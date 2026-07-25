// ホストからブリッジへ到達するための (host, port)。
//   - iOS シミュレータ / Android: 常に 127.0.0.1(シミュレータはホストとネットワークスタックを
//     共有、Android は adb forward がホスト側ポートを開く)
//   - iOS 実機: デバイス内のループバックはホストから見えない。到達手段は 2 つ(IOSDeviceTransport):
//       lan … ランナーを 0.0.0.0 に bind させ、デバイスの LAN IP へ直接 HTTP
//       usb … iproxy(libimobiledevice)で USB トンネルを張り 127.0.0.1 を維持
// 解決済みの endpoint は .ftester/bridge-<port>.endpoint に置き、別プロセス(モニター・
// 復帰時のワーカー再構築)が同じ宛先を再現できるようにする。

import Foundation

public struct BridgeEndpoint: Sendable, Hashable, Codable {
    /// シミュレータ・Android・USB トンネル時の宛先
    public static let loopbackHost = "127.0.0.1"

    public let host: String
    public let port: UInt16

    public init(host: String = BridgeEndpoint.loopbackHost, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var isLoopback: Bool { host == Self.loopbackHost }

    // MARK: - 永続化(.ftester/bridge-<port>.endpoint)

    static func fileURL(port: UInt16, repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".ftester/bridge-\(port).endpoint")
    }

    /// 127.0.0.1 以外のときだけ書く(ループバックはファイルが無い=既定、という契約にして
    /// シミュレータ運用に新しいファイルを増やさない)
    public func persist(repoRoot: URL) {
        let url = Self.fileURL(port: port, repoRoot: repoRoot)
        guard !isLoopback else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? host.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 記録が無ければループバック(= シミュレータ・Android の既定)
    public static func load(port: UInt16, repoRoot: URL) -> BridgeEndpoint {
        guard let host = try? String(contentsOf: fileURL(port: port, repoRoot: repoRoot),
                                     encoding: .utf8) else {
            return BridgeEndpoint(port: port)
        }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return BridgeEndpoint(host: trimmed.isEmpty ? loopbackHost : trimmed, port: port)
    }

    public static func forget(port: UInt16, repoRoot: URL) {
        try? FileManager.default.removeItem(at: fileURL(port: port, repoRoot: repoRoot))
    }
}
