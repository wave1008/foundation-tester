// 「一覧が未接続と言う端末を、本当に使えないと結論してよいか」の判定。
//
// `devicectl list devices` の `connection.state` は「**今**つながっているか」であって
// 「到達できるか」ではない。有線で待機中の端末は CoreDevice がトンネルを畳むので
// `disconnected` と出るが、名指しで問い合わせれば繋がる。**そこに無い端末と同じ値**なので、
// 一覧だけで「無い」と結論すると、実在して使える端末を、既に済ませた対処(Trust・
// Developer Mode)を促して拒否する(2026-09-04 実機で実測: USB の iPhone SE3 が
// list では disconnected、`devicectl device info details` は成功。E2E 34 本が
// 「no usable workers」で1本も走らなかった)。

import FTCore
import XCTest
@testable import FTBridgeClient

final class PhysicalReachabilityVerdictTests: XCTestCase {

    private func device(_ name: String, udid: String, connected: Bool,
                        transport: String = "wired") -> IOSPhysicalDeviceInfo {
        IOSPhysicalDeviceInfo(udid: udid, name: name, os: "iOS 26.6", connected: connected,
                              transport: transport)
    }

    private func spec(_ udid: String) -> DeviceSpec {
        DeviceSpec(name: "target", kind: .physical, udid: udid, engine: "xcuitest")
    }

    func testTrustsTheListWhenItSaysConnectedAndDoesNotAsk() throws {
        var probed: [String] = []
        let found = try IOSPhysicalDeviceCatalog.resolve(
            spec: spec("U1"), in: [device("SE3", udid: "U1", connected: true)],
            probe: { probed.append($0); return true })
        XCTAssertEqual(found.udid, "U1")
        XCTAssertEqual(probed, [], "一覧が接続中と言っているなら往復を払わない")
    }

    /// 本命の回帰: 一覧は未接続、実問い合わせは到達 → 使える
    func testAsksWhenTheListSaysDisconnectedAndAcceptsAReachableDevice() throws {
        var probed: [String] = []
        let found = try IOSPhysicalDeviceCatalog.resolve(
            spec: spec("U1"), in: [device("SE3", udid: "U1", connected: false)],
            probe: { probed.append($0); return true })
        XCTAssertEqual(probed, ["U1"], "拒否する前に必ず訊く")
        XCTAssertTrue(found.connected, "確かめた事実で connected を上書きする")
    }

    func testRejectsOnlyWhenTheProbeAlsoFails() {
        XCTAssertThrowsError(try IOSPhysicalDeviceCatalog.resolve(
            spec: spec("U1"), in: [device("snb", udid: "U1", connected: false)],
            probe: { _ in false })) { error in
            guard case IOSPhysicalDeviceCatalogError.notConnected = error else {
                return XCTFail("expected notConnected, got \(error)")
            }
        }
    }

    /// 断定するのは訊いたあとだけなので、文言も「届かない」と言い切ってよい
    func testTheRefusalSaysItAlsoAskedDirectly() {
        let message = IOSPhysicalDeviceCatalogError
            .notConnected(udid: "U1", name: "iPhone snb", transport: "wired")
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("devicectl query"),
                      "一覧だけで言っていないことが読み手に伝わること: \(message)")
    }

    func testConfirmedConnectedIsTheSingleVerdict() {
        let listed = device("A", udid: "U1", connected: true)
        let unlisted = device("B", udid: "U2", connected: false)
        XCTAssertTrue(IOSPhysicalDeviceCatalog.confirmedConnected(listed, probe: { _ in false }))
        XCTAssertTrue(IOSPhysicalDeviceCatalog.confirmedConnected(unlisted, probe: { _ in true }))
        XCTAssertFalse(IOSPhysicalDeviceCatalog.confirmedConnected(unlisted, probe: { _ in false }))
    }
}
