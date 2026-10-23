// `fleetest run --dry-run` と `fleetest api run --dry-run` は別実装なので、platform を宣言していないシナリオの OS を
// 別々に決めていた(CLI は --platform = 既定 ios・api run はプロファイルのデバイス)。同じ `--profile android-run --dry-run` が
// CLI だけ iOS の ios { } を検証して緑になった。両方が `ResolvedProfile.undeclaredScenarioPlatform` を通すことを走査で縛る。

import XCTest

final class DryRunPlatformParityTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testBothRunCommandsDecideTheDryRunPlatformFromTheSharedRule() throws {
        let cli = try source("Sources/fleetest/Fleetest.swift")
        let api = try source("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertTrue(cli.contains("dryRunPlatform = resolved.undeclaredScenarioPlatform"),
                      "fleetest run --dry-run --profile がプロファイルから OS を決めていない")
        XCTAssertTrue(api.contains("let defaultPlatform = resolved.undeclaredScenarioPlatform"),
                      "api run --dry-run が共有の規則を使っていない")
        XCTAssertTrue(cli.contains("runDryRun(items, project: testProject, platform: dryRunPlatform,"),
                      "dry-run の列挙へ決めた OS を渡していない")
    }

    /// 実行時の既定 platform と台数の見積りも同じ規則(`undeclaredScenarioPlatform`)を通す。見積りが未宣言を両 OS に数えると
    /// 走らない側の OS の台を用意し、実行が別の規則で倒すと見積りが用意しなかった OS へ流れる
    func testRunPlatformAndDeviceEstimateShareTheRule() throws {
        let runner = try source("Sources/fleetest/ProfileRunner.swift")
        let api = try source("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertEqual(runner.components(separatedBy: "full.scenarioCounts(platforms:").count - 1, 2,
                       "一覧の確定した2経路(run の準備・機械分担の事前判定)が共有の数え方を使っていない")
        XCTAssertFalse(runner.contains("platform != \"android\" }.count"), "未宣言を両 OS に数える形が残っている")
        XCTAssertFalse(runner.contains("platform != \"ios\" }.count"), "未宣言を両 OS に数える形が残っている")
        XCTAssertEqual(runner.components(separatedBy: "let defaultPlatform = resolved.undeclaredScenarioPlatform").count - 1, 1)
        XCTAssertEqual(api.components(separatedBy: "let defaultPlatform = resolved.undeclaredScenarioPlatform").count - 1, 2,
                       "api run の並列経路と逐次経路が共有の規則を使っていない")
        let mcp = try source("Sources/fleetest-mcp/MCPServer+ScenarioTools.swift")
        XCTAssertTrue(mcp.contains("platformArg: infos.first?.platform, fallback: .undeclaredScenario,"),
                      "ft_run_scenario が未宣言のシナリオを run と別の規則(先頭のデバイス)で走らせている")
    }
}
