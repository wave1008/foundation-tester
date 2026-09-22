import XCTest

/// api live serve の launch/activate が実地(L2)で踏んだ穴: 空文字列・未インストールの
/// bundle をそのまま `driver.launch`/`driver.activate` へ渡すと XCUIApplication.launch() が
/// 約60秒ハングしてブリッジが自壊した。判定そのもの(InstalledAppCheck.launchGuard)は
/// Tests/FTBridgeClientTests/InstalledAppCheckLaunchGuardTests.swift が固定するので、
/// ここは配線(空文字列を弾く・撃つ前に門を通す)をソース走査で縛る。
final class ApiLiveLaunchGuardWiringTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testLaunchRejectsAnEmptyBundle() throws {
        let code = try source()
        guard let caseRange = code.range(of: "case \"launch\":") else {
            return XCTFail("launch の分岐が見当たらない")
        }
        guard let nextCaseRange = code.range(of: "case \"activate\":") else {
            return XCTFail("activate の分岐が見当たらない")
        }
        let body = String(code[caseRange.upperBound..<nextCaseRange.lowerBound])
        XCTAssertTrue(body.contains("!bundle.isEmpty"),
                      "launch は空文字列の bundle を弾くこと(実地 L2: 空文字列がそのまま撃たれた)")
        guard let guardCallRange = body.range(of: "launchGuard(bundle:"),
              let driverCallRange = body.range(of: "driver.launch(bundleID:") else {
            return XCTFail("launchGuard も driver.launch も見当たらない")
        }
        XCTAssertTrue(guardCallRange.upperBound < driverCallRange.lowerBound,
                      "launchGuard は driver.launch より前に撃つこと")
    }

    func testActivateRejectsAnEmptyBundleAndGoesThroughTheSameGate() throws {
        let code = try source()
        guard let caseRange = code.range(of: "case \"activate\":") else {
            return XCTFail("activate の分岐が見当たらない")
        }
        guard let nextCaseRange = code.range(of: "case \"appSwitcher\":") else {
            return XCTFail("次の分岐(appSwitcher)が見当たらない")
        }
        let body = String(code[caseRange.upperBound..<nextCaseRange.lowerBound])
        XCTAssertTrue(body.contains("!bundle.isEmpty"),
                      "activate も空文字列の bundle を弾くこと")
        guard let guardCallRange = body.range(of: "launchGuard(bundle:"),
              let driverCallRange = body.range(of: "driver.activate(bundleID:") else {
            return XCTFail("launchGuard も driver.activate も見当たらない")
        }
        XCTAssertTrue(guardCallRange.upperBound < driverCallRange.lowerBound,
                      "launchGuard は driver.activate より前に撃つこと")
    }

    /// launchGuard 自体が InstalledAppCheck.launchGuard(MCP と共有する判定)を通すことを固定する
    /// (二つ目の実装を書かない)
    func testLaunchGuardDelegatesToTheSharedVerdict() throws {
        let code = try source()
        XCTAssertTrue(code.contains("InstalledAppCheck.launchGuard("),
                      "判定は InstalledAppCheck.launchGuard(MCP の ft_launch と共有)を通すこと")
    }
}
