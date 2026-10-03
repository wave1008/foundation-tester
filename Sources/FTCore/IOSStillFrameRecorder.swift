// 物理 iPhone の「録画」。動画を取り出す手段が無い(simctl io recordVideo はシミュレータ専用・macOS 27 は
// iPhone を AVCaptureDevice として出す DAL プラグインも無い = docs/verification.md「実機の画面配信」)ので、
// シナリオ実行プロセスが操作の直後に撮った静止画(StillFrameCapture)を、停止時に時刻どおりの mp4 へまとめる。
// ホストが撮り続ける方式は採らない —— 撮影と操作が同じブリッジを奪い合い、5 コマ/秒でも /snapshot が
// 76ms → 114ms に延びた(SE3 実測)。子は操作と同じ順番でブリッジを使うので奪い合わない。
// 撮影先は `<workDir>/<fileStem>-stills/`。子へは ScenarioHost が `--still-frames-dir` で渡す
// (VideoRecordingCoordinator.stillFramesDir)。

import Foundation

/// 子(シナリオ実行プロセス)側の撮影の書き手。ファイル名は `<epoch ミリ秒>.png` ——
/// 読み手 StillFrameMovieEncoder.frames(in:) と同じ規約(片方だけ変えない)
public struct StillFrameCapture: Sendable {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    public static func fileName(at date: Date) -> String {
        "\(Int64((date.timeIntervalSince1970 * 1000).rounded(.down))).png"
    }

    /// at = 撮影を頼んだ時刻(返ってきた時刻ではない —— 絵はその時点の画面)。失敗は無視する
    /// (撮れない1枚のためにシナリオを止めない)
    public func save(_ png: Data, at date: Date) {
        try? png.write(to: dir.appendingPathComponent(Self.fileName(at: date)), options: .atomic)
    }
}

actor IOSStillFrameRecorder: DeviceVideoRecorderSession {
    nonisolated let stillsDir: URL
    private let movieURL: URL

    init(workDir: URL, fileStem: String) {
        self.stillsDir = workDir.appendingPathComponent("\(fileStem)-stills", isDirectory: true)
        self.movieURL = workDir.appendingPathComponent("\(fileStem).mp4")
    }

    func start() async -> Bool {
        (try? FileManager.default.createDirectory(at: stillsDir, withIntermediateDirectories: true)) != nil
    }

    /// 尺は「最初の1枚 〜 停止時刻」。最初の1枚より前は絵が無いので録画の範囲に含めない
    /// (クリップの切り出しは録画の範囲との交わりを取るので、そこで欠けるだけ)
    func stop() async -> RecordingSource? {
        let endAt = Date()
        defer { try? FileManager.default.removeItem(at: stillsDir) }
        let frames = StillFrameMovieEncoder.frames(in: stillsDir)
        guard let first = frames.first, let last = frames.last else { return nil }
        // 尺の終わりを encoder と同じ値で決める(segments の尺と mp4 の尺を食い違わせない)
        let end = endAt > last.at ? endAt : last.at.addingTimeInterval(1)
        guard await StillFrameMovieEncoder.encode(frames: frames, endAt: end, to: movieURL) else { return nil }
        let durationMs = Int((end.timeIntervalSince(first.at) * 1000).rounded())
        return RecordingSource(
            files: [movieURL],
            segments: [RecordingIndexSegment(startedAt: ISO8601Millis.string(from: first.at),
                                             durationMs: durationMs)])
    }
}
