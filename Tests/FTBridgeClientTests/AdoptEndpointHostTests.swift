// BridgeProvisioner の `.adopt`(別プロセスが起動中のブリッジを引き取る)経路が、ready 待ちの宛先を
// **記録ファイル(.fleetest/bridge-<port>.endpoint)から丸ごと読む**ことのソース走査。
//
// `BridgeEndpoint(port:)` は常にループバック・token 無し。LAN 経由の実機は起動した側が LAN IP を
// 記録しており、それを読まずに待つと「起動しているのに応答が無い」と誤って止めて建て直す。
// usb トンネルは host こそループバックのままだが token を記録している(establish の usb 分岐)ので、
// host だけでなく endpoint ごと渡す必要がある。仮想デバイスは記録が無く load がループバック・
// token 無しを返すので挙動は変わらない。同型: BridgeHostPlumbingTests(BridgeClient の生成側)。

import XCTest
@testable import FTBridgeClient

final class AdoptEndpointHostTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// `.adopt` の case ブロック(次の `case .launch` まで)の中の waitUntilReady が
    /// `BridgeEndpoint.load(port: port, repoRoot: repoRoot)` を**丸ごと**渡していること
    /// (host だけ取り出すと usb トンネルの token を落とす。BridgeClient(endpoint:) と対)
    func testAdoptWaitsOnTheRecordedEndpoint() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift"),
            encoding: .utf8)
        guard let start = source.range(of: "case .adopt(let port):\n            await claimed()"),
              let end = source.range(of: "case .launch(let port,", range: start.upperBound..<source.endIndex)
        else {
            return XCTFail("executeBridge の .adopt ブロックが見つからない(書式が変わった)")
        }
        let block = String(source[start.upperBound..<end.lowerBound])
        let collapsed = block.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(
            collapsed.contains("waitUntilReady( endpoint: BridgeEndpoint.load(port: port, repoRoot: repoRoot)"),
            "adopt の ready 待ちは記録ファイルの endpoint(host + token)を丸ごと使うこと: \(collapsed)")
        XCTAssertFalse(collapsed.contains("host: BridgeEndpoint.load(port: port, repoRoot: repoRoot).host"),
                       "host だけを取り出す形へ戻さない(usb トンネルの token を落とす)")
        XCTAssertFalse(block.contains("BridgeEndpoint(port: port).host"),
                       "adopt の ready 待ちをループバック固定へ戻さない(LAN/usb 経由の実機で届かない)")
    }

    /// 記録が無ければループバック・あれば記録した host(adopt が依存する契約)
    func testLoadFallsBackToLoopbackWithoutARecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adopt-endpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(BridgeEndpoint.load(port: 8901, repoRoot: root).host, BridgeEndpoint.loopbackHost)
        BridgeEndpoint(host: "192.168.1.23", port: 8901).persist(repoRoot: root)
        XCTAssertEqual(BridgeEndpoint.load(port: 8901, repoRoot: root).host, "192.168.1.23")
    }
}
