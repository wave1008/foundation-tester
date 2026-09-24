// profile 無しの MCP が「既定ポートに誰も居ない」ときにどう振る舞うか。
//
// ここが緩むと 2026-08-06 のフィードバック #2 が再発する(bridge up が 8124 を選び、
// MCP は 8123 を叩き続けて全ツールがタイムアウト)。逆に緩みすぎると **別デバイスの
// ブリッジを黙って掴む** —— 複数本のときに自動採用しないことが安全側の要点。
//
// 走査そのもの(scan/isAlive)はネットワークなのでここでは扱わない。判断と文言だけを固める。

import XCTest
@testable import FTBridgeClient
import FTCore

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

    /// 1本だけなら自動採用(ユーザー決定)
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

    /// 名前引きは**最後の手段**(旧ブリッジは udid を申告せず記録も持たない)。
    /// 申告・記録のどちらかがあればそちらが勝つ —— 同名 sim が複数 booted のとき、
    /// 名前引きを先に見ると一意に決まらず nil へ落ちて二重起動を許す
    func testResolveUDIDUsesTheNameMatchOnlyAsALastResort() {
        XCTAssertEqual(BridgeDiscovery.resolveUDID(reported: "REPORTED", recorded: nil,
                                                   matchedByName: "BY-NAME"), "REPORTED")
        XCTAssertEqual(BridgeDiscovery.resolveUDID(reported: nil, recorded: "RECORDED",
                                                   matchedByName: "BY-NAME"), "RECORDED")
        XCTAssertEqual(BridgeDiscovery.resolveUDID(reported: nil, recorded: nil,
                                                   matchedByName: "BY-NAME"), "BY-NAME")
    }

    /// **実機の形**: udid を申告せず、名前も汎用の "iPhone" でプロファイル名と
    /// 一致しないので名前引きは nil。記録が無ければ端末に紐付かず、planBridge の同一デバイス
    /// 判定に当たらないまま2本目のランナーが立つ(1台に2本立てると両方死ぬ)
    func testResolveUDIDIdentifiesAPhysicalBridgeOnlyThroughTheRecord() {
        XCTAssertNil(BridgeDiscovery.resolveUDID(reported: nil, recorded: nil, matchedByName: nil),
                     "記録が無ければ特定できない(= 記録を書くことが実機対応の前提)")
        XCTAssertEqual(BridgeDiscovery.resolveUDID(reported: nil, recorded: "00008130-0018",
                                                   matchedByName: nil), "00008130-0018")
    }

    // MARK: - 本人確認へ渡す status(statusForIdentityCheck)
    //
    // 実地 2026-09-24: 実機の XCUITest ランナーは udid を申告しないので、補わずに
    // BridgeIdentityCheck へ渡すと「一致」に倒れ、iPhone wave のライブ操作が既定ポート 8123 の
    // iPhone SE3 のブリッジを掴んで SE3 の画面を出した。

    private let wave = "00008130-001819863E60001C"
    private let se3 = "00008110-000260242EEB801E"

    private func tempRepoRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("statusForIdentityCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func physicalStatus(udid: String?) -> StatusResponse {
        var status = StatusResponse(ready: true, device: "iPhone", osVersion: "27.0", sessionBundleID: nil)
        status.engine = "xcuitest"
        status.udid = udid
        return status
    }

    func testUnreportedUDIDIsFilledFromTheRecordSoAnotherPhysicalBridgeIsRejected() throws {
        let root = try tempRepoRoot()
        BridgeDeviceRecord.persist(udid: se3, port: 8123, repoRoot: root)
        let status = BridgeDiscovery.statusForIdentityCheck(physicalStatus(udid: nil), port: 8123, repoRoot: root)
        XCTAssertEqual(status.udid, se3, "申告が無ければ記録で補う")
        let expected = BridgeIdentityCheck.Expected(port: 8123, udid: wave, physical: true, engine: "xcuitest")
        XCTAssertFalse(BridgeIdentityCheck.matches(expected: expected, status: status),
                       "記録が別の実機なら、そのブリッジを自分のものとして掴まない")
        let own = BridgeIdentityCheck.Expected(port: 8123, udid: se3, physical: true, engine: "xcuitest")
        XCTAssertTrue(BridgeIdentityCheck.matches(expected: own, status: status), "記録が自分なら一致")
    }

    func testReportedUDIDWinsOverTheRecord() throws {
        let root = try tempRepoRoot()
        BridgeDeviceRecord.persist(udid: se3, port: 8123, repoRoot: root)
        let status = BridgeDiscovery.statusForIdentityCheck(physicalStatus(udid: "SIM-UDID"), port: 8123, repoRoot: root)
        XCTAssertEqual(status.udid, "SIM-UDID", "申告があれば記録で上書きしない")
    }

    func testNoRecordLeavesTheStatusAsReported() throws {
        let root = try tempRepoRoot()
        XCTAssertNil(BridgeDiscovery.statusForIdentityCheck(physicalStatus(udid: nil), port: 8123, repoRoot: root).udid)
        XCTAssertNil(BridgeDiscovery.statusForIdentityCheck(physicalStatus(udid: nil), port: 8123, repoRoot: nil).udid)
    }

    /// ライブ操作の本人確認2か所が補完を通すこと(通さないと上の3本が緑のまま実害が戻る)
    func testLiveIdentityChecksFillTheUDIDFromTheRecord() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest")
        for file in ["ApiLiveCommand.swift", "LiveBridgeAutoStarter.swift"] {
            let code = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertTrue(code.contains("BridgeDiscovery.statusForIdentityCheck("),
                          "\(file) は本人確認の前に statusForIdentityCheck を通すこと")
        }
    }

    // MARK: - transportFailed の再分類(resolveTransportFailure。B4)
    //
    // 実地 2026-09-22: 忙しい XCUITest(pid は生きたままアプリの quiescence 待ちで数十秒
    // ブロック)の listen backlog が溢れると、他クライアントの connect は即座に切れ、
    // 固まった実機の iproxy と同じ指紋(`.transportFailed`)になる。loopback(シミュレータ)側は
    // listener の実体を確かめ、iproxy トンネルでないと分かったときだけ `.timedOut`(busy)へ倒す。

    /// timedOut はそもそも再分類の対象外(他の入力に関わらず変わらない)
    func testResolveTransportFailureLeavesTimedOutUnchanged() {
        XCTAssertEqual(
            BridgeDiscovery.resolveTransportFailure(
                classification: .timedOut, isLoopback: true,
                listenerExists: true, listenerIsTunnelOnly: false),
            .timedOut)
    }

    /// LAN(実機を Wi-Fi 越しに叩く)は再分類の対象外 —— 実測は固まった実機の iproxy でだけ取った
    func testResolveTransportFailureLeavesLANUnchanged() {
        XCTAssertEqual(
            BridgeDiscovery.resolveTransportFailure(
                classification: .transportFailed, isLoopback: false,
                listenerExists: true, listenerIsTunnelOnly: false),
            .transportFailed)
    }

    /// listener を確認できなかった(lsof が拾えない等)は「わからないから消えたことにする」に
    /// 倒さない —— 元の分類のまま残す
    func testResolveTransportFailureLeavesUnconfirmedListenerUnchanged() {
        XCTAssertEqual(
            BridgeDiscovery.resolveTransportFailure(
                classification: .transportFailed, isLoopback: true,
                listenerExists: false, listenerIsTunnelOnly: false),
            .transportFailed)
    }

    /// listener が iproxy トンネルだった(本物の固まった転送)はそのまま残す
    func testResolveTransportFailureLeavesATunnelOnlyListenerUnchanged() {
        XCTAssertEqual(
            BridgeDiscovery.resolveTransportFailure(
                classification: .transportFailed, isLoopback: true,
                listenerExists: true, listenerIsTunnelOnly: true),
            .transportFailed)
    }

    /// loopback + listener あり + トンネルでない、と**肯定的に**読めたときだけ busy へ読み替える
    func testResolveTransportFailureReclassifiesABusySimulatorRunnerAsTimedOut() {
        XCTAssertEqual(
            BridgeDiscovery.resolveTransportFailure(
                classification: .transportFailed, isLoopback: true,
                listenerExists: true, listenerIsTunnelOnly: false),
            .timedOut)
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
