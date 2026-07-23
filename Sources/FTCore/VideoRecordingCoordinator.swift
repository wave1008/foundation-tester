// VideoRecordingCoordinator.swift
// run profile の record:true 時、RunOrchestrator がワーカーの起動/離脱・シナリオ開始/終了に
// 合わせて呼び出す録画セッションの束ね役。
// 録画プロセス自体はワーカー単位で回す(シナリオ毎の start/stop はオーバーヘッド大)が、
// 成果物はテスト関数(シナリオ)ごとに 1 本の mp4 へファイナライズ時に壁時計区間で切り出す
// (VideoRecordingFinalizer.extractClip)。index.json への書き出しは finish()
// (run() の task group join 後に 1 回だけ呼ぶ)。

import Foundation

/// RunOrchestrator に注入する録画設定。nil を渡せば録画自体が無効(呼び出し側の既定)。
public struct VideoRecordingConfig: Sendable {
    /// recordings/index.json・録画ファイルの書き出し先(RunRecorder.runDir)
    public let runDir: URL
    /// Android の adb パス(AndroidDriver.findADB() 相当)。nil なら Android 録画は無効
    /// (FTCore は FTAndroid を import できないため呼び出し側が注入する)
    public let androidADBPath: String?

    public init(runDir: URL, androidADBPath: String? = nil) {
        self.runDir = runDir
        self.androidADBPath = androidADBPath
    }
}

/// 1 ワーカーのフル録画ソース。iOS は要素数 1([.mov])、Android は pull 済みセグメント mp4 群
/// (180 秒毎)。files[i] の壁時計スパンが segments[i](1:1 対応・連結順)。
/// ソース自体は録画停止していた区間(欠落)を含まない = ここでの位置がそのままソース内 CMTime になる
struct RecordingSource: Sendable {
    let files: [URL]
    let segments: [RecordingIndexSegment]
}

/// iOS(simctl)/Android(adb screenrecord)の実体を隠す共通インターフェース
protocol DeviceVideoRecorderSession: Sendable {
    /// 録画プロセスの起動に成功したら true。RecordingLease の書き込み可否の判定に使う
    /// (RunOrchestrator.videoRecording?.start(_:) の戻り値経由)
    func start() async -> Bool
    /// 録画停止。フル録画のソースを返す(ファイナライズ/クリップ切り出しは呼び出し側が行う)。
    /// 録画自体が始まっていない/停止時に何も拾えなかった場合は nil
    /// (呼び出し側は警告ログのみで run を失敗させない)
    func stop() async -> RecordingSource?
}

actor VideoRecordingCoordinator {
    private struct ActiveEntry {
        let session: any DeviceVideoRecorderSession
        let workerID: String
        let platform: String
    }

    /// 1 シナリオの実行区間(壁時計)。end が nil の間は実行中(scenarioFinished 未着)
    private struct ScenarioInterval {
        let scenarioID: String
        let start: Date
        var end: Date?
    }

    private let config: VideoRecordingConfig
    private var active: [String: ActiveEntry] = [:]  // key = worker.label(物理ワーカー単位)
    /// key = worker.label。superviseWorker の revive で worker.label が変わっても、
    /// 古いラベルの区間は stop()/finish() 時にそのラベルの録画ソースに対して処理されるだけで矛盾しない
    private var scenarioIntervals: [String: [ScenarioInterval]] = [:]
    /// ソース一時ファイル名(recordings/ 配下に直接置く)の一意化。key = workerID
    private var sourceFileNameCounts: [String: Int] = [:]
    /// 最終クリップファイル名の一意化(同一 scenarioID の revive 後再実行等)。key = scenarioID
    private var clipFileNameCounts: [String: Int] = [:]
    private var entries: [RecordingIndexEntry] = []

    init(config: VideoRecordingConfig) {
        self.config = config
    }

    /// worker.label(物理ワーカー)ごとにセッションを開始する。revive 後の新ワーカーは
    /// worker.label が変わるため独立したセッション(=別ソース)になる。
    /// 戻り値: 録画プロセスの起動に成功したら true(呼び出し側の RecordingLease 書き込み判定用)
    @discardableResult
    func start(_ worker: RunWorker) async -> Bool {
        let workerID = "\(worker.platform):\(worker.logicalName ?? worker.label)"
        let recordingsDir = config.runDir.appendingPathComponent(RecordingIndexIO.directoryName)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        // クリップの最終ファイル名(scenarioID 由来)とは別名前空間(ソースは切り出し後に削除される一時物)
        let sourceStem = "src-\(uniqueSourceStem(for: workerID))"

        let session: (any DeviceVideoRecorderSession)?
        switch worker.platform {
        case "ios":
            session = worker.connection.udid.map {
                IOSSimulatorVideoRecorder(udid: $0, workDir: recordingsDir, fileStem: sourceStem)
            }
        case "android":
            if let serial = worker.connection.serial, let adbPath = config.androidADBPath {
                session = AndroidScreenVideoRecorder(
                    serial: serial, adbPath: adbPath, workDir: recordingsDir, fileStem: sourceStem)
            } else {
                session = nil
            }
        default:
            session = nil
        }
        guard let session else { return false }
        guard await session.start() else { return false }
        active[worker.label] = ActiveEntry(session: session, workerID: workerID, platform: worker.platform)
        return true
    }

    /// RunOrchestrator のワーカーループが ScenarioRunner.runOne 呼び出し直前に通知する
    func scenarioStarted(workerLabel: String, scenarioID: String, at: Date) {
        scenarioIntervals[workerLabel, default: []].append(
            ScenarioInterval(scenarioID: scenarioID, start: at, end: nil))
    }

    /// RunOrchestrator のワーカーループが ScenarioRunner.runOne 呼び出し直後に通知する
    func scenarioFinished(workerLabel: String, at: Date) {
        guard var list = scenarioIntervals[workerLabel], let last = list.indices.last,
              list[last].end == nil else { return }
        list[last].end = at
        scenarioIntervals[workerLabel] = list
    }

    func stop(_ worker: RunWorker) async {
        guard let entry = active.removeValue(forKey: worker.label) else { return }
        await finalize(worker.label, entry)
    }

    /// run() の task group join 後に 1 回呼ぶ。残っているセッション(通常は無いはずの安全網)を
    /// 畳んでから index.json を書く
    func finish() async {
        let remaining = active
        active.removeAll()
        for (label, entry) in remaining { await finalize(label, entry) }
        // 先頭 segment の startedAt 昇順(再生ビューの既定選択・一覧表示の安定順)
        entries.sort { ($0.segments.first?.startedAt ?? "") < ($1.segments.first?.startedAt ?? "") }
        RecordingIndexIO.write(entries, runDir: config.runDir)
    }

    /// 1 ワーカーのフル録画を停止し、そのワーカーで実行された各シナリオの区間ごとに
    /// クリップを切り出す。フルソースは(1件もクリップが取れなくても)必ず削除する
    private func finalize(_ workerLabel: String, _ entry: ActiveEntry) async {
        guard let source = await entry.session.stop() else { return }
        defer { for file in source.files { try? FileManager.default.removeItem(at: file) } }

        // 区間が1つも無いワーカーの録画は破棄(シナリオが1本も来なかったアイドルワーカー等)
        let intervals = scenarioIntervals.removeValue(forKey: workerLabel) ?? []
        guard !intervals.isEmpty,
              let recordingRange = RecordingWallClock.wallClockRange(of: source.segments) else { return }

        for interval in intervals {
            // クリップの壁時計範囲 = [max(シナリオ開始, 録画開始), min(シナリオ終了, 録画終了)]
            let clipWallStart = max(interval.start, recordingRange.start)
            let clipWallEnd = min(interval.end ?? recordingRange.end, recordingRange.end)
            // 実長500ms未満はスキップ
            guard clipWallEnd.timeIntervalSince(clipWallStart) >= 0.5 else { continue }

            let clipStartMs = RecordingWallClock.offsetMs(source.segments, at: clipWallStart)
            let clipEndMs = RecordingWallClock.offsetMs(source.segments, at: clipWallEnd)
            // シナリオ区間全体が録画の欠落(停止していた間)に落ちるとゼロ長になり得る
            guard clipEndMs > clipStartMs else { continue }

            let fileStem = uniqueClipStem(for: interval.scenarioID)
            let file = "\(RecordingIndexIO.directoryName)/\(fileStem).mp4"
            let outputURL = config.runDir.appendingPathComponent(file)
            guard await VideoRecordingFinalizer.extractClip(
                sourceFiles: source.files, clipStartMs: clipStartMs, clipEndMs: clipEndMs,
                to: outputURL) else {
                FileHandle.standardError.write(Data(
                    "⚠️ [recording] \(interval.scenarioID): クリップの切り出しに失敗しました\n".utf8))
                continue
            }
            let clipSegments = RecordingWallClock.intersect(
                source.segments, range: (clipWallStart, clipWallEnd))
            entries.append(RecordingIndexEntry(
                scenarioID: interval.scenarioID, worker: entry.workerID, platform: entry.platform,
                file: file, segments: clipSegments))
        }
    }

    private func uniqueSourceStem(for workerID: String) -> String {
        let base = RecordingIndexIO.sanitizedFileName(for: workerID)
        let count = (sourceFileNameCounts[base] ?? 0) + 1
        sourceFileNameCounts[base] = count
        return count == 1 ? base : "\(base)~\(count)"
    }

    private func uniqueClipStem(for scenarioID: String) -> String {
        let base = RecordingIndexIO.sanitizedFileName(for: scenarioID)
        let count = (clipFileNameCounts[base] ?? 0) + 1
        clipFileNameCounts[base] = count
        return count == 1 ? base : "\(base)~\(count)"
    }
}
