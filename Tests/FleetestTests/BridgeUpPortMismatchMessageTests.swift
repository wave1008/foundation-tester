// `fleetest bridge up` が要求ポートと違うポートで起動したときの文言(M11)。provision() の戻り値は
// 「稼働中ブリッジを再利用した」のか「要求ポートが別ブリッジに塞がれていたので新規に立てた」のかを
// 教えないため、以前は後者(新規起動)にも「再利用した。元のポートで作り直すには今のポートを止めて
// 撃ち直せ」という事実と食い違う案内を出していた(実測 2026-09-17: --port 省略、8123 は別デバイスの
// ブリッジの台帳ポートだったので 8128 に新規起動したのに「Reused … (port 8128) … stop it first with
// `bridge down --port 8128`」と出た。8128 を止めても 8123 を塞いでいるのは別デバイスなので直らない)。

import XCTest
@testable import fleetest

final class BridgeUpPortMismatchMessageTests: XCTestCase {

    func testAPortFoundInThePreexistingSetIsReportedAsReused() {
        XCTAssertEqual(
            Bridge.Up.portMismatchReason(actualPort: 8130, preexistingPorts: [8130, 8140]),
            .reusedExistingBridge)
    }

    func testAPortNotInThePreexistingSetIsReportedAsANewLaunch() {
        XCTAssertEqual(
            Bridge.Up.portMismatchReason(actualPort: 8128, preexistingPorts: []),
            .startedOnAnotherPort)
    }

    /// 再利用のときだけ「今動いているポートを止めて撃ち直せ」と言ってよい
    /// (この台にはそのポートで既にブリッジがあったので、止めて再実行すれば要求ポートに戻れる)
    func testTheReusedMessageNamesTheActualPortAsTheOneToStop() {
        let text = Bridge.Up.portMismatchMessage(actualPort: 8130, requestedPort: 8123,
                                                  reason: .reusedExistingBridge,
                                                  requestedPortHeldByOther: false)
        XCTAssertTrue(text.contains("Reused"), text)
        XCTAssertTrue(text.contains("bridge down --port 8130"), text)
    }

    /// 本命(M11): 新規起動のときは「再利用」と言わず、止める案内も出さない
    /// (要求ポートを塞いでいるのは別の台のブリッジのことがある = 実測では iPhone 13 の LAN ブリッジ)
    func testTheNewLaunchMessageDoesNotClaimReuseOrSuggestStoppingAnything() {
        let text = Bridge.Up.portMismatchMessage(actualPort: 8128, requestedPort: 8123,
                                                  reason: .startedOnAnotherPort,
                                                  requestedPortHeldByOther: true)
        XCTAssertFalse(text.contains("Reused"), text)
        XCTAssertTrue(text.contains("Started the bridge on port 8128 because port 8123 is in use by another bridge"), text)
        XCTAssertFalse(text.contains("bridge down"), text)
    }

    /// N1(2026-09-18): 再利用でも、要求ポートを別の台が握っているなら止める案内は出さない
    /// (今のポートを止めても要求ポートは空かない。実測では既定 8123 が USB 実機のトンネル)
    func testTheReusedMessageDoesNotSuggestStoppingWhenTheRequestedPortBelongsToAnotherBridge() {
        let text = Bridge.Up.portMismatchMessage(actualPort: 8129, requestedPort: 8123,
                                                  reason: .reusedExistingBridge,
                                                  requestedPortHeldByOther: true)
        XCTAssertTrue(text.contains("Reused the running bridge on this device (port 8129)"), text)
        XCTAssertTrue(text.contains("8123 is in use by another bridge"), text)
        XCTAssertFalse(text.contains("bridge down"), text)
    }
}
