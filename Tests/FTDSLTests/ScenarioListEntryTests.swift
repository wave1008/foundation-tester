// 子の `list --json` が親へ渡す行(`FTTestClassDescriptor.scenarioInfos`)。`@Test(scenarioTimeout:)` は
// この行に載らないと親の watchdog に届かず、黙ってプロファイル → 既定へ落ちる(どのテストも緑のまま)。

import XCTest
@testable import FTDSL

final class ScenarioListEntryTests: XCTestCase {

    func testListEntryCarriesTheScenarioMetadata() {
        let testClass = FTTestClassDescriptor(
            className: "同期", app: "com.example", platform: "ios",
            scenarios: [
                FTScenarioDescriptor(name: "S0010", title: "全件", scenarioTimeout: 1800, run: {}),
                FTScenarioDescriptor(name: "S0020", title: "差分", deleted: true, platform: "android", run: {}),
            ])
        let entries = testClass.scenarioInfos
        XCTAssertEqual(entries, [
            ScenarioInfo(id: "同期.S0010", title: "全件", app: "com.example", platform: "ios",
                         scenarioTimeout: 1800),
            ScenarioInfo(id: "同期.S0020", title: "差分", app: "com.example", platform: "android",
                         deleted: true),
        ])
    }
}
