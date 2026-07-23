// RunRecorder.swift
// 1 run(ftester run / ftester api run 1 回の呼び出し)のライフサイクルを持つ記録器。
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
    /// 動画録画(record:true)が recordings/index.json を書く場所。RunOrchestrator への
    /// VideoRecordingConfig 注入に呼び出し側(ApiRunCommand/ProfileRunner)が使う
    public let runDir: URL

    private let lock = NSLock()
    /// ファイル名(sanitize 済み scenarioID)ごとの記録回数。2 回目以降は `~<回数>` を付与
    private var fileNameCounts: [String: Int] = [:]
    private let hostMetrics: HostMetricsRecorder?

    private init(runID: String, projectName: String, profile: String?, machine: String,
                trigger: String, startedAt: String, runDir: URL,
                hostMetrics: HostMetricsRecorder?) {
        self.runID = runID
        self.projectName = projectName
        self.profile = profile
        self.machine = machine
        self.trigger = trigger
        self.startedAt = startedAt
        self.runDir = runDir
        self.hostMetrics = hostMetrics
    }

    public static func begin(project: TestProject, profile: String?, trigger: String,
                             captureHostMetrics: Bool = true) -> RunRecorder {
        let machine = resolveMachine()
        let runID = makeRunID(machine: machine)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        let startedAt = ISO8601DateFormatter().string(from: Date())

        // runDir/host-metrics.ndjson へ 1Hz 採取・finish で停止
        let hostMetrics: HostMetricsRecorder? = captureHostMetrics
            ? HostMetricsRecorder(
                outputURL: runDir.appendingPathComponent("host-metrics.ndjson"), interval: 1,
                logFailure: { FileHandle.standardError.write(Data(("[RunRecorder] " + $0 + "\n").utf8)) })
            : nil

        let recorder = RunRecorder(
            runID: runID, projectName: project.name, profile: profile, machine: machine,
            trigger: trigger, startedAt: startedAt, runDir: runDir, hostMetrics: hostMetrics)

        let meta = RunMetaRecord(
            runID: runID, project: project.name, profile: profile, machine: machine,
            trigger: trigger, startedAt: startedAt)
        RunResultsStore.writeMeta(meta, runDir: runDir)
        return recorder
    }

    /// scenarioID の 2 回目以降が同一ファイルを上書きしないよう `<ID>~2.json` のように連番採番する
    public func record(_ record: ScenarioRunRecord) {
        var record = record
        record.runID = runID
        record.machine = machine
        record.profile = profile
        write(record)
    }

    public func recordSkipped(scenarioID: String, title: String?, platform: String,
                              worker: String?, reason: String) {
        let record = ScenarioRunRecord(
            runID: runID, scenarioID: scenarioID, title: title, platform: platform, worker: worker,
            machine: machine, profile: profile, passed: false, timedOut: false,
            startedAt: ISO8601DateFormatter().string(from: Date()), durationMs: 0,
            steps: StepCountsRecord(total: 1, skipped: 1),
            failedSteps: [FailedStepRecord(index: 0, description: reason)])
        write(record)
    }

    /// 凍結による再実行時に直前の記録を取り消す。連番カウンタも巻き戻す
    public func discardLast(scenarioID: String) {
        let baseName = Self.sanitizeFileName(scenarioID)
        lock.lock()
        let count = fileNameCounts[baseName] ?? 0
        guard count > 0 else { lock.unlock(); return }
        let fileName = count == 1 ? baseName : "\(baseName)~\(count)"
        fileNameCounts[baseName] = count - 1
        lock.unlock()
        RunResultsStore.removeScenario(runDir: runDir, fileName: fileName)
    }

    public func finish(total: Int, passed: Int, failed: Int, degradedWorkers: [String] = [],
                       freezeRetries: [String] = []) {
        hostMetrics?.stop()
        let meta = RunMetaRecord(
            runID: runID, project: projectName, profile: profile, machine: machine,
            trigger: trigger, startedAt: startedAt,
            finishedAt: ISO8601DateFormatter().string(from: Date()),
            total: total, passed: passed, failed: failed,
            degradedWorkers: degradedWorkers.isEmpty ? nil : degradedWorkers,
            freezeRetries: freezeRetries.isEmpty ? nil : freezeRetries)
        RunResultsStore.writeMeta(meta, runDir: runDir)
    }

    private func write(_ record: ScenarioRunRecord) {
        let baseName = Self.sanitizeFileName(record.scenarioID)
        lock.lock()
        let count = (fileNameCounts[baseName] ?? 0) + 1
        fileNameCounts[baseName] = count
        lock.unlock()
        let fileName = count == 1 ? baseName : "\(baseName)~\(count)"
        RunResultsStore.writeScenario(record, runDir: runDir, fileName: fileName)
    }

    private static func sanitizeFileName(_ scenarioID: String) -> String {
        String(scenarioID.map { $0 == "/" || $0 == ":" ? "_" : $0 })
    }

    /// 優先順位: LocalConfig.currentMachineName(FT_MACHINE > 登録名)> Host.current().localizedName
    /// > "unknown"。ファイル名(runID)に使うため [A-Za-z0-9_-] 以外は "_" に置換
    private static func resolveMachine(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let raw = LocalConfig.currentMachineName(environment: environment)
            ?? Host.current().localizedName
            ?? "unknown"
        return sanitizeMachineName(raw)
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

    /// <yyyyMMdd-HHmmss(UTC)>Z-<machine>-<乱数4hex>。辞書順 = 時系列順になるよう固定幅にする
    private static func makeRunID(machine: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let random = String(format: "%04x", UInt32.random(in: 0...0xFFFF))
        return "\(timestamp)Z-\(machine)-\(random)"
    }
}
