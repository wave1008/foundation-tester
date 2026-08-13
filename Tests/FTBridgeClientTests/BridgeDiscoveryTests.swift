// profile 無しの MCP が「既定ポートに誰も居ない」ときにどう振る舞うか。
//
// ここが緩むと 2026-08-06 のフィードバック #2 が再発する(bridge up が 8124 を選び、
// MCP は 8123 を叩き続けて全ツールがタイムアウト)。逆に緩みすぎると **別デバイスの
// ブリッジを黙って掴む** —— 複数本のときに自動採用しないことが安全側の要点。
//
// 走査そのもの(scan/isAlive)はネットワークなのでここでは扱わない。判断と文言だけを固める。

import XCTest
@testable import FTBridgeClient

final class BridgeDiscoveryTests: XCTestCase {

    private func found(_ port: UInt16, _ device: String = "iPhone 17 Pro",
                       _ engine: String = "xcuitest") -> BridgeDiscovery.Found {
        BridgeDiscovery.Found(port: port, device: device, engine: engine)
    }

    /// 既定ポートが生きていれば探索結果に関わらずそれを使う(従来挙動を変えない)
    func testAlivePreferredPortWins() {
        XCTAssertEqual(BridgeDiscovery.decide(preferredAlive: true, preferredBound: true,
                                              found: [found(8130)]),
                       .usePreferred)
    }

    /// 1本だけなら自動採用(ユーザー決定 2026-08-06)
    func testAdoptsTheOnlyRunningBridge() {
        XCTAssertEqual(BridgeDiscovery.decide(preferredAlive: false, preferredBound: false,
                                              found: [found(8124)]),
                       .adopt(found(8124)))
    }

    /// **複数なら自動採用しない**: 別デバイスを黙って操作させない
    func testMultipleBridgesAreAmbiguous() {
        let decision = BridgeDiscovery.decide(
            preferredAlive: false, preferredBound: false,
            found: [found(8130, "iPad Pro"), found(8124)])
        XCTAssertEqual(decision, .ambiguous([found(8124), found(8130, "iPad Pro")]),
                       "ポート昇順で提示すること")
    }

    func testNoBridgeAtAll() {
        XCTAssertEqual(BridgeDiscovery.decide(preferredAlive: false, preferredBound: false,
                                              found: []), .none)
    }

    /// **待受しているのに応答しないだけなら乗り換えない**(2026-08-06 のログ: quiescence 待ちで
    /// 33.7 秒ブロックした実績がある)。ここが緩むと別デバイスを黙って操作する
    func testBoundButSilentPreferredIsNeverAbandoned() {
        XCTAssertEqual(BridgeDiscovery.decide(preferredAlive: false, preferredBound: true,
                                              found: [found(8124)]),
                       .preferredBusy, "1本しか無くても乗り換えてはいけない")
        XCTAssertEqual(BridgeDiscovery.decide(preferredAlive: false, preferredBound: true,
                                              found: []),
                       .preferredBusy, "他に居なくても「無い」ではなく「今は忙しい」")
    }

    /// 待たせる側の文言は、**死んでいないこと**と再試行を言うこと
    func testBusyMessageSaysItIsNotGone() {
        let busy = BridgeDiscovery.busyMessage(preferred: 8123)
        XCTAssertTrue(busy.contains("8123"), busy)
        XCTAssertTrue(busy.contains("not gone"), busy)
        XCTAssertTrue(busy.contains("Retry"), busy)
        XCTAssertTrue(busy.contains("different device"), busy)
    }

    // MARK: - udid の優先順位(status の申告 vs BridgeDeviceRecord の記録)

    /// 仮想デバイスは自分で正しい udid を出すので、記録が古くてもそちらを信じてはいけない
    func testResolveUDIDPrefersReportedOverRecorded() {
        XCTAssertEqual(BridgeDiscovery.resolveUDID(reported: "REPORTED", recorded: "RECORDED"),
                       "REPORTED")
    }

    /// 実機は申告できないので記録で補う(欠陥②の前提)
    func testResolveUDIDFallsBackToRecordedWhenNotReported() {
        XCTAssertEqual(BridgeDiscovery.resolveUDID(reported: nil, recorded: "RECORDED"), "RECORDED")
    }

    func testResolveUDIDIsNilWhenNeitherIsPresent() {
        XCTAssertNil(BridgeDiscovery.resolveUDID(reported: nil, recorded: nil))
    }

    /// 文言はそのまま利用者(エージェント)への指示になる。**次の一手が書かれていること**
    func testMessagesCarryPortsDevicesAndTheNextStep() {
        let adopted = BridgeDiscovery.adoptedNote(preferred: 8123, found: found(8124))
        XCTAssertTrue(adopted.contains("8123"), adopted)
        XCTAssertTrue(adopted.contains("8124"), adopted)
        XCTAssertTrue(adopted.contains("iPhone 17 Pro"), adopted)

        let ambiguous = BridgeDiscovery.ambiguousMessage(
            preferred: 8123, found: [found(8124), found(8130, "iPad Pro")])
        XCTAssertTrue(ambiguous.contains("8124"), ambiguous)
        XCTAssertTrue(ambiguous.contains("iPad Pro"), ambiguous)
        XCTAssertTrue(ambiguous.contains("port:"), ambiguous)
        XCTAssertTrue(ambiguous.contains("profile:"), ambiguous)

        let none = BridgeDiscovery.noBridgeMessage(preferred: 8123)
        XCTAssertTrue(none.contains("bridge up"), none)
        XCTAssertTrue(none.contains("\(BridgeDiscovery.portRange.upperBound)"), none)
    }
}
