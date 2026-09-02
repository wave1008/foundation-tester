// RunRecorder.swift
// 1 run(fleetest run / fleetest api run 1 回の呼び出し)のライフサイクルを持つ記録器。
// begin() で runID 発番+ run.json 初回書き込み、record()/recordSkipped() でシナリオ単位を
// 都度書き込み、finish() で run.json に finishedAt・集計を追記する。
// 並列ワーカー(--profile 実行)から同時に record() が呼ばれるため NSLock で直列化する。
// 書き込みは全て best-effort(RunResultsStore 経由。失敗しても実行は止めない)。

import Foundation

/// シナリオ実行 1 件と RunRecorder を束ねて呼び出し側(逐次/並列の各ワーカー)に渡す単位
public struct ScenarioRecording: Sendable {
    public let recorder: RunRecorder
    public let worker: String?
    public let title: String?

    public init(recorder: RunRecorder, worker: String? = nil, title: String? = nil) {
        self.recorder = recorder
        self.worker = worker
        self.title = title
    }
}

public final class RunRecorder: @unchecked Sendable {
    public let runID: String

    private let projectName: String
    private let profile: String?
    private let machine: String
    private let trigger: String
    private let startedAt: String
    /// 自己申告のディスパッチ発行者(LocalConfig.resolveIssuerId)。begin() で1回だけ解決し、
    /// begin/finish 両方の RunMetaRecord へ同じ値を焼き込む
    private let issuer: String?
    /// 同じ実行から分かれた run を束ねる鍵(RunMetaRecord.runGroup の宣言参照)。issuer と同じく
    /// begin/finish 両方へ同じ値を焼き込む —— finish で落とすと、途中で落ちた run だけが
    /// 束から外れて「マシンが1台足りない実行」に見える
    private let runGroup: String?
    /// 動画録画(record:true)が recordings/index.json を書く場所。RunOrchestrator への
    /// VideoRecordingConfig 注入に呼び出し側(ApiRunCommand/ProfileRunner)が使う
    public let runDir: URL

    private let lock = NSLock()
    /// ファイル名(sanitize 済み scenarioID)ごとの**高水位**(これまでに振った最大の連番)。
    /// 2 回目以降は `~<回数>` を付与。discardLast で巻き戻すのは「消したのが最新」のときだけ
    private var fileNameCounts: [String: Int] = [:]
    /// baseName ごとの、いま残っているファイル名と書き手(ScenarioRunRecord.worker)。書いた順。
    /// **discardLast(worker:) がその書き手のぶんだけを消す**ための台帳 —— ブロードキャスト実行は
    /// 同じ ID を N 台が同時に書くので、「この ID の最新」では別の台の記録を消す
    private var liveFiles: [String: [(fileName: String, worker: String?)]] = [:]
    private let hostMetrics: HostMetricsRecorder?

    private init(runID: String, projectName: String, profile: String?, machine: String,
                trigger: String, startedAt: String, runDir: URL,
                hostMetrics: HostMetricsRecorder?, issuer: String?, runGroup: String?) {
        self.runID = runID
        self.projectName = projectName
        self.profile = profile
        self.machine = machine
        self.trigger = trigger
        self.startedAt = startedAt
        self.runDir = runDir
        self.hostMetrics = hostMetrics
        self.issuer = issuer
        self.runGroup = runGroup
    }

    public static func begin(project: TestProject, profile: String?, trigger: String,
                             captureHostMetrics: Bool = true,
                             runGroup: String? = nil) -> RunRecorder {
        let machine = resolveMachine()
        let runID = makeRunID()
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        let startedAt = ISO8601DateFormatter().string(from: Date())

        // runDir/host-metrics.ndjson へ 1Hz 採取・finish で停止
        let hostMetrics: HostMetricsRecorder? = captureHostMetrics
            ? HostMetricsRecorder(
                outputURL: runDir.appendingPathComponent("host-metrics.ndjson"), interval: 1,
                logFailure: { FileHandle.standardError.write(Data(("[RunRecorder] " + $0 + "\n").utf8)) })
            : nil

        let issuer = LocalConfig.resolveIssuerId()
        let recorder = RunRecorder(
            runID: runID, projectName: project.name, profile: profile, machine: machine,
            trigger: trigger, startedAt: startedAt, runDir: runDir, hostMetrics: hostMetrics,
            issuer: issuer, runGroup: runGroup)

        let meta = RunMetaRecord(
            runID: runID, project: project.name, profile: profile, host: machine,
            trigger: trigger, startedAt: startedAt, issuer: issuer, runGroup: runGroup)
        RunResultsStore.writeMeta(meta, runDir: runDir)
        return recorder
    }

    /// scenarioID の 2 回目以降が同一ファイルを上書きしないよう `<ID>~2.json` のように連番採番する
    public func record(_ record: ScenarioRunRecord) {
        var record = record
        record.runID = runID
        record.host = machine
        record.profile = profile
        write(record)
    }

    /// 実行に至らなかったシナリオの合成レコード。kind の既定は `.noWorker`(インフラ都合)で、
    /// **`.notApplicable`(platform 宣言による対象外)は呼び出し側が明示する** ——
    /// 取り違えると意図された未実行と事故が同じ顔になる(ScenarioSkipKind の宣言)
    public func recordSkipped(scenarioID: String, title: String?, platform: String,
                              worker: String?, reason: String,
                              kind: ScenarioSkipKind = .noWorker) {
        let record = ScenarioRunRecord(
            runID: runID, scenarioID: scenarioID, title: title, platform: platform, worker: worker,
            host: machine, profile: profile, passed: false, timedOut: false,
            startedAt: ISO8601DateFormatter().string(from: Date()), durationMs: 0,
            steps: StepCountsRecord(total: 1, skipped: 1),
            failedSteps: [FailedStepRecord(index: 0, description: reason)],
            skipKind: kind)
        write(record)
    }

    /// 凍結・環境エラーによる再実行時に直前の記録を取り消す。
    /// - worker: 消してよい書き手(`ScenarioRunner.recordingWorker` = 記録の `worker` と同じ文字列)。
    ///   **並列の呼び手は必ず渡す** —— nil は「この ID の最新」を消す(逐次実行・旧呼び手向け)。
    /// 連番は「消したのが最新」のときだけ巻き戻す(途中を消したときは欠番のまま残す。巻き戻すと
    /// 次の書き込みが残っている番号と衝突して上書きする)
    public func discardLast(scenarioID: String, worker: String? = nil) {
        let baseName = Self.sanitizeFileName(scenarioID)
        lock.lock()
        guard var entries = liveFiles[baseName],
              let index = worker == nil ? entries.indices.last
                                        : entries.lastIndex(where: { $0.worker == worker }) else {
            lock.unlock()
            return
        }
        let removed = entries.remove(at: index)
        liveFiles[baseName] = entries
        if index == entries.count, let count = fileNameCounts[baseName], count > 0,
           removed.fileName == Self.fileName(baseName, count: count) {
            fileNameCounts[baseName] = count - 1
        }
        lock.unlock()
        RunResultsStore.removeScenario(runDir: runDir, fileName: removed.fileName)
    }

    public func finish(total: Int, passed: Int, failed: Int, degradedWorkers: [String] = [],
                       freezeRetries: [String] = [],
                       blankRepairs: [String] = [], blankExclusions: [String] = [],
                       measurementInvalid: Bool = false, measurementInvalidReasons: [String] = [],
                       workerAnomalies: [WorkerAnomalyRecord] = [],
                       performanceMode: Bool = false) {
        hostMetrics?.stop()
        // FM の死活は**引数で受け取らない** —— 機械グローバルな事実(FMLiveness)なので、
        // 呼び出し元が run のたびに集めて渡す形にすると経路ごとに渡し忘れが出る
        // (`fleetest run` / `api run` は別実装。RunCommandFlagParityTests の教訓)
        let fmReading = FMLiveness.current()
        let fmDeadPaths = fmReading.deadPaths
        let meta = RunMetaRecord(
            runID: runID, project: projectName, profile: profile, host: machine,
            trigger: trigger, startedAt: startedAt,
            finishedAt: ISO8601DateFormatter().string(from: Date()),
            total: total, passed: passed, failed: failed,
            degradedWorkers: degradedWorkers.isEmpty ? nil : degradedWorkers,
            freezeRetries: freezeRetries.isEmpty ? nil : freezeRetries,
            blankRepairs: blankRepairs.isEmpty ? nil : blankRepairs,
            blankExclusions: blankExclusions.isEmpty ? nil : blankExclusions,
            // false は書かない(既存レコードと同じ形を保つ。measurementInvalid=false の run は
            // performanceMode オフか、performanceMode でもレーンが安定していた run)
            measurementInvalid: measurementInvalid ? true : nil,
            measurementInvalidReasons: measurementInvalid && !measurementInvalidReasons.isEmpty
                ? measurementInvalidReasons : nil,
            workerAnomalies: workerAnomalies.isEmpty ? nil : workerAnomalies,
            issuer: issuer, runGroup: runGroup,
            // false/nil は書かない(measurementInvalid と同じ流儀)
            performanceMode: performanceMode ? true : nil,
            // 生・不明は書かない(既存レコードと同じ形)。**不明を「生」と書かない**のが肝で、
            // 欄が無い = 何も観測できなかった、と読む
            fmDead: fmDeadPaths.isEmpty ? nil : fmDeadPaths,
            fmDeadReason: fmReading.deadSummary())
        RunResultsStore.writeMeta(meta, runDir: runDir)
    }

    private func write(_ record: ScenarioRunRecord) {
        let baseName = Self.sanitizeFileName(record.scenarioID)
        lock.lock()
        let count = (fileNameCounts[baseName] ?? 0) + 1
        fileNameCounts[baseName] = count
        let fileName = Self.fileName(baseName, count: count)
        liveFiles[baseName, default: []].append((fileName, record.worker))
        lock.unlock()
        RunResultsStore.writeScenario(record, runDir: runDir, fileName: fileName)
    }

    private static func fileName(_ baseName: String, count: Int) -> String {
        count == 1 ? baseName : "\(baseName)~\(count)"
    }

    private static func sanitizeFileName(_ scenarioID: String) -> String {
        String(scenarioID.map { $0 == "/" || $0 == ":" ? "_" : $0 })
    }

    /// 結果に付ける「どの機械で走ったか」。優先順位: FT_MACHINE > **ホスト名** > "unknown"。
    /// 既定がホスト名なのは、人が登録する値ではないぶんズレようがなく、
    /// 機械の身元としてはむしろ正確なため(登録名は持たない。RunProfile.determineMachine)
    /// (ファイル名(runID)に使うため [A-Za-z0-9_-] 以外は "_" に置換)
    private static func resolveMachine(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let env = environment["FT_MACHINE"]
        let raw = (env?.isEmpty == false ? env : nil)
            ?? Host.current().localizedName
            ?? "unknown"
        return sanitizeMachineName(raw)
    }

    /// 実績の読み手(LPT の同一 machine 優先)が「この機械」を判定するための識別子。
    /// **記録時(resolveMachine)と同じ規則**(FT_MACHINE > ホスト名 > "unknown"、同じ正規化)
    /// でなければ照合できないので、別の規則を作らずここを呼ぶこと
    public static func currentMachine(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolveMachine(environment: environment)
    }

    private static func sanitizeMachineName(_ name: String) -> String {
        let sanitized = String(name.map { char -> Character in
            if char.isASCII, char.isLetter || char.isNumber || char == "_" || char == "-" {
                return char
            }
            return "_"
        })
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    /// ファンアウトの親が1回だけ発行する束ね鍵(RunMetaRecord.runGroup)。**形式は runID と同じ**
    /// (辞書順=時系列順。親は run ディレクトリを作らないので runID とは衝突しない)。
    /// 子はこれを `--run-group` で受け取って**そのまま**書く —— 各機械が自分で作ると束にならない
    public static func makeRunGroupID() -> String {
        makeRunID()
    }

    /// <yyyyMMdd-HHmmss(UTC)>Z-<乱数8hex>。辞書順 = 時系列順になるよう固定幅にする。
    /// **マシン名は埋めない**(2026-09-01 ユーザー指示。埋めたホスト名が表示へ漏れ続けるため。
    /// どの機械の run かは記録の `host` 欄が持ち、画面は machine へ読み替える)。
    /// 複数マシンが同じ results/ へ書いても衝突しない一意性は、マシン名の代わりに
    /// 乱数を 4hex→8hex(2^32)へ広げて担保する。旧形式
    /// (<ts>Z-<マシン名>-<4hex>)の記録もそのまま読める —— 構造に依存する読み手は
    /// 先頭の日時 prefix だけ(RunResultsStore.runDir / recordingsStore.ts)
    private static func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let random = String(format: "%08x", UInt32.random(in: .min ... .max))
        return "\(timestamp)Z-\(random)"
    }
}
