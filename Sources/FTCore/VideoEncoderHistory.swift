// ハードウェアビデオエンコーダの故障の兆候の履歴(追記)。台帳(VideoEncoderLiveness)は最新1件の上書きなので、
// 「いつ・再起動から何分・何の直後に壊れたか」を後から突き合わせるためにここへ残す(故障の原因は未特定 =
// 監視して改善する方針。~/.fleetest/video-encoder-history.ndjson)。
// 書くのは: 切り出しのハードウェアの失敗・固まり(VideoRecordingCoordinator)/ 台帳の状態の変わり目(VideoEncoderLiveness.record)。
// 1 行 = {"at","boot","uptimeSeconds","event","source","detail"}。maxBytes を超えたら新しい側の半分を残す。
// **書き手は複数プロセス**(run・host-metrics)なので、追記も切り詰めも lockFileName の flock の内側で O_APPEND で書く
// (seekToEnd → write だと同じ位置へ上書きし合い、8 プロセス × 1,000 回で 8,000 件中 2,673 件しか残らなかった)

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
    static let lockFileName = "video-encoder-history.lock"
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
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = open(dir.appendingPathComponent(lockFileName).path, O_CREAT | O_NOFOLLOW | O_RDWR, 0o644)
        guard lock >= 0 else { return }
        defer { close(lock) }  // close が flock も解放する
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { return }
        }
        let fd = open(url.path, O_CREAT | O_NOFOLLOW | O_WRONLY | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var info = stat()
        let size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        close(fd)
        if written > 0, size > maxBytes { trim(url) }
    }

    /// 新しい側の半分(行単位)を残す。**呼ぶのは append の flock の内側だけ**(置き換えの間に他の書き手が旧 inode へ書かない)
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
