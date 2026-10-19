// 子の `list --json` が親へ渡す行(`FTTestClassDescriptor.scenarioInfos`)。`@Test(scenarioTimeout:)` は
// この行に載らないと親の watchdog に届かず、黙ってプロファイル → 既定へ落ちる(どのテストも緑のまま)。

import XCTest
@testable import FTDSL

final class ScenarioListEntryTests: XCTestCase {

    func testListEntryCarriesTheScenarioMetadata() {
        let testClass = FTTestClassDescriptor(
            className: "同期", platform: "ios",
            scenarios: [
                FTScenarioDescriptor(name: "S0010", title: "全件", scenarioTimeout: 1800, run: {}),
                FTScenarioDescriptor(name: "S0020", title: "差分", deleted: true, platform: "android", run: {}),
            ])
        let entries = testClass.scenarioInfos
        XCTAssertEqual(entries, [
            ScenarioInfo(id: "同期.S0010", title: "全件", platform: "ios",
                         scenarioTimeout: 1800),
            ScenarioInfo(id: "同期.S0020", title: "差分", platform: "android",
                         deleted: true),
        ])
    }

    /// クラスの beforeAll の有無は各シナリオの行に載る。載らないと親は待たせず、beforeAll より先に
    /// 別のデバイスでそのクラスのシナリオが走る
    func testListEntryCarriesTheClassBeforeAll() {
        let withHook = FTTestClassDescriptor(
            className: "準備", scenarios: [FTScenarioDescriptor(name: "S0010", title: "", run: {})],
            hasBeforeAll: true)
        XCTAssertEqual(withHook.scenarioInfos.map(\.beforeAll), [true])
        let without = FTTestClassDescriptor(
            className: "素", scenarios: [FTScenarioDescriptor(name: "S0010", title: "", run: {})])
        XCTAssertEqual(without.scenarioInfos.map(\.beforeAll), [false])
    }
}
