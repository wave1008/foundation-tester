// BridgeEndpoint の永続化フォーマット(1行目=host / 2行目=token)の往復。
// 2行目が無い旧形式(host のみ)は token=nil として読めること(更新前から動いているブリッジとの
// 後方互換)。同型: AdoptEndpointHostTests(host だけの往復)。

import XCTest
@testable import FTBridgeClient

final class BridgeEndpointTokenTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-endpoint-token-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPersistAndLoadRoundTripsHostAndToken() {
        BridgeEndpoint(host: "192.168.1.23", port: 8901, token: "deadbeef").persist(repoRoot: root)
        let loaded = BridgeEndpoint.load(port: 8901, repoRoot: root)
        XCTAssertEqual(loaded.host, "192.168.1.23")
        XCTAssertEqual(loaded.token, "deadbeef")
    }

    func testPersistWithoutTokenLoadsNilToken() {
        BridgeEndpoint(host: "192.168.1.23", port: 8901).persist(repoRoot: root)
        XCTAssertNil(BridgeEndpoint.load(port: 8901, repoRoot: root).token)
    }

    /// 更新前に書かれた host 1行だけのファイル(このリポジトリの旧版が実際に書いていた形)
    func testLegacyOneLineFileLoadsWithNilToken() throws {
        let url = root.appendingPathComponent(".fleetest/bridge-8901.endpoint")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "192.168.1.23".write(to: url, atomically: true, encoding: .utf8)
        let loaded = BridgeEndpoint.load(port: 8901, repoRoot: root)
        XCTAssertEqual(loaded.host, "192.168.1.23")
        XCTAssertNil(loaded.token)
    }

    /// ループバック **かつ token 無し**のときだけ persist しても書かない(既存挙動の維持)
    func testLoopbackWithoutTokenPersistRemovesFile() {
        let url = root.appendingPathComponent(".fleetest/bridge-8901.endpoint")
        BridgeEndpoint(host: "192.168.1.23", port: 8901, token: "deadbeef").persist(repoRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        BridgeEndpoint(port: 8901).persist(repoRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// **ループバックでも token を持つなら書く**(usb トンネルの実機)。判定は「ループバックか」
    /// ではなく「token を持つか」——ここが変わらないと establish(usb) の戻り値が別プロセス・
    /// 再接続から一生読めない(IOSDeviceTransport.establish の usb 分岐と対)
    func testLoopbackWithTokenPersistWritesTheFile() {
        let url = root.appendingPathComponent(".fleetest/bridge-8901.endpoint")
        BridgeEndpoint(port: 8901, token: "usb-token").persist(repoRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "loopback + token の persist はファイルを書くこと(usb トンネルの実機)")
        let loaded = BridgeEndpoint.load(port: 8901, repoRoot: root)
        XCTAssertEqual(loaded.host, BridgeEndpoint.loopbackHost)
        XCTAssertEqual(loaded.token, "usb-token")
    }
}
