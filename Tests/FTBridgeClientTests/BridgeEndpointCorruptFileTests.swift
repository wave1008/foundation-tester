// 壊れた .fleetest/bridge-<port>.endpoint(台帳)からの復旧。
//
// 実測(負荷テスト台帳 T3): この台帳の1行目に `{"broken":` のような妥当でない host を書くと、
// `BridgeClient.init` の `URL(string: "http://\(host):\(port)")!` が強制開封でクラッシュし、
// そのポートを開く全プロセス(`fleetest bridge status`・`fleetest-mcp` の呼び出しのたび)が
// 道連れで exit 133 になっていた。台帳の中身は誰も検証していなかった。
// `BridgeEndpoint.isUsableHost` が弾き、`BridgeClient.init` も loopback へのフォールバックを持つ
// (二重の備え)ので、どちらか片方が直っていればクラッシュしないはず。

import XCTest
@testable import FTBridgeClient

final class BridgeEndpointCorruptFileTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-endpoint-corrupt-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, port: UInt16) throws {
        let url = root.appendingPathComponent(".fleetest/bridge-\(port).endpoint")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 実測の再現: 1行目が JSON の破片(壊れた host)だと「記録が無かった」と同じ扱いに落ちること
    func testBrokenFirstLineFallsBackToLoopbackWithoutToken() throws {
        try write("{\"broken\":", port: 8149)
        let loaded = BridgeEndpoint.load(port: 8149, repoRoot: root)
        XCTAssertEqual(loaded.host, BridgeEndpoint.loopbackHost)
        XCTAssertNil(loaded.token)
    }

    func testEmptyFileFallsBackToLoopback() throws {
        try write("", port: 8150)
        let loaded = BridgeEndpoint.load(port: 8150, repoRoot: root)
        XCTAssertEqual(loaded.host, BridgeEndpoint.loopbackHost)
        XCTAssertNil(loaded.token)
    }

    func testWhitespaceOnlyFileFallsBackToLoopback() throws {
        try write("   \t  ", port: 8151)
        let loaded = BridgeEndpoint.load(port: 8151, repoRoot: root)
        XCTAssertEqual(loaded.host, BridgeEndpoint.loopbackHost)
        XCTAssertNil(loaded.token)
    }

    /// 既存契約の回帰: 正常な LAN IP だけの1行はそのまま host として読めること
    func testValidLANHostOnlyLoadsThatHostWithNilToken() throws {
        try write("192.168.1.23", port: 8152)
        let loaded = BridgeEndpoint.load(port: 8152, repoRoot: root)
        XCTAssertEqual(loaded.host, "192.168.1.23")
        XCTAssertNil(loaded.token)
    }

    /// 既存契約の回帰: host が妥当なら2行目の token も読めること
    func testValidLANHostWithTokenLoadsBoth() throws {
        try write("192.168.1.23\ndeadbeef", port: 8153)
        let loaded = BridgeEndpoint.load(port: 8153, repoRoot: root)
        XCTAssertEqual(loaded.host, "192.168.1.23")
        XCTAssertEqual(loaded.token, "deadbeef")
    }

    /// **1行目が壊れていれば2行目(token)も信用しない**こと(host だけ直しても token 側の
    /// 妥当性は見ていないので、host が無効な時点で全体を「記録無し」に倒す契約を固定する)
    func testBrokenFirstLineIgnoresASecondLineToken() throws {
        try write("{\"broken\":\nsome-token", port: 8154)
        let loaded = BridgeEndpoint.load(port: 8154, repoRoot: root)
        XCTAssertEqual(loaded.host, BridgeEndpoint.loopbackHost)
        XCTAssertNil(loaded.token)
    }

    /// **核心の回帰対象**: 壊れた台帳から作った `BridgeEndpoint` を丸ごと `BridgeClient` へ渡しても
    /// クラッシュしないこと(以前は `URL(string:)!` が強制開封で exit 133 していた)。
    /// `BridgeEndpoint.load` が既にループバックへ倒すので host は常に妥当だが、
    /// `BridgeClient.init` 側の二重の備え(loopback フォールバック)もここで一緒に確かめる
    func testBridgeClientDoesNotCrashOnEndpointLoadedFromACorruptFile() throws {
        try write("{\"broken\":", port: 8155)
        let endpoint = BridgeEndpoint.load(port: 8155, repoRoot: root)
        let client = BridgeClient(endpoint: endpoint)
        XCTAssertEqual(client.baseURL.host, BridgeEndpoint.loopbackHost)
        XCTAssertEqual(client.baseURL.port, 8155)
    }

    /// `BridgeClient.init` 単体の備え: `BridgeEndpoint.load` を経由せず、直接使えない host を
    /// 渡してもクラッシュせず loopback へ倒れること(host 検証がここ1箇所に依存しないための保険)
    func testBridgeClientInitFallsBackToLoopbackForAnUnusableHostLiteral() {
        let client = BridgeClient(endpoint: BridgeEndpoint(host: "{\"broken\":", port: 8156))
        XCTAssertEqual(client.baseURL.host, BridgeEndpoint.loopbackHost)
        XCTAssertEqual(client.baseURL.port, 8156)
    }
}
