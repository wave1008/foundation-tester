// PortHolder.stopIfOwnedBridge の iproxy 分岐は lsof/kill を伴うため、所有判定だけを
// classifyIproxy/commandIsIproxyForPort に切り出して固定する(F8: 台帳を見ずに「第1引数が
// ポート一致なら自分の資産」と判定していたため、別プロセスが張った実機の USB トンネルを
// 誤って kill した。sim -01 用に採番したポートが実機 SE3 のトンネルと衝突し、実機レーンが
// 全滅した上、跡地のシミュレータ in-app ブリッジが実機向けシナリオを代わりに実行して
// 誤った PASS を作った)。

import XCTest
@testable import FTBridgeClient

final class PortHolderClassifyTests: XCTestCase {

    // MARK: - commandIsIproxyForPort

    func testCommandMatchesIproxyForExactPort() {
        XCTAssertTrue(PortHolder.commandIsIproxyForPort(
            "/opt/homebrew/bin/iproxy 8138 8138 -u 00008030-ABC", port: 8138))
    }

    func testCommandDoesNotMatchDifferentPort() {
        XCTAssertFalse(PortHolder.commandIsIproxyForPort(
            "/opt/homebrew/bin/iproxy 8139 8139 -u 00008030-ABC", port: 8138))
    }

    func testNonIproxyCommandNeverMatches() {
        XCTAssertFalse(PortHolder.commandIsIproxyForPort(
            "/usr/bin/xcodebuild test-without-building -destination id=8138", port: 8138))
    }

    // MARK: - classifyIproxy(recordedDeviceUDID:ownerUDID:)

    func testMatchingRecordedAndOwnerUDIDIsOwned() {
        XCTAssertEqual(
            PortHolder.classifyIproxy(recordedDeviceUDID: "SE3-UDID", ownerUDID: "SE3-UDID"),
            .owned)
    }

    func testMismatchedUDIDIsForeign() {
        // F8 の実測そのもの: 採番側は sim -01(別 UDID)を供給しようとしていた
        XCTAssertEqual(
            PortHolder.classifyIproxy(recordedDeviceUDID: "SE3-UDID", ownerUDID: "SIM-01-UDID"),
            .foreign)
    }

    func testNoRecordedUDIDIsForeign() {
        XCTAssertEqual(
            PortHolder.classifyIproxy(recordedDeviceUDID: nil, ownerUDID: "SIM-01-UDID"),
            .foreign)
    }

    func testNoOwnerUDIDIsForeign() {
        // 呼び手が対象デバイスを渡していない(既定 nil の呼び出し元)ときは、確認できない
        // 資産として安全側(.foreign)に倒す ——決して「渡し忘れたから殺してよい」にしない
        XCTAssertEqual(
            PortHolder.classifyIproxy(recordedDeviceUDID: "SE3-UDID", ownerUDID: nil),
            .foreign)
    }
}
