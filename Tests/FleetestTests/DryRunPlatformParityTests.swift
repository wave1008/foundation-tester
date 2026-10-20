// `fleetest run --dry-run` と `fleetest api run --dry-run` は別実装なので、platform を宣言していないシナリオの OS を
// 別々に決めていた(CLI は --platform = 既定 ios・api run はプロファイルのデバイス)。同じ `--profile android-run --dry-run` が
// CLI だけ iOS の ios { } を検証して緑になった。両方が `ResolvedProfile.dryRunDefaultPlatform` を通すことを走査で縛る。

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
        XCTAssertTrue(cli.contains("dryRunPlatform = resolved.dryRunDefaultPlatform"),
                      "fleetest run --dry-run --profile がプロファイルから OS を決めていない")
        XCTAssertTrue(api.contains("? resolved.dryRunDefaultPlatform"),
                      "api run --dry-run が共有の規則を使っていない")
        XCTAssertTrue(cli.contains("runDryRun(items, project: testProject, platform: dryRunPlatform,"),
                      "dry-run の列挙へ決めた OS を渡していない")
    }
}
