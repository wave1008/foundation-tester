// `fleetest remote setup` (docs/remote-runner.md §14) の純粋ロジック。
// scp/ssh 越しの結合は e2e に残す(ここは文字列合成・判定のみ)。

import Foundation
import XCTest
@testable import FTCore
import FTRemote

final class RemoteSetupTests: XCTestCase {

    // MARK: - RemoteSetupPlan.installArgs

    func testInstallArgs() {
        XCTAssertEqual(
            RemoteSetupPlan.installArgs(
                workDir: "/Users/ci/fleetest-runner/users/alice/work", projectName: "E2E",
                toolRoot: "/Users/ci/fleetest-runner/foundation-tester"),
            [
                "--work-dir", "/Users/ci/fleetest-runner/users/alice/work",
                "--tool-root", "/Users/ci/fleetest-runner/foundation-tester",
                "--name", "E2E",
                "--skip-extension",
                "--skip-mcp",
                "--skip-entry-point",
                "--no-next-steps",
                "--track-branch",
            ])
    }

    /// `--tool-root` を明示する — work が `<base>/users/<issuer>/work` へ2階層深くなり、
    /// install.sh の既定 `<work-dir>/../foundation-tester` が RemoteLayout.toolRoot と
    /// もう一致しないため(§18.2)
    func testInstallArgsIncludesToolRoot() {
        let args = RemoteSetupPlan.installArgs(workDir: "/x/users/alice/work", projectName: "E2E",
                                                toolRoot: "/x/foundation-tester")
        guard let index = args.firstIndex(of: "--tool-root") else {
            return XCTFail("--tool-root が無い: \(args)")
        }
        XCTAssertEqual(args[index + 1], "/x/foundation-tester")
    }

    // MARK: - RemoteSetupPlan.preflightArgs / preflightVerdict

    func testPreflightArgs() {
        XCTAssertEqual(
            RemoteSetupPlan.preflightArgs(
                base: "/Users/ci/fleetest-runner", workDir: "/Users/ci/fleetest-runner/users/alice/work"),
            ["--runner", "--base", "/Users/ci/fleetest-runner",
             "--work-dir", "/Users/ci/fleetest-runner/users/alice/work"])
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
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        XCTAssertEqual(RemoteSetupPlan.ensureWorkDirCommand(layout: layout),
                       "mkdir -p '/Users/ci/fleetest-runner/users/alice/work'")
    }

    // MARK: - RemoteSetupPlan.runAndCleanupCommand

    func testRunAndCleanupCommand() {
        XCTAssertEqual(
            RemoteSetupPlan.runAndCleanupCommand(remotePath: "/tmp/preflight.sh", args: ["--runner", "--base", "/x"]),
            "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; "
                + "bash '/tmp/preflight.sh' '--runner' '--base' '/x'; ft_status=$?; rm -f '/tmp/preflight.sh'; exit $ft_status")
    }

    /// 非対話 ssh の PATH には Homebrew が入らない。preflight / install.sh は Homebrew の道具を見るので、
    /// これが抜けると**入っているのに「無い」と判定する**(remoteRunCommand と同じ規律)
    func testRunAndCleanupCommandPrependsHomebrewToPath() {
        let command = RemoteSetupPlan.runAndCleanupCommand(remotePath: "/tmp/x.sh", args: [])
        XCTAssertTrue(command.hasPrefix("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\";"), command)
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

    /// 期待値は**リテラルで書き切る**(`StreamHelpers.all` から組むと、ヘルパーを取り落とす
    /// 変異が production と期待値の両方に同時に効いて素通しする)。ヘルパーを増やしたら
    /// ここも手で足す —— それがこのテストの仕事
    /// **アラインのビルドもディスパッチと同じ Xcode で行う**(選んだ Xcode を `DEVELOPER_DIR` で先頭に export する)。
    /// 渡さないとランナーの `xcode-select` の既定でビルドし、コマンドラインツールだと FoundationModels のマクロが無くて落ちた
    func testAlignBuildsWithTheSelectedXcode() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        let command = RemoteSetupPlan.alignRevisionCommand(
            layout: layout, revision: "9655a21", helperPath: "/tmp/fleetest-remote-align.12345678/fleetest",
            developerDir: "/Applications/Xcode_27.2_Release_Candidate.app/Contents/Developer")
        XCTAssertTrue(command.hasPrefix("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; "
            + "export DEVELOPER_DIR='/Applications/Xcode_27.2_Release_Candidate.app/Contents/Developer'; "), command)
        XCTAssertFalse(RemoteSetupPlan.alignRevisionCommand(
            layout: layout, revision: "9655a21", helperPath: "/tmp/fleetest-remote-align.12345678/fleetest",
            developerDir: nil).contains("DEVELOPER_DIR"), "ambient のときは何も足さない")
    }

    func testAlignRevisionCommand() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        XCTAssertEqual(
            RemoteSetupPlan.alignRevisionCommand(layout: layout, revision: "9655a21",
                                                  helperPath: "/tmp/fleetest-remote-align.12345678/fleetest",
                                                  developerDir: nil),
            "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; "
                + "ft_align_helper='/tmp/fleetest-remote-align.12345678/fleetest'; "
                + "ft_align_helper_dir='/tmp/fleetest-remote-align.12345678'; "
                + #"trap 'rm -f -- "$ft_align_helper"; rmdir -- "$ft_align_helper_dir"' EXIT; "#
                + #"chmod 700 "$ft_align_helper" && cd '/Users/ci/fleetest-runner/foundation-tester' && git fetch origin && "#
                + #""$ft_align_helper" api fm-align "#
                + "--target-executable '/Users/ci/fleetest-runner/foundation-tester/.build/debug/fleetest' "
                + #"--build-command 'git checkout '\''9655a21'\'' && swift build --product fleetest"#
                + " && swift build --product fleetest-simstream"
                + " && swift build --product fleetest-androidstream"
                + " && swift build --product fleetest-devicepoll"
                + " && swift build --product fleetest-services'")
    }

    func testAlignRevisionCommandRemovesHelperWhenFetchFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = RemoteLayout(base: root.appendingPathComponent("runner").path, issuer: "alice", home: root.path)
        try FileManager.default.createDirectory(atPath: layout.toolRoot, withIntermediateDirectories: true)
        let helperDirectory = root.appendingPathComponent("maintenance")
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let helper = helperDirectory.appendingPathComponent("fleetest")
        try Data("not invoked".utf8).write(to: helper)
        let command = RemoteSetupPlan.alignRevisionCommand(layout: layout, revision: "9655a21", helperPath: helper.path,
                                                           developerDir: nil)

        // toolRoot は Git リポジトリではない。fetch の失敗を保ち、helper へ進まず後片付けする。
        let result = try Shell.run(["/bin/sh", "-c", command])

        XCTAssertEqual(result.status, 128, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperDirectory.path))
    }

    func testAlignRevisionCommandPreservesHeadAndBinaryWhenMaintenanceRefuses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = RemoteLayout(base: root.appendingPathComponent("runner").path, issuer: "alice", home: root.path)
        try FileManager.default.createDirectory(atPath: layout.toolRoot, withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws -> String {
            let result = try Shell.run(["/usr/bin/git", "-C", layout.toolRoot,
                "-c", "user.name=Fleetest Tests", "-c", "user.email=fleetest@example.invalid",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments)
            XCTAssertEqual(result.status, 0, result.output)
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "--quiet"])
        let marker = URL(fileURLWithPath: layout.toolRoot).appendingPathComponent("revision-marker")
        try Data("old source".utf8).write(to: marker)
        _ = try git(["add", "revision-marker"])
        _ = try git(["commit", "--quiet", "-m", "old"])
        let oldRevision = try git(["rev-parse", "HEAD"])
        try Data("new source".utf8).write(to: marker)
        _ = try git(["commit", "--quiet", "-am", "new"])
        let newRevision = try git(["rev-parse", "HEAD"])
        _ = try git(["checkout", "--quiet", "--detach", oldRevision])
        _ = try git(["remote", "add", "origin", layout.toolRoot])
        let binary = URL(fileURLWithPath: layout.toolRoot).appendingPathComponent(".build/debug/fleetest")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old executable".utf8).write(to: binary)
        let helperDirectory = root.appendingPathComponent("maintenance")
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let helper = helperDirectory.appendingPathComponent("fleetest")
        try Data("#!/bin/sh\nexit 73\n".utf8).write(to: helper)
        let command = RemoteSetupPlan.alignRevisionCommand(
            layout: layout, revision: newRevision, helperPath: helper.path, developerDir: nil)

        let result = try Shell.run(["/bin/sh", "-c", command])

        XCTAssertEqual(result.status, 73, result.output)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), oldRevision)
        XCTAssertEqual(try Data(contentsOf: marker), Data("old source".utf8))
        XCTAssertEqual(try Data(contentsOf: binary), Data("old executable".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperDirectory.path))
    }

    // MARK: - RemoteSetupPlan.validateUninstallBase

    func testValidateUninstallBaseAcceptsDefaultLayout() throws {
        try RemoteSetupPlan.validateUninstallBase("/Users/ci/fleetest-runner", home: "/Users/ci")
    }

    func testValidateUninstallBaseAcceptsTwoLevelCustomPath() throws {
        try RemoteSetupPlan.validateUninstallBase("/opt/fleetest-runner", home: "/Users/ci")
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
            try RemoteSetupPlan.validateUninstallBase("fleetest-runner", home: "/Users/ci")) { error in
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
        XCTAssertEqual(RemoteSetupPlan.uninstallCommand(base: "/Users/ci/fleetest-runner"),
                       "rm -rf '/Users/ci/fleetest-runner'")
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
