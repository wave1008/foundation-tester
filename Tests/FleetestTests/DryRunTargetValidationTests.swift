import XCTest

/// `--dry-run` で使わない宛先(--profile / --fleet / --runner)の扱いを `run` と `api run` で揃える。
/// 実地 2026-09-24: `run --profile nope --dry-run` は通り `api run` は「run profile not found」で落ちた /
/// `--dry-run --runner` は `run` が注記して続行・`api run` は拒否した(同じ打鍵で可否が割れる)
final class DryRunTargetValidationTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// run の dry-run 分岐は、使わないプロファイル・フリートでも実在を確かめる
    func testRunDryRunStillValidatesProfileAndFleetNames() throws {
        let code = try source("Fleetest.swift")
        guard let start = code.range(of: "if dryRun {\n            if let profile {"),
              let end = code.range(of: "so --fleet is not used", range: start.upperBound..<code.endIndex) else {
            return XCTFail("run の dry-run 分岐が見当たらない — テストを見直すこと")
        }
        let body = String(code[start.lowerBound..<end.upperBound])
        XCTAssertTrue(body.contains("ProfileError.runProfileNotFound("), "dry-run でプロファイルの実在を確かめていない")
        XCTAssertTrue(body.contains("FleetProfile.load(project: testProject, name: fleet)"),
                      "dry-run でフリートの実在を確かめていない")
    }

    /// api run は dry-run を送出側へ入れない(断らず、注記してローカルで検証する)
    func testApiRunDryRunDoesNotRejectRunner() throws {
        let code = try source("ApiRunCommand.swift")
        XCTAssertFalse(code.contains("ValidationError(\"--dry-run is not supported with --runner\")"))
        XCTAssertTrue(code.contains("if dryRun, runner != nil {"), "dry-run の送出を避ける門が無い")
    }
}
