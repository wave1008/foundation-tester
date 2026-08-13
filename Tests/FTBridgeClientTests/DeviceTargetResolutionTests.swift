// simctl / devicectl の**対象の決め方**を固定する。
//
// /status はデバイス名しか返さないので、名前から相手を引き当てる必要がある。ここが緩むと
// **実機を繋いだときに名前をそのまま simctl へ渡す**ことになり、
//   - 良くて「Invalid device」という的外れな失敗(利用者は原因を追えない)
//   - 悪ければ**同名のシミュレータが起動していればそちらを操作する**(消去・インストールの誤爆)
// になる。install / uninstall / clearAppData の3経路が同じ決め方を共有する。

import XCTest
@testable import FTBridgeClient

final class DeviceTargetResolutionTests: XCTestCase {

    private func device(_ name: String, udid: String, booted: Bool = true) -> SimDeviceInfo {
        SimDeviceInfo(udid: udid, name: name, os: "iOS 27.0", booted: booted,
                      physical: false, wired: true)
    }

    private func phone(_ name: String, udid: String) -> IOSPhysicalDeviceInfo {
        IOSPhysicalDeviceInfo(udid: udid, name: name, os: "iOS 27.0", connected: true,
                              transport: "wired", deviceCtlIdentifier: udid, model: "iPhone17,1")
    }

    private func resolve(_ name: String, simulators: [SimDeviceInfo]?,
                         phones: [IOSPhysicalDeviceInfo]? = []) -> BridgeClient.ResolvedTarget {
        BridgeClient.resolveTarget(named: name, simulators: simulators, physicalDevices: { phones })
    }

    func testBootedSimulatorResolvesToItsUDID() {
        XCTAssertEqual(resolve("iPhone 17 Pro", simulators: [device("iPhone 17 Pro", udid: "SIM-1")]),
                       .simulator(udid: "SIM-1"))
    }

    /// **実機は実機として返す**(呼び出し側が devicectl へ回す / simctl 系は 501 で断る)
    func testPhysicalDeviceIsIdentifiedAsPhysical() {
        XCTAssertEqual(resolve("wave の iPhone", simulators: [],
                               phones: [phone("wave の iPhone", udid: "PHONE-1")]),
                       .physical(udid: "PHONE-1"))
    }

    /// **起動していないシミュレータは掴まない**(操作できないので名前解決としても誤り)
    func testShutdownSimulatorIsNotUsed() {
        XCTAssertEqual(resolve("iPhone 17 Pro",
                               simulators: [device("iPhone 17 Pro", udid: "SIM-1", booted: false)]),
                       .unknown(name: "iPhone 17 Pro"))
    }

    /// **同名のシミュレータと実機が並んでいてもシミュレータを優先する**(booted な方が
    /// ブリッジの相手である公算が高い)。実機を狙うなら profile 経由で UDID が渡る
    func testBootedSimulatorWinsOverASamedNamedPhysicalDevice() {
        XCTAssertEqual(resolve("iPhone 17 Pro", simulators: [device("iPhone 17 Pro", udid: "SIM-1")],
                               phones: [phone("iPhone 17 Pro", udid: "PHONE-1")]),
                       .simulator(udid: "SIM-1"))
    }

    /// **実機一覧は必要なときだけ引く**(devicectl は数百 ms かかる)。
    /// シミュレータに同名が居れば、実機一覧は評価されない
    func testThePhysicalCatalogIsOnlyConsultedWhenNoSimulatorMatches() {
        var consulted = 0
        _ = BridgeClient.resolveTarget(named: "iPhone 17 Pro",
                                       simulators: [device("iPhone 17 Pro", udid: "SIM-1")],
                                       physicalDevices: { consulted += 1; return [] })
        XCTAssertEqual(consulted, 0, "シミュレータで決まるなら devicectl を叩かないこと")

        _ = BridgeClient.resolveTarget(named: "wave の iPhone", simulators: [],
                                       physicalDevices: { consulted += 1; return [] })
        XCTAssertEqual(consulted, 1)
    }

    /// カタログ自体が引けないのは**別種の故障**なので、従来どおり名前を渡す
    /// (ここで失敗させると、シミュレータ運用が列挙の一時的な失敗で落ちる)
    func testFallsBackToTheNameWhenTheCatalogIsUnavailable() {
        XCTAssertEqual(resolve("iPhone 17 Pro", simulators: nil),
                       .unknown(name: "iPhone 17 Pro"))
    }

    // MARK: - Safari DOM 読み取りの対象特定(`resolveTarget` とは別物 —— 実機は
    // devicectl identifier ではなく usbmuxd 用のハードウェア UDID を返す)

    private func resolveBrowserDOM(_ name: String, simulators: [SimDeviceInfo]?,
                                   phones: [IOSPhysicalDeviceInfo]? = []) -> BridgeClient.BrowserDOMTarget? {
        BridgeClient.resolveBrowserDOMTarget(named: name, simulators: simulators, physicalDevices: { phones })
    }

    func testBrowserDOMSimulatorResolvesToSimctlUDID() {
        XCTAssertEqual(resolveBrowserDOM("iPhone 17 Pro", simulators: [device("iPhone 17 Pro", udid: "SIM-1")]),
                       .simulator(udid: "SIM-1"))
    }

    /// **実機はハードウェア UDID を返す** —— `resolveTarget` の `.physical` が持つ
    /// devicectl identifier とは値が違う(`IOSPhysicalDeviceInfo.udid` を使う)。
    /// usbmuxd の ReadPairRecord/ListDevices はこちらの値でないと引けない
    func testBrowserDOMPhysicalDeviceResolvesToHardwareUDIDNotDeviceCtlIdentifier() {
        let phone = IOSPhysicalDeviceInfo(udid: "00008130-001819863E60001C", name: "wave の iPhone",
                                          os: "iOS 26.6", connected: true, transport: "wired",
                                          deviceCtlIdentifier: "2DBFD3DF-21FE-5C6C-9F5D-1210BF80726B",
                                          model: "iPhone17,1")
        XCTAssertEqual(resolveBrowserDOM("wave の iPhone", simulators: [], phones: [phone]),
                       .physical(udid: "00008130-001819863E60001C"))
    }

    func testBrowserDOMReturnsNilWhenNothingMatches() {
        XCTAssertNil(resolveBrowserDOM("unknown", simulators: [], phones: []))
    }

    // MARK: - 宛先が一意でないときは撃たない(2026-08-13)

    /// **同名のシミュレータが2台起きていたら諦める**。1つ選ぶと
    /// 別端末の Safari の画面内容をこの端末の木へ差し込むことになる
    func testAmbiguousSimulatorNameYieldsNoBrowserTarget() {
        XCTAssertNil(resolveBrowserDOM("iPhone 17 Pro",
                                       simulators: [device("iPhone 17 Pro", udid: "SIM-1"),
                                                    device("iPhone 17 Pro", udid: "SIM-2")]))
    }

    /// 一意なら従来どおり選ぶ(諦めすぎない)
    func testUniqueSimulatorNameStillResolves() {
        XCTAssertEqual(resolveBrowserDOM("iPhone 17 Pro",
                                         simulators: [device("iPhone 17 Pro", udid: "SIM-1"),
                                                      device("iPhone 16", udid: "SIM-2")]),
                       .simulator(udid: "SIM-1"))
    }
}
