// SimulatorCatalog.isPhysical(udid:simulators:physicalDevices:) を固定する。
//
// 実機 UDID は 25 文字型・旧 40 桁 hex 型があり、シミュレータの「36 文字・ダッシュ5分割」判定を
// 外れる(BridgeLauncher.physical の doc コメント参照)。この判定を**形状**でやり直すと、
// LiveBridgeAutoStarter が実機に対して常にシミュレータ扱いで起動を試み、DerivedData と
// -destination をシミュレータ用のまま実機へ向けて確実に失敗する。

import XCTest
@testable import FTBridgeClient

final class PhysicalUDIDDetectionTests: XCTestCase {

    private func simulator(udid: String) -> SimDeviceInfo {
        SimDeviceInfo(udid: udid, name: "iPhone 17 Pro", os: "iOS 27.0", booted: true,
                      physical: false, wired: true)
    }

    private func phone(udid: String) -> IOSPhysicalDeviceInfo {
        IOSPhysicalDeviceInfo(udid: udid, name: "wave の iPhone", os: "iOS 27.0", connected: true,
                              transport: "wired", deviceCtlIdentifier: udid, model: "iPhone17,1")
    }

    /// 実機一覧に居れば true(25 文字型の実機 UDID)
    func testPhysicalUDIDInThePhysicalListIsPhysical() {
        let udid = "00008110-001460910E0A201E"
        XCTAssertEqual(
            SimulatorCatalog.isPhysical(udid: udid, simulators: [], physicalDevices: { [phone(udid: udid)] }),
            true)
    }

    /// シミュレータ一覧に居れば false(36 文字・ダッシュ5分割の UUID)
    func testSimulatorUDIDInTheSimulatorListIsNotPhysical() {
        let udid = "12345678-1234-1234-1234-123456789ABC"
        XCTAssertEqual(
            SimulatorCatalog.isPhysical(udid: udid, simulators: [simulator(udid: udid)], physicalDevices: { [] }),
            false)
    }

    /// どちらの一覧にも無ければ nil(「実機と分からない」を false と混同しない)
    func testUnknownUDIDIsNil() {
        XCTAssertNil(SimulatorCatalog.isPhysical(
            udid: "does-not-exist", simulators: [simulator(udid: "SIM-1")],
            physicalDevices: { [phone(udid: "PHONE-1")] }))
    }

    /// **シミュレータで当たったら実機一覧を引かない**(devicectl は 0.5〜1 秒かかる。
    /// クロージャ引数はこの短絡のためだけに在るので、素の配列へ戻されたら気付けるようにする)
    func testDoesNotQueryThePhysicalListWhenTheSimulatorMatches() {
        var queried = false
        let result = SimulatorCatalog.isPhysical(
            udid: "SIM-1", simulators: [simulator(udid: "SIM-1")],
            physicalDevices: { queried = true; return [] })
        XCTAssertEqual(result, false)
        XCTAssertFalse(queried, "シミュレータで確定しているのに devicectl を引いている")
    }

    /// **形状だけでは決めていないこと**の固定: シミュレータと同じ「36 文字・ダッシュ5分割」の
    /// UDID でも、実機一覧に居れば true になる(= 一覧で決めている。形で判定に書き換えられたら
    /// この1本が落ちる)
    func testShapeDoesNotDecideItTheListDoes() {
        let udid = "12345678-1234-1234-1234-123456789ABC"
        XCTAssertEqual(
            SimulatorCatalog.isPhysical(udid: udid, simulators: [], physicalDevices: { [phone(udid: udid)] }),
            true)
    }
}
