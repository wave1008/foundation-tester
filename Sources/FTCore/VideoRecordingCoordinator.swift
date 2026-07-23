// VideoRecordingCoordinator.swift
// run profile の record:true 時、RunOrchestrator がワーカーの起動/離脱に合わせて
// 呼び出す録画セッションの束ね役。1 ワーカー = 1 DeviceVideoRecorderSession。
// index.json への書き出しは finish()(run() の task group join 後に 1 回だけ呼ぶ)。

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

/// iOS(simctl)/Android(adb screenrecord)の実体を隠す共通インターフェース
protocol DeviceVideoRecorderSession: Sendable {
    /// 録画プロセスの起動に成功したら true。RecordingLease の書き込み可否の判定に使う
    /// (RunOrchestrator.videoRecording?.start(_:) の戻り値経由)
    func start() async -> Bool
    /// 録画停止+ファイナライズ。録画自体が始まっていない/停止時に何も拾えなかった場合は nil
    /// (呼び出し側は警告ログのみで run を失敗させない)
    func stopAndFinalize() async -> [RecordingIndexSegment]?
}

actor VideoRecordingCoordinator {
    private struct ActiveEntry {
        let session: any DeviceVideoRecorderSession
        let workerID: String
        let platform: String
        let fileStem: String
    }

    private let config: VideoRecordingConfig
    private var active: [String: ActiveEntry] = [:]   // key = worker.label(物理ワーカー単位)
    private var fileNameCounts: [String: Int] = [:]
    private var entries: [RecordingIndexEntry] = []

    init(config: VideoRecordingConfig) {
        self.config = config
    }

    /// worker.label(物理ワーカー)ごとにセッションを開始する。revive 後の新ワーカーは
    /// worker.label が変わるため独立したセッション(=別ファイル)になる(index.json に
    /// 同じ worker id で複数エントリが載り得る既知の制約。動画自体は revive 前後で連結しない)。
    /// 戻り値: 録画プロセスの起動に成功したら true(呼び出し側の RecordingLease 書き込み判定用)
    @discardableResult
    func start(_ worker: RunWorker) async -> Bool {
        let workerID = "\(worker.platform):\(worker.logicalName ?? worker.label)"
        let fileStem = uniqueFileStem(for: workerID)
        let recordingsDir = config.runDir.appendingPathComponent(RecordingIndexIO.directoryName)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let session: (any DeviceVideoRecorderSession)?
        switch worker.platform {
        case "ios":
            session = worker.connection.udid.map {
                IOSSimulatorVideoRecorder(udid: $0, workDir: recordingsDir, fileStem: fileStem)
            }
        case "android":
            if let serial = worker.connection.serial, let adbPath = config.androidADBPath {
                session = AndroidScreenVideoRecorder(
                    serial: serial, adbPath: adbPath, workDir: recordingsDir, fileStem: fileStem)
            } else {
                session = nil
            }
        default:
            session = nil
        }
        guard let session else { return false }
        guard await session.start() else { return false }
        active[worker.label] = ActiveEntry(
            session: session, workerID: workerID, platform: worker.platform, fileStem: fileStem)
        return true
    }

    func stop(_ worker: RunWorker) async {
        guard let entry = active.removeValue(forKey: worker.label) else { return }
        await finalize(entry)
    }

    /// これ未満の録画は index に載せず破棄する(ms)。シナリオが1本も来なかったアイドルワーカーは
    /// 画面が変化せず VFR ソースが数 ms になる。0:00 動画が再生ビューの既定選択になる実害があった
    private static let minimumDurationMs = 1000

    /// run() の task group join 後に 1 回呼ぶ。残っているセッション(通常は無いはずの安全網)を
    /// 畳んでから index.json を書く
    func finish() async {
        let remaining = active
        active.removeAll()
        for (_, entry) in remaining { await finalize(entry) }
        // worker id 順で安定させる(再生ビューの既定選択が先頭エントリになるため)
        entries.sort { $0.worker < $1.worker }
        RecordingIndexIO.write(entries, runDir: config.runDir)
    }

    private func finalize(_ entry: ActiveEntry) async {
        guard let segments = await entry.session.stopAndFinalize(), !segments.isEmpty else { return }
        let file = "\(RecordingIndexIO.directoryName)/\(entry.fileStem).mp4"
        guard segments.reduce(0, { $0 + $1.durationMs }) >= Self.minimumDurationMs else {
            try? FileManager.default.removeItem(at: config.runDir.appendingPathComponent(file))
            return
        }
        entries.append(RecordingIndexEntry(
            worker: entry.workerID, platform: entry.platform, file: file, segments: segments))
    }

    private func uniqueFileStem(for workerID: String) -> String {
        let base = RecordingIndexIO.sanitizedFileName(for: workerID)
        let count = (fileNameCounts[base] ?? 0) + 1
        fileNameCounts[base] = count
        return count == 1 ? base : "\(base)~\(count)"
    }
}
