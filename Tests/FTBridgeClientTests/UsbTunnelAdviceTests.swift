// USB トンネル(iproxy)越しの実機だけに、ドライバのエラーへ注記を足すことの固定。
// lanTransportAdvice との排他(実機の LAN 接続はループバックでない・実機以外は常にループバック)も
// ここで固定する。
import XCTest
@testable import FTBridgeClient

final class UsbTunnelAdviceTests: XCTestCase {

    private func advice(_ url: String, physicalUDID: String?) -> String {
        BridgeClient.usbTunnelAdvice(baseURL: URL(string: url)!, physicalUDID: physicalUDID)
    }

    func testPhysicalDeviceOverLoopbackIsNamed() {
        let text = advice("http://127.0.0.1:8123", physicalUDID: "00008030-ABC")
        XCTAssertTrue(text.contains("USB tunnel"), text)
        XCTAssertTrue(text.contains("iproxy"), text)
        XCTAssertTrue(text.contains("cable"), text)
    }

    func testSimulatorOverLoopbackSaysNothing() {
        XCTAssertEqual(advice("http://127.0.0.1:8123", physicalUDID: nil), "")
    }

    func testPhysicalDeviceOverLanSaysNothing() {
        // LAN の実機は lanTransportAdvice が受け持つ(対の注記が両方付くと矛盾した助言になる)
        XCTAssertEqual(advice("http://192.168.20.5:8127", physicalUDID: "00008030-ABC"), "")
    }

    func testAdvicesAreMutuallyExclusive() {
        for (url, physicalUDID) in [
            ("http://127.0.0.1:8123", nil), ("http://127.0.0.1:8123", "00008030-ABC"),
            ("http://192.168.20.5:8127", nil), ("http://192.168.20.5:8127", "00008030-ABC"),
        ] as [(String, String?)] {
            let lan = BridgeClient.lanTransportAdvice(baseURL: URL(string: url)!)
            let usb = advice(url, physicalUDID: physicalUDID)
            XCTAssertTrue(lan.isEmpty || usb.isEmpty, "both fired for \(url) physicalUDID=\(String(describing: physicalUDID))")
        }
    }
}
