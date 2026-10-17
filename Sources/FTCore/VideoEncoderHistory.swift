// ハードウェア動画エンコーダの故障の兆候の履歴(追記)。台帳(VideoEncoderLiveness)は最新1件の上書きなので、
// 「いつ・再起動から何分・何の直後に壊れたか」を後から突き合わせるためにここへ残す(故障の原因は未特定 =
// 監視して改善する方針。~/.fleetest/video-encoder-history.ndjson)。
// 書くのは: 切り出しのハードウェアの失敗・固まり(VideoRecordingCoordinator)/ 台帳の状態の変わり目(VideoEncoderLiveness.record)。
// 1 行 = {"at","boot","uptimeSeconds","event","source","detail"}。maxBytes を超えたら新しい側の半分を残す

import Foundation

public enum VideoEncoderHistory {
    public enum Event: String, Codable, Sendable {
        /// 切り出しのハードウェアが期限内に失敗した
        case callFailed
        /// 切り出しのハードウェアが期限内に終わらなかった
        case callTimedOut
        /// 台帳が生から死(または不明から死)へ変わった
        case becameDead
        /// 台帳が死から生へ変わった
        case becameAlive
    }

    struct Line: Codable, Equatable {
        let at: String
        let boot: String
        let uptimeSeconds: Int
        let event: Event
        let source: VideoEncoderLiveness.Source
        let detail: String?
    }

    static let fileName = "video-encoder-history.ndjson"
    /// 上限(バイト)。1 行 約 200 バイト = 約 2.5 万件。故障は1日に数回の事象なので数年分
    static let maxBytes = 5 * 1024 * 1024

    /// 書き込み先(台帳と同じ門・同じ置き場)。nil = 書かない
    static var writeURL: URL? {
        VideoEncoderLiveness.writeURL?.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    public static func append(event: Event, source: VideoEncoderLiveness.Source, detail: String?) {
        guard let url = writeURL else { return }
        append(event: event, source: source, detail: detail, to: url)
    }

    static func append(event: Event, source: VideoEncoderLiveness.Source, detail: String?, to url: URL,
                       now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let line = Line(at: ISO8601Millis.string(from: now), boot: FMLiveness.Stamp.bootID,
                        uptimeSeconds: Int(uptime.rounded()), event: event, source: source,
                        detail: detail.map { String($0.prefix(VideoEncoderLiveness.errorLimit)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        if let size = try? handle.offset(), size > UInt64(maxBytes) { trim(url) }
    }

    /// 新しい側の半分(行単位)を残す
    static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let keepFrom = data.count - maxBytes / 2
        guard keepFrom > 0, let newline = data[keepFrom...].firstIndex(of: 0x0A) else { return }
        try? data[(newline + 1)...].write(to: url, options: .atomic)
    }

    static func read(at url: URL) -> [Line] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
    }
}
