// 子プロセスへ渡す環境の契約。**DEVELOPER_DIR を必ず載せる**ことを守る。
//
// FTCoreSimShim は DEVELOPER_DIR が無いと `xcode-select -p` を spawn する(実測 65ms)。
// シナリオ1本=1プロセスなので、渡し忘れると毎シナリオ払う。しかも失敗ではなく
// 「少し遅い」だけなので、テストが無いと誰も気付かない。

import XCTest
@testable import FTCore

final class ScenarioHostChildEnvironmentTests: XCTestCase {

    func testChildEnvironmentCarriesDeveloperDir() throws {
        // **skip の条件は「解決できたか」で判定する**。子の環境にキーが無いことを skip 条件に
        // すると、載せ忘れ(=直したい欠陥)そのものを skip で見逃す
        guard let resolved = ScenarioHost.resolvedDeveloperDir else {
            throw XCTSkip("Xcode の無い環境(xcode-select が解決できない)")
        }
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved),
                      "解決した DEVELOPER_DIR が実在しない: \(resolved)")
        XCTAssertEqual(ScenarioHost.childEnvironment()["DEVELOPER_DIR"], resolved,
                       "解決できているのに子の環境へ載っていない(FTCoreSimShim が毎回 xcode-select を spawn する)")
    }

    /// 親が明示指定していればそれを尊重する(別 Xcode を指したい検証を壊さない)
    func testChildEnvironmentInheritsTheRestOfTheParentEnvironment() {
        let parent = ProcessInfo.processInfo.environment
        let env = ScenarioHost.childEnvironment()
        for (key, value) in parent {
            XCTAssertEqual(env[key], value, "親の環境変数が落ちている: \(key)")
        }
    }
}
