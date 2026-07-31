// `ftester run --host` (docs/remote-runner.md §3・§7・Phase 1) の純粋ロジック。
// SSH/rsync 越しの結合は e2e に残す(ここは文字列合成・判定のみ)。

import Foundation
import XCTest
@testable import FTCore

final class RemoteDispatchTests: XCTestCase {

    // MARK: - RemoteHostSpec.parse

    func testParseAcceptsBareHost() throws {
        XCTAssertEqual(try RemoteHostSpec.parse("host").sshTarget, "host")
    }

    func testParseAcceptsUserAtHost() throws {
        XCTAssertEqual(try RemoteHostSpec.parse("user@host").sshTarget, "user@host")
    }

    func testParseRejectsEmpty() {
        XCTAssertThrowsError(try RemoteHostSpec.parse("")) { error in
            guard case RemoteDispatchError.invalidHost = error else {
                return XCTFail("expected invalidHost, got \(error)")
            }
        }
    }

    func testParseRejectsWhitespaceOnly() {
        XCTAssertThrowsError(try RemoteHostSpec.parse("   ")) { error in
            guard case RemoteDispatchError.invalidHost = error else {
                return XCTFail("expected invalidHost, got \(error)")
            }
        }
    }

    func testParseRejectsInternalWhitespace() {
        XCTAssertThrowsError(try RemoteHostSpec.parse("user @host")) { error in
            guard case RemoteDispatchError.invalidHost = error else {
                return XCTFail("expected invalidHost, got \(error)")
            }
        }
    }

    func testParseRejectsLeadingDash() {
        XCTAssertThrowsError(try RemoteHostSpec.parse("-oProxyCommand=evil")) { error in
            guard case RemoteDispatchError.invalidHost = error else {
                return XCTFail("expected invalidHost, got \(error)")
            }
        }
    }

    func testParseRejectsColon() {
        XCTAssertThrowsError(try RemoteHostSpec.parse("host:/some/path")) { error in
            guard case RemoteDispatchError.invalidHost = error else {
                return XCTFail("expected invalidHost, got \(error)")
            }
        }
    }

    // MARK: - RemoteCompat.mismatches

    func testMismatchesEmptyWhenAllMatch() {
        XCTAssertEqual(RemoteCompat.mismatches(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0"), [])
    }

    func testMismatchesRevisionOnly() {
        let reasons = RemoteCompat.mismatches(
            localRevision: "abc", remoteRevision: "def",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0")
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("git revision"), reasons[0])
        XCTAssertTrue(reasons[0].contains("local=abc") && reasons[0].contains("remote=def"), reasons[0])
    }

    func testMismatchesToolchainOnly() {
        let reasons = RemoteCompat.mismatches(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.1")
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("toolchain"), reasons[0])
        XCTAssertTrue(reasons[0].contains("local=Xcode 27.0") && reasons[0].contains("remote=Xcode 27.1"),
                     reasons[0])
    }

    /// fail-closed: リモート値が取れない(nil)場合も不一致に含める
    func testMismatchesNilRemoteIsMismatch() {
        let reasons = RemoteCompat.mismatches(
            localRevision: "abc", remoteRevision: nil,
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0")
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("could not determine the remote value"), reasons[0])
        XCTAssertTrue(reasons[0].contains("local=abc"), reasons[0])
    }

    /// fail-closed: ローカル値が取れない場合も不一致に含める
    func testMismatchesNilLocalIsMismatch() {
        let reasons = RemoteCompat.mismatches(
            localRevision: nil, remoteRevision: "abc",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0")
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("could not determine the local value"), reasons[0])
        XCTAssertTrue(reasons[0].contains("remote=abc"), reasons[0])
    }

    // MARK: - RemoteLayout

    func testRemoteLayoutStripsTrailingSlashFromBase() {
        let layout = RemoteLayout(base: "/Users/x/ftester-runner/")
        XCTAssertEqual(layout.base, "/Users/x/ftester-runner")
    }

    func testRemoteLayoutToolRootWorkDirBinary() {
        let layout = RemoteLayout(base: "/Users/x/ftester-runner")
        XCTAssertEqual(layout.toolRoot, "/Users/x/ftester-runner/foundation-tester")
        XCTAssertEqual(layout.workDir, "/Users/x/ftester-runner/work")
        XCTAssertEqual(layout.binary, "/Users/x/ftester-runner/foundation-tester/.build/debug/ftester")
    }

    func testRemoteLayoutProjectDir() {
        let layout = RemoteLayout(base: "/Users/x/ftester-runner")
        XCTAssertEqual(layout.projectDir("E2E"), "/Users/x/ftester-runner/work/Projects/E2E")
    }

    func testRemoteLayoutDispatchReportDir() {
        let layout = RemoteLayout(base: "/Users/x/ftester-runner")
        XCTAssertEqual(layout.dispatchReportDir(stamp: "20260801-120000-42"),
                       "/Users/x/ftester-runner/work/.ftester/dispatch/20260801-120000-42/reports")
    }

    // MARK: - RemoteLayout.resolveBase

    func testResolveBaseExpandsTildeSlash() {
        XCTAssertEqual(RemoteLayout.resolveBase("~/ftester-runner", home: "/Users/ci"),
                       "/Users/ci/ftester-runner")
    }

    func testResolveBaseKeepsAbsolutePathUnchanged() {
        XCTAssertEqual(RemoteLayout.resolveBase("/opt/ftester-runner", home: "/Users/ci"),
                       "/opt/ftester-runner")
    }

    func testResolveBaseExpandsBareTilde() {
        XCTAssertEqual(RemoteLayout.resolveBase("~", home: "/Users/ci"), "/Users/ci")
    }

    func testResolveBaseEmptyFallsBackToDefault() {
        XCTAssertEqual(RemoteLayout.resolveBase("", home: "/Users/ci"), "/Users/ci/ftester-runner")
    }

    func testResolveBaseWhitespaceOnlyFallsBackToDefault() {
        XCTAssertEqual(RemoteLayout.resolveBase("   ", home: "/Users/ci"), "/Users/ci/ftester-runner")
    }

    func testResolveBaseStripsTrailingSlashFromHome() {
        XCTAssertEqual(RemoteLayout.resolveBase("~/x", home: "/Users/ci/"), "/Users/ci/x")
    }

    // MARK: - RemoteTransferPlan.rsyncArgs

    func testRsyncArgs() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        XCTAssertEqual(
            RemoteTransferPlan.rsyncArgs(project: "E2E", localProjectsDir: "/local/Projects",
                                        layout: layout, sshTarget: "user@host"),
            [
                "-az", "--delete",
                "--exclude", "/reports", "--exclude", "/results", "--exclude", "/.ftester",
                "/local/Projects/E2E/",
                "user@host:/Users/ci/ftester-runner/work/Projects/E2E/",
            ])
    }

    // MARK: - RemoteRunArgs.build

    func testRemoteRunArgsMinimal() {
        XCTAssertEqual(
            RemoteRunArgs.build(project: "E2E", profile: "ios-inapp", scenarios: [], folders: [],
                                heal: false, noLPT: false, lptHistoryRuns: nil,
                                fastInput: false, remoteJUnitPath: nil, reportDir: nil),
            ["run", "--project", "E2E", "--profile", "ios-inapp", "--quiet"])
    }

    func testRemoteRunArgsEverything() {
        XCTAssertEqual(
            RemoteRunArgs.build(project: "E2E", profile: "ios-inapp",
                                scenarios: ["Login.S0010", "Login.S0020"], folders: ["smoke"],
                                heal: true, noLPT: true, lptHistoryRuns: 3,
                                fastInput: true, remoteJUnitPath: "/remote/junit.xml",
                                reportDir: "/remote/reports"),
            [
                "run", "--project", "E2E", "--profile", "ios-inapp", "--quiet",
                "--report-dir", "/remote/reports",
                "--scenario", "Login.S0010", "--scenario", "Login.S0020",
                "--folder", "smoke",
                "--heal", "--no-lpt", "--lpt-history-runs", "3", "--fast-input",
                "--junit", "/remote/junit.xml",
            ])
    }

    func testRemoteRunArgsReportDirOmittedWhenNil() {
        XCTAssertFalse(
            RemoteRunArgs.build(project: "E2E", profile: "ios-inapp", scenarios: [], folders: [],
                                heal: false, noLPT: false, lptHistoryRuns: nil,
                                fastInput: false, remoteJUnitPath: nil, reportDir: nil)
                .contains("--report-dir"))
    }

    // MARK: - RemoteShell.quote

    func testQuotePlainString() {
        XCTAssertEqual(RemoteShell.quote("abc"), "'abc'")
    }

    func testQuoteEmptyString() {
        XCTAssertEqual(RemoteShell.quote(""), "''")
    }

    func testQuoteWithWhitespace() {
        XCTAssertEqual(RemoteShell.quote("a b"), "'a b'")
    }

    func testQuoteWithSingleQuote() {
        XCTAssertEqual(RemoteShell.quote("it's"), "'it'\\''s'")
    }

    /// $ や ; はシェルにとって特別な文字だが、シングルクォート内では素通しされる
    /// (エスケープを足すと逆に文字として壊れる)ことを確認
    func testQuotePassesThroughShellMetacharacters() {
        XCTAssertEqual(RemoteShell.quote("$HOME;rm -rf /"), "'$HOME;rm -rf /'")
    }

    // MARK: - RemoteShell.remoteRunCommand

    func testRemoteRunCommand() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let command = RemoteShell.remoteRunCommand(
            layout: layout,
            ftesterArgs: ["run", "--project", "E2E", "--profile", "ios-inapp", "--quiet"])
        let binary = "/Users/ci/ftester-runner/foundation-tester/.build/debug/ftester"
        XCTAssertEqual(command,
            "cd '/Users/ci/ftester-runner/work' && export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\" && test -x '\(binary)' || "
            + "{ echo \"ftester binary not found on remote — run: swift build --product ftester\" >&2; exit 90; } && "
            + "'\(binary)' project sync >/dev/null 2>&1 || true && "
            + "'\(binary)' 'run' '--project' 'E2E' '--profile' 'ios-inapp' '--quiet'")
    }

    // MARK: - RemotePathRewrite

    func testRewriteReplacesMultipleOccurrences() {
        let xml = "report: /remote/root/Projects/E2E/reports/a.json\n"
            + "worker: /remote/root/Projects/E2E/reports/b.json"
        let rewritten = RemotePathRewrite.rewrite(xml, remoteRoot: "/remote/root", localRoot: "/local/root")
        XCTAssertEqual(rewritten,
            "report: /local/root/Projects/E2E/reports/a.json\n"
            + "worker: /local/root/Projects/E2E/reports/b.json")
    }

    func testRewriteTreatsTrailingSlashAsEquivalent() {
        let xml = "report: /remote/root/Projects/E2E/reports/a.json"
        let withSlash = RemotePathRewrite.rewrite(xml, remoteRoot: "/remote/root/", localRoot: "/local/root")
        let withoutSlash = RemotePathRewrite.rewrite(xml, remoteRoot: "/remote/root", localRoot: "/local/root")
        XCTAssertEqual(withSlash, withoutSlash)
        XCTAssertEqual(withSlash, "report: /local/root/Projects/E2E/reports/a.json")
    }

    func testRewriteLeavesXMLUnchangedWhenRemoteRootAbsent() {
        let xml = "report: /somewhere/else/reports/a.json"
        XCTAssertEqual(
            RemotePathRewrite.rewrite(xml, remoteRoot: "/remote/root", localRoot: "/local/root"), xml)
    }

    func testRewriteAppliesToNDJSONLine() {
        let line = "{\"kind\":\"scenarioFinished\",\"reportPath\":\"/remote/root/Projects/E2E/reports/a.json\"}"
        XCTAssertEqual(
            RemotePathRewrite.rewrite(line, remoteRoot: "/remote/root", localRoot: "/local/root"),
            "{\"kind\":\"scenarioFinished\",\"reportPath\":\"/local/root/Projects/E2E/reports/a.json\"}")
    }

    // MARK: - RemoteRunArgs.buildApi

    func testBuildApiMinimal() {
        XCTAssertEqual(
            RemoteRunArgs.buildApi(project: "E2E", profile: "ios-inapp", scenarios: ["Login.S0010"],
                                   heal: false, noLPT: false, lptHistoryRuns: nil,
                                   defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil),
            ["api", "run", "--project", "E2E", "--profile", "ios-inapp", "--scenario", "Login.S0010"])
    }

    func testBuildApiEverything() {
        XCTAssertEqual(
            RemoteRunArgs.buildApi(project: "E2E", profile: "ios-inapp",
                                   scenarios: ["Login.S0010", "Login.S0020"],
                                   heal: true, noLPT: true, lptHistoryRuns: 3,
                                   defaultTimeout: 5.5, scenarioTimeout: 90,
                                   reportDir: "/remote/reports"),
            [
                "api", "run", "--project", "E2E", "--profile", "ios-inapp",
                "--report-dir", "/remote/reports",
                "--scenario", "Login.S0010", "--scenario", "Login.S0020",
                "--heal", "--no-lpt", "--lpt-history-runs", "3",
                "--default-timeout", "5.5", "--scenario-timeout", "90",
            ])
    }

    // MARK: - StreamLineSplitter

    func testFeedReturnsAllLinesInOneChunk() {
        let splitter = StreamLineSplitter()
        XCTAssertEqual(splitter.feed(Data("a\nb\nc\n".utf8)), ["a", "b", "c"])
    }

    func testFeedHoldsPartialLineAcrossChunks() {
        let splitter = StreamLineSplitter()
        XCTAssertEqual(splitter.feed(Data("abc".utf8)), [])
        XCTAssertEqual(splitter.feed(Data("def\nghi".utf8)), ["abcdef"])
    }

    func testFeedDropsCarriageReturnBeforeNewline() {
        let splitter = StreamLineSplitter()
        XCTAssertEqual(splitter.feed(Data("line1\r\nline2\r\n".utf8)), ["line1", "line2"])
    }

    func testFlushReturnsRemainingPartialLine() {
        let splitter = StreamLineSplitter()
        _ = splitter.feed(Data("no newline yet".utf8))
        XCTAssertEqual(splitter.flush(), "no newline yet")
    }

    func testFlushReturnsNilWhenNothingRemains() {
        let splitter = StreamLineSplitter()
        _ = splitter.feed(Data("complete\n".utf8))
        XCTAssertNil(splitter.flush())
    }

    func testFeedOnEmptyDataReturnsEmptyArray() {
        let splitter = StreamLineSplitter()
        XCTAssertEqual(splitter.feed(Data()), [])
    }

    // MARK: - RemoteTimeout.seconds

    func testRemoteTimeoutExplicitWins() {
        XCTAssertEqual(RemoteTimeout.seconds(explicit: 3600, scenarioCount: 500), 3600)
    }

    func testRemoteTimeoutExplicitZeroClampsToMinimum() {
        XCTAssertEqual(RemoteTimeout.seconds(explicit: 0, scenarioCount: 5), 1800)
    }

    func testRemoteTimeoutExplicitNegativeClampsToMinimum() {
        XCTAssertEqual(RemoteTimeout.seconds(explicit: -5, scenarioCount: 5), 1800)
    }

    func testRemoteTimeoutAutoZeroScenariosFallsBackToMinimum() {
        // overhead(900) 単独では minimum(1800) を下回るため下限が効く
        XCTAssertEqual(RemoteTimeout.seconds(explicit: nil, scenarioCount: 0), 1800)
    }

    func testRemoteTimeoutAutoOneScenarioStillClampsToMinimum() {
        // 900 + 600*1 = 1500 < 1800
        XCTAssertEqual(RemoteTimeout.seconds(explicit: nil, scenarioCount: 1), 1800)
    }

    func testRemoteTimeoutAutoScalesWithScenarioCount() {
        // 900 + 600*5 = 3900, within minimum..maximum
        XCTAssertEqual(RemoteTimeout.seconds(explicit: nil, scenarioCount: 5), 3900)
    }

    func testRemoteTimeoutAutoClampsToMaximum() {
        // 900 + 600*200 = 121_500 > 86_400
        XCTAssertEqual(RemoteTimeout.seconds(explicit: nil, scenarioCount: 200), 86_400)
    }

    // MARK: - RemoteProbe.parseSessionInfo

    func testParseSessionInfoNormalThreeLines() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice")
        XCTAssertEqual(info, RemoteSessionInfo(home: "/Users/ci", consoleUser: "alice", sshUser: "alice"))
        XCTAssertEqual(info?.isLoggedIn, true)
    }

    func testParseSessionInfoAcceptsTrailingNewline() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\n")
        XCTAssertEqual(info, RemoteSessionInfo(home: "/Users/ci", consoleUser: "alice", sshUser: "alice"))
    }

    func testParseSessionInfoMissingLineReturnsNil() {
        XCTAssertNil(RemoteProbe.parseSessionInfo("/Users/ci\nalice"))
    }

    func testParseSessionInfoBlankLineReturnsNil() {
        XCTAssertNil(RemoteProbe.parseSessionInfo("/Users/ci\n\nalice"))
    }

    func testParseSessionInfoConsoleUserRootDiffersFromSshUser() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nroot\nalice")
        XCTAssertEqual(info?.isLoggedIn, false)
    }

    func testParseSessionInfoConsoleUserMatchesSshUser() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice")
        XCTAssertEqual(info?.isLoggedIn, true)
    }

    // MARK: - StreamLineSplitter (CR handling)

    func testFlushStripsTrailingCarriageReturn() {
        let splitter = StreamLineSplitter()
        _ = splitter.feed(Data("partial line\r".utf8))
        XCTAssertEqual(splitter.flush(), "partial line")
    }

    // MARK: - ToolchainFingerprint.compose

    func testComposeFoldsTwoLineXcodeVersionIntoOneLine() {
        XCTAssertEqual(
            ToolchainFingerprint.compose(
                xcodeVersionOutput: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h"),
            "Xcode 27.0 Build version 27A5228h / iphonesimulator 27A5228h")
    }

    // MARK: - RemoteStatusProbe.command

    func testStatusProbeCommand() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let tool = "\"/Users/ci/ftester-runner/foundation-tester\""
        let binary = "\"/Users/ci/ftester-runner/foundation-tester/.build/debug/ftester\""
        let base = "\"/Users/ci/ftester-runner\""
        XCTAssertEqual(
            RemoteStatusProbe.command(layout: layout),
            "echo $HOME; stat -f%Su /dev/console; id -un; echo '---FT---'; "
            + "git -C \(tool) rev-parse HEAD 2>/dev/null || echo -; echo '---FT---'; "
            + "xcodebuild -version; echo '---FT---'; "
            + "xcrun --sdk iphonesimulator --show-sdk-build-version; echo '---FT---'; "
            + "test -x \(binary) && echo yes || echo no; echo '---FT---'; "
            + "df -k \(base) | tail -1")
    }

    /// $HOME を未解決のまま埋め込んだ layout(remote status の実運用形)でも
    /// 二重引用符で包むだけで壊れない(単一引用符と違い変数展開を妨げない)ことを確認
    func testStatusProbeCommandQuotesDoNotSuppressHomeExpansion() {
        let layout = RemoteLayout(base: RemoteLayout.resolveBase("~/ftester-runner", home: "$HOME"))
        XCTAssertTrue(RemoteStatusProbe.command(layout: layout).contains("\"$HOME/ftester-runner/foundation-tester\""))
    }

    // MARK: - RemoteStatusProbe.dquote

    func testDquotePlainPathUnaffected() {
        XCTAssertEqual(RemoteStatusProbe.dquote("/Users/ci/ftester-runner"), "\"/Users/ci/ftester-runner\"")
    }

    /// $ はエスケープしない(remote status がここに $HOME を埋め込んで展開させるため)
    func testDquotePreservesDollarForHomeExpansion() {
        XCTAssertEqual(RemoteStatusProbe.dquote("$HOME/x"), "\"$HOME/x\"")
    }

    /// --remote-dir に紛れ込んだ埋め込み二重引用符・バックスラッシュが引用符から抜け出さない
    func testDquoteEscapesEmbeddedQuoteAndBackslash() {
        XCTAssertEqual(RemoteStatusProbe.dquote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    // MARK: - RemoteStatusProbe.parse

    private static let statusSeparator = "---FT---"

    private func statusOutput(session: String, revision: String, xcodeVersion: String,
                              sdkBuild: String, binary: String, df: String?) -> String {
        var blocks = [session, revision, xcodeVersion, sdkBuild, binary]
        if let df { blocks.append(df) }
        return blocks.joined(separator: "\n\(Self.statusSeparator)\n")
    }

    func testStatusProbeParseNormalOutput() {
        let output = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        let status = RemoteStatusProbe.parse(output)
        XCTAssertEqual(status.session, RemoteSessionInfo(home: "/Users/ci", consoleUser: "alice", sshUser: "alice"))
        XCTAssertEqual(status.revision, "abc123")
        XCTAssertEqual(status.toolchain, "Xcode 27.0 Build version 27A5228h / iphonesimulator 27A5228h")
        XCTAssertTrue(status.binaryPresent)
        XCTAssertEqual(status.freeKB, 400_000_000)
    }

    func testStatusProbeParseDashRevisionBecomesNil() {
        let output = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "-",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        XCTAssertNil(RemoteStatusProbe.parse(output).revision)
    }

    func testStatusProbeParseBinaryNoBecomesFalse() {
        let output = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "no", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        XCTAssertFalse(RemoteStatusProbe.parse(output).binaryPresent)
    }

    func testStatusProbeParseMissingDfLineLeavesFreeKBNil() {
        let output = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: nil)
        XCTAssertNil(RemoteStatusProbe.parse(output).freeKB)
    }

    func testStatusProbeParseBrokenSessionLeavesOtherFieldsIntact() {
        // セッションが2行しかない(壊れている)が、後続のブロックは正常
        let output = statusOutput(
            session: "/Users/ci\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        let status = RemoteStatusProbe.parse(output)
        XCTAssertNil(status.session)
        XCTAssertEqual(status.revision, "abc123")
        XCTAssertEqual(status.toolchain, "Xcode 27.0 Build version 27A5228h / iphonesimulator 27A5228h")
        XCTAssertTrue(status.binaryPresent)
        XCTAssertEqual(status.freeKB, 400_000_000)
    }

    // MARK: - RemoteCleanPlan.commands

    func testCleanPlanDryRunUsesPrint() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 7, dryRun: true)
        XCTAssertEqual(commands.count, 3)
        for command in commands {
            XCTAssertTrue(command.hasSuffix("-print"), command)
            XCTAssertFalse(command.contains("-exec"), command)
        }
    }

    func testCleanPlanNonDryRunUsesExecRm() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 7, dryRun: false)
        for command in commands {
            XCTAssertTrue(command.hasSuffix("-exec rm -rf {} +"), command)
        }
    }

    func testCleanPlanKeepDaysReflected() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 30, dryRun: true)
        for command in commands {
            XCTAssertTrue(command.contains("-mtime +30"), command)
        }
    }

    func testCleanPlanCoversDispatchReportsAndResults() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 7, dryRun: true)
        XCTAssertTrue(commands[0].contains("'/Users/ci/ftester-runner/work'/.ftester/dispatch"), commands[0])
        XCTAssertTrue(commands[1].contains("'/Users/ci/ftester-runner/work'/Projects/*/reports"), commands[1])
        XCTAssertTrue(commands[2].contains("'/Users/ci/ftester-runner/work'/Projects/*/results"), commands[2])
    }

    func testCleanPlanQuotesTheWorkDirPortion() {
        let layout = RemoteLayout(base: "/Users/ci/ftester runner")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 7, dryRun: true)
        XCTAssertTrue(commands[0].contains("'/Users/ci/ftester runner/work'"), commands[0])
    }

    // MARK: - RemoteLayout.validateBase(コマンド置換の入口ガード)

    func testValidateBaseAcceptsOrdinaryPaths() throws {
        try RemoteLayout.validateBase("~/ftester-runner")
        try RemoteLayout.validateBase("/opt/ft_runner-1.0")
        try RemoteLayout.validateBase("")            // 空は既定値へフォールバック
    }

    /// status は $HOME をリモートで展開させるため二重引用符でパスを包む。`$(…)`・`` ` `` を
    /// 通すとリモートでコマンド置換が起きるので入口で落とす
    func testValidateBaseRejectsCommandSubstitution() {
        for bad in ["$(touch /tmp/pwned)", "`id`", "~/x$HOME", "~/a b", "~/x;id", "~/x|id", "~/x\"y"] {
            XCTAssertThrowsError(try RemoteLayout.validateBase(bad), bad) { error in
                guard case RemoteDispatchError.invalidRemoteDir = error else {
                    return XCTFail("expected invalidRemoteDir for \(bad), got \(error)")
                }
            }
        }
    }
}
