// IOSDeviceTransport.establish の usb 分岐が token を落とさないことの固定。
//
// 修正前: 「usb はループバックを維持する(トンネルはホスト内で完結)ので認証は不要」という
// コメントの通りに `BridgeEndpoint(port: port)` を組んでおり、token を渡していなかった。
// 実際は認証を要求するのはブリッジ側(実機は 0.0.0.0 に bind するため FT_BIND_ALL=1 で
// fail-closed に token を要求する。BridgeLauncher.bridgeToken / BridgeDTO.bridgeTokenRequired
// 参照)なので、経路(lan/usb)に関わらず token が要る。この誤りにより USB 接続の iPhone は
// ブリッジ起動のたびに 401 で失敗していた(iPhone 13 実機で確認)。
//
// establish 本体は iproxy プロセスの起動を伴うため、endpoint の組み立てだけを
// `IOSDeviceTransport.usbEndpoint(port:token:)` へ切り出してここで検証する。

import XCTest
@testable import FTBridgeClient

final class IOSDeviceTransportUSBTokenTests: XCTestCase {

    func testUSBEndpointCarriesTheToken() {
        let endpoint = IOSDeviceTransport.usbEndpoint(port: 8123, token: "abc123")
        XCTAssertEqual(endpoint.host, BridgeEndpoint.loopbackHost,
                      "usb トンネルの到達先は常にループバック")
        XCTAssertEqual(endpoint.token, "abc123",
                      "usb でも token を落とさないこと(実機のブリッジは host を問わず認証を要求する)")
    }

    /// 逆方向も固定する(「常に非nilを返す」変異と「常にnilを返す」変異の両方を落とす)
    func testUSBEndpointWithoutATokenStaysNil() {
        let endpoint = IOSDeviceTransport.usbEndpoint(port: 8123, token: nil)
        XCTAssertNil(endpoint.token)
    }
}
