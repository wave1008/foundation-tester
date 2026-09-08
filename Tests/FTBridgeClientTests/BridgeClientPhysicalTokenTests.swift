// BridgeClient のトークン解決(実機接続時に X-FT-Token を載せるか)の固定。
//
// 背景: iOS 実機を USB(iproxy トンネル)で使うと、ブリッジ自身は listen まで到達するのに
// 認証だけが 401 で弾かれ続けていた。原因は2つ:
//   ① IOSDeviceTransport.establish の usb 分岐が token を落としていた
//      (「usb はループバックを維持するので認証は不要」という誤ったコメントの通りに実装していた)
//   ② BridgeClient が token の要否を「宛先がループバックか」から推測していた
//      (usb トンネルは到達先こそループバックだが、ブリッジ側は host を問わず FT_BIND_ALL=1 で
//      fail-closed に認証を要求する。IOSDeviceTransport.establish のコメント参照)
// ①は IOSDeviceTransportUSBTokenTests、②はここで固定する。

import XCTest
@testable import FTBridgeClient

final class BridgeClientPhysicalTokenTests: XCTestCase {

    /// **核心の回帰対象**: `BridgeEndpoint(port:token:)` を丸ごと渡す init は、
    /// host がループバック(usb トンネル)でも token をそのまま運ぶこと。
    /// 修正前はこの組み合わせ(ループバック + token あり)を表現する経路自体が無く、
    /// `host == loopback` だけを見て token を常に nil にしていた
    func testEndpointInitCarriesTheTokenEvenWhenHostIsLoopback() {
        let endpoint = BridgeEndpoint(port: 59991, token: "usb-secret")
        XCTAssertEqual(endpoint.host, BridgeEndpoint.loopbackHost)
        let client = BridgeClient(endpoint: endpoint)
        XCTAssertEqual(client.token, "usb-secret",
                      "endpoint 経由なら host がループバックでも token を保持すること"
                      + "(usb トンネルの実機はこの組み合わせで接続する)")
    }

    /// endpoint 経由の token を明示的に渡した場合(nil)も、そのまま反映されること
    /// (endpoint init が独自の推測へフォールバックしないことの確認)
    func testEndpointInitWithoutATokenStaysNil() {
        let client = BridgeClient(endpoint: BridgeEndpoint(port: 59992))
        XCTAssertNil(client.token)
    }

    /// **退行防止**: シミュレータ相当(host 省略 = ループバック・physicalUDID 無し)の
    /// 既定呼び出しは、以前と同じく token を送らないこと。壊すと全シミュレータ呼び出しに
    /// 無駄な X-FT-Token ヘッダが付く(有害ではないが、シミュレータのポートスキャンで
    /// 当たらない台帳読みが 32 ポート分増える性能退行にもなる)
    func testDefaultLoopbackConstructionWithoutPhysicalUDIDStaysTokenless() {
        let client = BridgeClient(port: 59993)
        XCTAssertNil(client.token,
                     "host 省略・physicalUDID 無しはシミュレータの既定経路。token は付かないこと")
    }

    /// **inferredToken の短絡だけを直接固定する**(ディスク I/O 前の判定)。
    /// host がループバックで physicalUDID も無いときは `RepoRoot.find()` すら呼ばず nil を返す
    /// (BridgeDiscovery のポート範囲走査で当たらない読みを増やさないための最適化。
    /// IOSDeviceTransport.establish のコメントと対)
    func testInferredTokenShortCircuitsForLoopbackWithoutPhysicalUDID() {
        XCTAssertNil(BridgeClient.inferredToken(
            host: BridgeEndpoint.loopbackHost, port: 59994, physicalUDID: nil))
    }
}
