// 画面が2枚以上の Simulator(Duo)では /screenshot に表示中の画面の display= を付ける(Runner の DisplayRouting と対)。
// 付けるかどうかはランナーの /status の multiDisplay だけで決める(純粋関数 BridgeClient.screenCapture)。

import FTCore
import XCTest

@testable import FTBridgeClient

final class BridgeClientScreenCaptureTests: XCTestCase {
    private func status(multiDisplay: Bool?, udid: String?) -> StatusResponse {
        StatusResponse(ready: true, device: "iPhone Duo", osVersion: "iOS 27.2", sessionBundleID: nil,
                       bridge: "xcuitest", udid: udid, multiDisplay: multiDisplay)
    }

    func testSingleDisplayRunnerIsPhotographedAsBefore() {
        XCTAssertEqual(BridgeClient.screenCapture(status: status(multiDisplay: nil, udid: "U1"), simulatorUDID: nil),
                       .single)
        XCTAssertEqual(BridgeClient.screenCapture(status: status(multiDisplay: false, udid: "U1"), simulatorUDID: nil),
                       .single)
    }

    /// 自己申告の udid を呼び手の udid より優先する(/status は常に今のランナー)
    func testMultiDisplayUsesTheRunnersUDID() {
        XCTAssertEqual(BridgeClient.screenCapture(status: status(multiDisplay: true, udid: "U1"), simulatorUDID: "U2"),
                       .multiDisplay(udid: "U1"))
        XCTAssertEqual(BridgeClient.screenCapture(status: status(multiDisplay: true, udid: nil), simulatorUDID: "U2"),
                       .multiDisplay(udid: "U2"))
    }

    /// udid が分からなくても single に倒さない(倒すと display= 無しで撮りに行き、ランナーに断られるか外側を撮る)
    func testMultiDisplayWithoutUDIDStaysMultiDisplay() {
        XCTAssertEqual(BridgeClient.screenCapture(status: status(multiDisplay: true, udid: nil), simulatorUDID: nil),
                       .multiDisplay(udid: ""))
    }

    func testStatusRoundTripsMultiDisplay() throws {
        let data = try JSONEncoder().encode(status(multiDisplay: true, udid: "U1"))
        XCTAssertEqual(try JSONDecoder().decode(StatusResponse.self, from: data).multiDisplay, true)
    }
}
