// 実機を LAN(WiFi)で掴んでいるときだけ、ドライバのエラーに注記を足すことの固定。
// ループバック(シミュレータ・Android・USB トンネル)に足すと、無関係な失敗へ
// 「USB にしろ」という誤った助言が付く。
import XCTest
@testable import FTBridgeClient

final class LanTransportAdviceTests: XCTestCase {

    private func advice(_ url: String) -> String {
        BridgeClient.lanTransportAdvice(baseURL: URL(string: url)!)
    }

    func testPhysicalDeviceOverLanIsNamed() {
        let text = advice("http://192.168.20.5:8127")
        XCTAssertTrue(text.contains("192.168.20.5"), text)
        XCTAssertTrue(text.contains("libimobiledevice"), text)
        // 既に建っているブリッジは LAN のまま再利用されるので、建て直しまで言わないと直せない
        XCTAssertTrue(text.contains("bridge down"), text)
    }

    func testLoopbackSaysNothing() {
        XCTAssertEqual(advice("http://127.0.0.1:8123"), "")
    }
}
