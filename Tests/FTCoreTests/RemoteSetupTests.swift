// `ftester remote setup` (docs/remote-runner.md §14) の純粋ロジック。
// scp/ssh 越しの結合は e2e に残す(ここは文字列合成・判定のみ)。

import Foundation
import XCTest
@testable import FTCore

final class RemoteSetupTests: XCTestCase {

    // MARK: - RemoteSetupPlan.installArgs

    func testInstallArgs() {
        XCTAssertEqual(
            RemoteSetupPlan.installArgs(workDir: "/Users/ci/ftester-runner/work", projectName: "E2E"),
            [
                "--work-dir", "/Users/ci/ftester-runner/work",
                "--name", "E2E",
                "--skip-extension",
                "--skip-mcp",
                "--skip-claude-md",
                "--no-next-steps",
            ])
    }

    /// `--tool-root` は渡さない — 既定の `<work-dir>/../foundation-tester` が
    /// RemoteLayout.toolRoot とちょうど一致するため(§12 の layout 設計)
    func testInstallArgsOmitsToolRoot() {
        let args = RemoteSetupPlan.installArgs(workDir: "/x/work", projectName: "E2E")
        XCTAssertFalse(args.contains("--tool-root"), "\(args)")
    }

    // MARK: - RemoteSetupPlan.preflightArgs / preflightVerdict

    func testPreflightArgs() {
        XCTAssertEqual(RemoteSetupPlan.preflightArgs(base: "/Users/ci/ftester-runner"),
                       ["--runner", "--base", "/Users/ci/ftester-runner"])
    }

    func testPreflightVerdictReady() {
        XCTAssertEqual(RemoteSetupPlan.preflightVerdict(exitCode: 0), .ready)
    }

    func testPreflightVerdictNeedsManual() {
        XCTAssertEqual(RemoteSetupPlan.preflightVerdict(exitCode: 2), .needsManual)
    }

    func testPreflightVerdictBlocked() {
        XCTAssertEqual(RemoteSetupPlan.preflightVerdict(exitCode: 1), .blocked)
    }

    func testPreflightVerdictUnknown() {
        XCTAssertEqual(RemoteSetupPlan.preflightVerdict(exitCode: 42), .unknown(42))
    }

    // MARK: - RemoteSetupPlan.ensureWorkDirCommand

    func testEnsureWorkDirCommand() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        XCTAssertEqual(RemoteSetupPlan.ensureWorkDirCommand(layout: layout),
                       "mkdir -p '/Users/ci/ftester-runner/work'")
    }

    // MARK: - RemoteSetupPlan.runAndCleanupCommand

    func testRunAndCleanupCommand() {
        XCTAssertEqual(
            RemoteSetupPlan.runAndCleanupCommand(remotePath: "/tmp/preflight.sh", args: ["--runner", "--base", "/x"]),
            "bash '/tmp/preflight.sh' '--runner' '--base' '/x'; ft_status=$?; rm -f '/tmp/preflight.sh'; exit $ft_status")
    }

    /// 一時ファイルの削除は成否に関わらず走る(rm は状態保存の後・exit の前)。
    /// この順序を壊すと失敗パスで一時ファイルが残る
    func testRunAndCleanupCommandOrdersStatusThenCleanupThenExit() {
        let command = RemoteSetupPlan.runAndCleanupCommand(remotePath: "/tmp/x.sh", args: [])
        let statusIndex = command.range(of: "ft_status=$?")!.lowerBound
        let rmIndex = command.range(of: "rm -f")!.lowerBound
        let exitIndex = command.range(of: "exit $ft_status")!.lowerBound
        XCTAssertLessThan(statusIndex, rmIndex)
        XCTAssertLessThan(rmIndex, exitIndex)
    }

    /// リモートは受け手のログインシェル(macOS 既定 zsh)で走る。zsh の `status` は `$?` の
    /// 読み取り専用エイリアスなので、そこへ代入すると**中のスクリプトの終了コードが消える**
    /// (2026-08-16 の localhost 実測。needs-manual=2 が 1 に化けて blocked と誤報し、rm も走らず
    /// 一時ファイルが残った)。zsh の特殊変数を代入先に使わないことを固定する
    func testRunAndCleanupCommandAvoidsZshReadOnlyVariables() {
        let command = RemoteSetupPlan.runAndCleanupCommand(remotePath: "/tmp/x.sh", args: [])
        for reserved in ["status=", "options=", "path=", "argv="] {
            XCTAssertFalse(command.contains(" \(reserved)"), "\(reserved) is read-only in zsh: \(command)")
        }
    }

    // MARK: - RemoteSetupPlan.validateRevision

    func testValidateRevisionAcceptsSevenCharHex() throws {
        try RemoteSetupPlan.validateRevision("9655a21")
    }

    func testValidateRevisionAcceptsFortyCharHex() throws {
        try RemoteSetupPlan.validateRevision(String(repeating: "a", count: 40))
    }

    func testValidateRevisionAcceptsMixedCase() throws {
        try RemoteSetupPlan.validateRevision("9655A21")
    }

    func testValidateRevisionRejectsTooShort() {
        XCTAssertThrowsError(try RemoteSetupPlan.validateRevision("9655a2")) { error in
            guard case RemoteSetupError.invalidRevision = error else {
                return XCTFail("expected invalidRevision, got \(error)")
            }
        }
    }

    func testValidateRevisionRejectsTooLong() {
        let tooLong = String(repeating: "a", count: 41)
        XCTAssertThrowsError(try RemoteSetupPlan.validateRevision(tooLong)) { error in
            guard case RemoteSetupError.invalidRevision = error else {
                return XCTFail("expected invalidRevision, got \(error)")
            }
        }
    }

    func testValidateRevisionRejectsNonHex() {
        XCTAssertThrowsError(try RemoteSetupPlan.validateRevision("9655a2g")) { error in
            guard case RemoteSetupError.invalidRevision = error else {
                return XCTFail("expected invalidRevision, got \(error)")
            }
        }
    }

    /// コマンド置換・シェルメタ文字混入の防止(`RemoteLayout.validateBase` と同じ入口ガードの規律)
    func testValidateRevisionRejectsShellMetacharacters() {
        for bad in ["$(touch /tmp/pwned)", "`id`", "9655a21;rm -rf /", ""] {
            XCTAssertThrowsError(try RemoteSetupPlan.validateRevision(bad), bad) { error in
                guard case RemoteSetupError.invalidRevision = error else {
                    return XCTFail("expected invalidRevision for \(bad), got \(error)")
                }
            }
        }
    }

    // MARK: - RemoteSetupPlan.alignRevisionCommand

    func testAlignRevisionCommand() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        XCTAssertEqual(
            RemoteSetupPlan.alignRevisionCommand(layout: layout, revision: "9655a21"),
            "cd '/Users/ci/ftester-runner/foundation-tester' && git fetch origin && "
                + "git checkout '9655a21' && swift build --product ftester")
    }

    // MARK: - RemoteSetupPlan.validateUninstallBase

    func testValidateUninstallBaseAcceptsDefaultLayout() throws {
        try RemoteSetupPlan.validateUninstallBase("/Users/ci/ftester-runner", home: "/Users/ci")
    }

    func testValidateUninstallBaseAcceptsTwoLevelCustomPath() throws {
        try RemoteSetupPlan.validateUninstallBase("/opt/ftester-runner", home: "/Users/ci")
    }

    func testValidateUninstallBaseRejectsEmpty() {
        XCTAssertThrowsError(try RemoteSetupPlan.validateUninstallBase("", home: "/Users/ci")) { error in
            guard case RemoteSetupError.unsafeUninstallBase = error else {
                return XCTFail("expected unsafeUninstallBase, got \(error)")
            }
        }
    }

    func testValidateUninstallBaseRejectsRelativePath() {
        XCTAssertThrowsError(
            try RemoteSetupPlan.validateUninstallBase("ftester-runner", home: "/Users/ci")) { error in
            guard case RemoteSetupError.unsafeUninstallBase = error else {
                return XCTFail("expected unsafeUninstallBase, got \(error)")
            }
        }
    }

    func testValidateUninstallBaseRejectsRoot() {
        XCTAssertThrowsError(try RemoteSetupPlan.validateUninstallBase("/", home: "/Users/ci")) { error in
            guard case RemoteSetupError.unsafeUninstallBase = error else {
                return XCTFail("expected unsafeUninstallBase, got \(error)")
            }
        }
    }

    func testValidateUninstallBaseRejectsHomeItself() {
        XCTAssertThrowsError(
            try RemoteSetupPlan.validateUninstallBase("/Users/ci", home: "/Users/ci")) { error in
            guard case RemoteSetupError.unsafeUninstallBase = error else {
                return XCTFail("expected unsafeUninstallBase, got \(error)")
            }
        }
    }

    /// home に末尾スラッシュが付いていても等価判定できる(RemoteLayout.stripTrailingSlash と同じ配慮)
    func testValidateUninstallBaseRejectsHomeItselfWithTrailingSlash() {
        XCTAssertThrowsError(
            try RemoteSetupPlan.validateUninstallBase("/Users/ci", home: "/Users/ci/")) { error in
            guard case RemoteSetupError.unsafeUninstallBase = error else {
                return XCTFail("expected unsafeUninstallBase, got \(error)")
            }
        }
    }

    func testValidateUninstallBaseRejectsShallowSystemPath() {
        for shallow in ["/tmp", "/etc", "/Users"] {
            XCTAssertThrowsError(try RemoteSetupPlan.validateUninstallBase(shallow, home: "/Users/ci"), shallow) { error in
                guard case RemoteSetupError.unsafeUninstallBase = error else {
                    return XCTFail("expected unsafeUninstallBase for \(shallow), got \(error)")
                }
            }
        }
    }

    // MARK: - RemoteSetupPlan.uninstallCommand

    func testUninstallCommand() {
        XCTAssertEqual(RemoteSetupPlan.uninstallCommand(base: "/Users/ci/ftester-runner"),
                       "rm -rf '/Users/ci/ftester-runner'")
    }

    // MARK: - RemoteSetupStepLine.render

    func testStepLineOK() {
        XCTAssertEqual(RemoteSetupStepLine.render(name: "reach", status: .ok, detail: "reachable"),
                       "✅ [ok] reach: reachable")
    }

    func testStepLineWarn() {
        XCTAssertEqual(RemoteSetupStepLine.render(name: "verify", status: .warn, detail: "skipped"),
                       "⚠️  [warn] verify: skipped")
    }

    func testStepLineFail() {
        XCTAssertEqual(RemoteSetupStepLine.render(name: "preflight", status: .fail, detail: "blocked"),
                       "❌ [fail] preflight: blocked")
    }

    func testStepLineSkip() {
        XCTAssertEqual(RemoteSetupStepLine.render(name: "machine", status: .skip, detail: "no --machine given"),
                       "⏭️  [skip] machine: no --machine given")
    }

    // MARK: - RemoteSetupSummary

    func testSummaryCountsEachStatus() {
        let summary = RemoteSetupSummary(statuses: [.ok, .ok, .skip, .warn, .fail])
        XCTAssertEqual(summary.ok, 2)
        XCTAssertEqual(summary.skip, 1)
        XCTAssertEqual(summary.needsAttention, 2)
    }

    func testSummaryLine() {
        let summary = RemoteSetupSummary(statuses: [.ok, .ok, .ok, .skip, .fail])
        XCTAssertEqual(summary.line, "✅ done 3 / ⏭️ skipped 1 / ⚠️ needs attention 1")
    }

    func testSummaryLineAllOK() {
        let summary = RemoteSetupSummary(statuses: [.ok, .ok])
        XCTAssertEqual(summary.line, "✅ done 2 / ⏭️ skipped 0 / ⚠️ needs attention 0")
    }
}
