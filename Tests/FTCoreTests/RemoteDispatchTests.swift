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
        XCTAssertEqual(layout.projectDir("E2E"), "/Users/x/ftester-runner/work/TestProjects/E2E")
    }

    func testRemoteLayoutDispatchReportDir() {
        let layout = RemoteLayout(base: "/Users/x/ftester-runner")
        XCTAssertEqual(layout.dispatchReportDir(stamp: "20260801-120000-42"),
                       "/Users/x/ftester-runner/work/.ftester/dispatch/20260801-120000-42/reports")
    }

    /// 次に改名する人をここで止める: `RemoteLayout.projectsDirName` は
    /// `ProjectStore.projectsDir` が解決する現行の名前と一致必須(片方だけ変えない)
    func testProjectsDirNameMatchesProjectStore() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-remote-dispatch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("TestProjects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = ProjectStore.projectsDir(repoRoot: tempRoot)
        XCTAssertEqual(resolved.lastPathComponent, RemoteLayout.projectsDirName)
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
                "user@host:/Users/ci/ftester-runner/work/TestProjects/E2E/",
            ])
    }

    // MARK: - RemoteArtifactsMode.parse

    func testArtifactsModeParseCollect() throws {
        XCTAssertEqual(try RemoteArtifactsMode.parse("collect"), .collect)
    }

    func testArtifactsModeParseOnDemand() throws {
        XCTAssertEqual(try RemoteArtifactsMode.parse("on-demand"), .onDemand)
    }

    func testArtifactsModeParseRejectsBogusValue() {
        XCTAssertThrowsError(try RemoteArtifactsMode.parse("bogus")) { error in
            guard case RemoteDispatchError.invalidArtifactsMode = error else {
                return XCTFail("expected invalidArtifactsMode, got \(error)")
            }
        }
    }

    /// rawValue の完全一致でしか受理しない(大文字小文字は区別する)
    func testArtifactsModeParseRejectsCapitalizedValue() {
        XCTAssertThrowsError(try RemoteArtifactsMode.parse("Collect")) { error in
            guard case RemoteDispatchError.invalidArtifactsMode = error else {
                return XCTFail("expected invalidArtifactsMode, got \(error)")
            }
        }
    }

    // MARK: - RemoteArtifactCollection.resultsRsyncArgs

    func testResultsRsyncArgs() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        XCTAssertEqual(
            RemoteArtifactCollection.resultsRsyncArgs(
                project: "E2E", layout: layout, sshTarget: "user@host",
                localProjectsDir: "/local/Projects"),
            [
                "-az",
                "user@host:/Users/ci/ftester-runner/work/TestProjects/E2E/results/",
                "/local/Projects/E2E/results/",
            ])
    }

    /// --delete が無いこと(ローカルの results を巻き添えで消さない)と、両パスとも末尾スラッシュを
    /// 保つこと(rsync のディレクトリ中身コピー契約)を確認
    func testResultsRsyncArgsOmitsDeleteAndKeepsTrailingSlashes() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let args = RemoteArtifactCollection.resultsRsyncArgs(
            project: "E2E", layout: layout, sshTarget: "user@host",
            localProjectsDir: "/local/Projects")
        XCTAssertFalse(args.contains("--delete"), "\(args)")
        XCTAssertTrue(args[1].hasSuffix("/"), args[1])
        XCTAssertTrue(args[2].hasSuffix("/"), args[2])
    }

    // MARK: - RemoteRunArgs.build

    func testRemoteRunArgsMinimal() {
        XCTAssertEqual(
            RemoteRunArgs.build(project: "E2E", profile: "ios-inapp", scenarios: [], folders: [],
                                heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
                                fastInput: false, enableAnimations: false, performanceMode: false,
                                remoteJUnitPath: nil, reportDir: nil),
            ["run", "--project", "E2E", "--profile", "ios-inapp", "--quiet", "--host", "local"])
    }

    /// **リモートのサブ実行はデバイスの絞り込みを中継しないと効かない**(2026-08-17 の実走)。
    /// 向こうは同じマシンプロファイルを受け取るので、渡さないと全ホストぶんの台を自分のものと
    /// して解決しようとする。一意なのは (host, name) なのでホストも要る
    func testRemoteRunArgsRelaysTheDeviceScope() {
        let args = RemoteRunArgs.build(
            project: "E2E", profile: "mixed", scenarios: [], folders: [],
            deviceNames: ["iPhone-01", "iPhone-02"], deviceHost: "M1Max",
            heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
            fastInput: false, enableAnimations: false, performanceMode: false,
            remoteJUnitPath: nil, reportDir: nil)
        XCTAssertEqual(
            args,
            ["run", "--project", "E2E", "--profile", "mixed", "--quiet", "--host", "local",
             "--device", "iPhone-01", "iPhone-02", "--device-host", "M1Max"])
    }

    func testRemoteRunArgsEverything() {
        XCTAssertEqual(
            RemoteRunArgs.build(project: "E2E", profile: "ios-inapp",
                                scenarios: ["Login.S0010", "Login.S0020"], folders: ["smoke"],
                                heal: true, noHeal: false, noLPT: true, lptHistoryRuns: 3,
                                fastInput: true, enableAnimations: true, performanceMode: true,
                                remoteJUnitPath: "/remote/junit.xml",
                                reportDir: "/remote/reports"),
            [
                "run", "--project", "E2E", "--profile", "ios-inapp", "--quiet", "--host", "local",
                "--report-dir", "/remote/reports",
                "--scenario", "Login.S0010", "--scenario", "Login.S0020",
                "--folder", "smoke",
                "--heal", "--no-lpt", "--lpt-history-runs", "3", "--fast-input",
                "--enable-animations", "--performance",
                "--junit", "/remote/junit.xml",
            ])
    }

    /// リモートで走る ftester が**もう一度ディスパッチしない**ことを固定する。転送された
    /// マシンプロファイルには host(= そのリモート自身の名前)が入っているので、--host local が
    /// 抜けると向こうの MachineHostDispatch が自動ディスパッチに入り、登録簿次第で
    /// 「未登録のホスト」で落ちるか自分自身へ ssh する
    func testRemoteRunArgsAlwaysPinTheRemoteSideToLocal() {
        for args in [
            RemoteRunArgs.build(project: "E2E", profile: "p", scenarios: [], folders: [],
                                heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
                                fastInput: false, enableAnimations: false, performanceMode: false,
                                remoteJUnitPath: nil, reportDir: nil),
            RemoteRunArgs.buildApi(project: "E2E", profile: "p", scenarios: [],
                                   heal: false, noLPT: false, lptHistoryRuns: nil,
                                   performanceMode: false,
                                   defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil),
        ] {
            guard let index = args.firstIndex(of: "--host") else {
                return XCTFail("--host local が無い: \(args)")
            }
            XCTAssertEqual(args[index + 1], "local")
        }
    }

    func testRemoteRunArgsReportDirOmittedWhenNil() {
        XCTAssertFalse(
            RemoteRunArgs.build(project: "E2E", profile: "ios-inapp", scenarios: [], folders: [],
                                heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
                                fastInput: false, enableAnimations: false, performanceMode: false,
                                remoteJUnitPath: nil, reportDir: nil)
                .contains("--report-dir"))
    }

    /// 実行の意図を変えるフラグは**中継されないと黙って無視される**(リモートはプロファイルの
    /// 既定で走り、指定しなかったのと同じ結果になる)。ここは OFF のときに**付けない**ことと
    /// 対で固定する —— 常に付ける実装なら計測でないふつうの run が計測モードになる
    func testRunPerformanceModeIsRelayedOnlyWhenOn() {
        func args(performance: Bool) -> [String] {
            RemoteRunArgs.build(project: "E2E", profile: "android-1", scenarios: [], folders: [],
                                heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
                                fastInput: false, enableAnimations: false,
                                performanceMode: performance,
                                remoteJUnitPath: nil, reportDir: nil)
        }
        XCTAssertTrue(args(performance: true).contains("--performance"))
        XCTAssertFalse(args(performance: false).contains("--performance"))
    }

    func testRunEnableAnimationsIsRelayedOnlyWhenOn() {
        func args(animations: Bool) -> [String] {
            RemoteRunArgs.build(project: "E2E", profile: "android-1", scenarios: [], folders: [],
                                heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
                                fastInput: false, enableAnimations: animations,
                                performanceMode: false,
                                remoteJUnitPath: nil, reportDir: nil)
        }
        XCTAssertTrue(args(animations: true).contains("--enable-animations"))
        XCTAssertFalse(args(animations: false).contains("--enable-animations"))
    }

    /// `api run` には `--enable-animations` が無い(実行プロファイルと環境変数から解決する)。
    /// 存在しないフラグを渡すとリモートの ftester が起動時に落ちるので、**混入しないこと**を固定する
    func testApiPerformanceModeIsRelayedAndAnimationsFlagIsNever() {
        func args(performance: Bool) -> [String] {
            RemoteRunArgs.buildApi(project: "E2E", profile: "android-1", scenarios: [],
                                   heal: false, noLPT: false, lptHistoryRuns: nil,
                                   performanceMode: performance,
                                   defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil)
        }
        XCTAssertTrue(args(performance: true).contains("--performance"))
        XCTAssertFalse(args(performance: false).contains("--performance"))
        XCTAssertFalse(args(performance: true).contains("--enable-animations"))
    }

    /// `--heal` だけ中継すると、ヒールを止めたつもりでリモートはプロファイルの既定で走る
    func testRunNoHealIsRelayedOnlyWhenOn() {
        func args(noHeal: Bool) -> [String] {
            RemoteRunArgs.build(project: "E2E", profile: "android-1", scenarios: [], folders: [],
                                heal: false, noHeal: noHeal, noLPT: false, lptHistoryRuns: nil,
                                fastInput: false, enableAnimations: false, performanceMode: false,
                                remoteJUnitPath: nil, reportDir: nil)
        }
        XCTAssertTrue(args(noHeal: true).contains("--no-heal"))
        XCTAssertFalse(args(noHeal: false).contains("--no-heal"))
    }

    // MARK: - RemoteDispatchGate

    /// `--dry-run` はデバイスに触れず、判定はローカルのシナリオ原本だけから決まるので
    /// **`--host` が付いていてもリモートへ送らない**(送っても答えは同じで遅いだけ)。
    /// この門が無いと `--dry-run --host` が実デバイス実行になる —— リモート送出は
    /// `run()` の dryRun 分岐より手前にあり、`--dry-run` は中継の許可リストにも無いため
    func testDryRunIsNotDispatchedRemotely() {
        XCTAssertFalse(RemoteDispatchGate.dispatchesRemotely(host: "user@host", dryRun: true))
    }

    func testHostWithoutDryRunIsDispatchedRemotely() {
        XCTAssertTrue(RemoteDispatchGate.dispatchesRemotely(host: "user@host", dryRun: false))
    }

    /// `--host` 無しはどちらの場合もローカル実行(dry-run の有無で変わらない)
    func testNoHostIsNeverDispatchedRemotely() {
        XCTAssertFalse(RemoteDispatchGate.dispatchesRemotely(host: nil, dryRun: false))
        XCTAssertFalse(RemoteDispatchGate.dispatchesRemotely(host: nil, dryRun: true))
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
                                   performanceMode: false,
                                   defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil),
            ["api", "run", "--project", "E2E", "--profile", "ios-inapp", "--host", "local",
             "--scenario", "Login.S0010"])
    }

    func testBuildApiEverything() {
        XCTAssertEqual(
            RemoteRunArgs.buildApi(project: "E2E", profile: "ios-inapp",
                                   scenarios: ["Login.S0010", "Login.S0020"],
                                   heal: true, noLPT: true, lptHistoryRuns: 3,
                                   performanceMode: true,
                                   defaultTimeout: 5.5, scenarioTimeout: 90,
                                   reportDir: "/remote/reports"),
            [
                "api", "run", "--project", "E2E", "--profile", "ios-inapp", "--host", "local",
                "--report-dir", "/remote/reports",
                "--scenario", "Login.S0010", "--scenario", "Login.S0020",
                "--heal", "--no-lpt", "--lpt-history-runs", "3", "--performance",
                "--default-timeout", "5.5", "--scenario-timeout", "90",
            ])
    }

    /// ApiRunHostFanout がホストごとの子(`api run --host <label>`)を立てるようになったため、
    /// `api run --host` のリモート実行にも `run --host` と同じデバイス絞り込みの中継が要る
    /// (testRemoteRunArgsRelaysTheDeviceScope と対。渡さないと向こうが全ホストぶんの台を掴む)
    func testBuildApiRelaysTheDeviceScope() {
        let args = RemoteRunArgs.buildApi(
            project: "E2E", profile: "mixed", scenarios: ["Login.S0010"],
            deviceNames: ["iPhone-01", "iPhone-02"], deviceHost: "M1Max",
            heal: false, noLPT: false, lptHistoryRuns: nil,
            performanceMode: false,
            defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil)
        XCTAssertEqual(
            args,
            ["api", "run", "--project", "E2E", "--profile", "mixed", "--host", "local",
             "--device", "iPhone-01", "iPhone-02", "--device-host", "M1Max",
             "--scenario", "Login.S0010"])
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

    func testRemoteTimeoutAutoZeroScenariosIsUnbounded() {
        // 欠陥2(2026-08-17): scenarioCount 0 は「0本」ではなく「見積り不能」(プロファイル全体・
        // --fleet)を意味しうるため、以前のように minimum(1800秒) へ丸めず nil(無期限)を返す。
        // 見積り不能で30分の下限を機械的に掛けると、正当な長時間 run を SIGKILL していた
        XCTAssertNil(RemoteTimeout.seconds(explicit: nil, scenarioCount: 0))
    }

    func testRemoteTimeoutExplicitStillWinsWithZeroScenarios() {
        // 見積り不能でも明示指定は従来どおり最優先(下限クランプも生きる)
        XCTAssertEqual(RemoteTimeout.seconds(explicit: 0, scenarioCount: 0), 1800)
        XCTAssertEqual(RemoteTimeout.seconds(explicit: 60, scenarioCount: 0), 60)
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

    // MARK: - RemoteDispatchFlagPolicy(欠陥1: --host 明示 vs マシンプロファイル自動での併用不可フラグ)

    func testSkipBuildIsRejectedForExplicitHost() {
        let decision = RemoteDispatchFlagPolicy.skipBuild(origin: .explicitHost)
        guard case .rejected(let message) = decision else {
            return XCTFail("expected .rejected, got \(decision)")
        }
        XCTAssertEqual(message, "--skip-build is not supported with --host")
    }

    func testSkipBuildIsIgnoredWithNoteForAutoDispatch() {
        let decision = RemoteDispatchFlagPolicy.skipBuild(
            origin: .autoDispatch(machine: "M1Max", host: "runner1"))
        guard case .ignoredWithNote(let note) = decision else {
            return XCTFail("expected .ignoredWithNote, got \(decision)")
        }
        XCTAssertTrue(note.contains("--skip-build"))
        XCTAssertFalse(note.isEmpty)
    }

    func testReportDirIsRejectedForExplicitHostWithExistingMessage() {
        let decision = RemoteDispatchFlagPolicy.rejected(flag: "--report-dir", origin: .explicitHost)
        guard case .rejected(let message) = decision else {
            return XCTFail("expected .rejected, got \(decision)")
        }
        XCTAssertEqual(message, "--report-dir is not supported with --host")
    }

    func testReportDirIsRejectedForAutoDispatchWithMachineAndHostInMessage() {
        // 欠陥1: 拒否理由が「--host と併用できない」のままだと、打ってもいない --host を疑うことになる。
        // マシン名・host 名を含む理由に変える
        let decision = RemoteDispatchFlagPolicy.rejected(
            flag: "--failed", origin: .autoDispatch(machine: "M1Max", host: "runner1"))
        guard case .rejected(let message) = decision else {
            return XCTFail("expected .rejected, got \(decision)")
        }
        XCTAssertTrue(message.contains("--failed"))
        XCTAssertTrue(message.contains("M1Max"))
        XCTAssertTrue(message.contains("runner1"))
        XCTAssertFalse(message.contains("is not supported with --host"),
                       "自動ディスパッチでは --host を打っていないので、この文言を出さない")
    }

    func testPortsIsRejectedForBothOrigins() {
        guard case .rejected = RemoteDispatchFlagPolicy.rejected(flag: "--ports", origin: .explicitHost) else {
            return XCTFail("expected .rejected for explicitHost")
        }
        guard case .rejected = RemoteDispatchFlagPolicy.rejected(
            flag: "--ports", origin: .autoDispatch(machine: "M1Max", host: "runner1")) else {
            return XCTFail("expected .rejected for autoDispatch")
        }
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
        XCTAssertTrue(commands[1].contains("'/Users/ci/ftester-runner/work'/TestProjects/*/reports"), commands[1])
        XCTAssertTrue(commands[2].contains("'/Users/ci/ftester-runner/work'/TestProjects/*/results"), commands[2])
    }

    /// `--dry-run` は**何も変えない**。`devices down` は走っている run を巻き添えにする破壊的操作
    /// なので、プレビューでは撃たない(2026-08-16 に実機で踏んだ: dry-run のつもりで
    /// ランナーのブリッジが落ちた)
    func testDryRunDoesNotStopDevices() {
        XCTAssertFalse(RemoteCleanPlan.stopsDevices(dryRun: true))
        XCTAssertTrue(RemoteCleanPlan.stopsDevices(dryRun: false))
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

    // MARK: - RemoteRelay(-tt で合流するリモート stderr の振り分け)

    func testIsMachineReadableLineAcceptsNDJSON() {
        XCTAssertTrue(RemoteRelay.isMachineReadableLine("{\"kind\":\"runStarted\",\"total\":1}"))
        XCTAssertTrue(RemoteRelay.isMachineReadableLine("  {\"kind\":\"runFinished\"}"))
    }

    func testIsMachineReadableLineRejectsHumanDiagnostics() {
        for line in ["🧩 Profile ios-1: サンプルアプリ @ M2 Ultra",
                     "→ Building scenarios (SampleApp)...",
                     "✅ iPhone 17 Pro(iOS 27.0): xcuitest bridge ready",
                     ""] {
            XCTAssertFalse(RemoteRelay.isMachineReadableLine(line), line)
        }
    }

    // MARK: - RemoteShell.remoteExecCommand

    // MARK: - RemoteReportLink

    /// リモートが記録する reportPath はディスパッチ単位の隔離先で、そこは回収後に消える。
    /// 回収先(ローカルの TestProjects/<project>/reports/)へ向け直す
    func testReportPathIsRelinkedToTheCollectedCopy() {
        XCTAssertEqual(
            RemoteReportLink.rewrittenReportPath(
                recorded: ".ftester/dispatch/20260816-130735-24451/reports/scenario-1-S0010.md",
                stamp: "20260816-130735-24451",
                projectReportsPathFromRepoRoot: "TestProjects/E2E-iOS/reports"),
            "TestProjects/E2E-iOS/reports/scenario-1-S0010.md")
    }

    /// **他の run の記録に触らない**。別のディスパッチ(別 stamp)の記録は対象外
    func testReportPathOfAnotherDispatchIsLeftAlone() {
        XCTAssertNil(RemoteReportLink.rewrittenReportPath(
            recorded: ".ftester/dispatch/20260816-999999-11111/reports/scenario-1-S0010.md",
            stamp: "20260816-130735-24451",
            projectReportsPathFromRepoRoot: "TestProjects/E2E-iOS/reports"))
    }

    /// ローカル実行が記録する形(既にリポジトリルート基準)は書き換えない
    func testLocalStyleReportPathIsNotRewritten() {
        XCTAssertNil(RemoteReportLink.rewrittenReportPath(
            recorded: "TestProjects/E2E-iOS/reports/scenario-1-S0010.md",
            stamp: "20260816-130735-24451",
            projectReportsPathFromRepoRoot: "TestProjects/E2E-iOS/reports"))
    }

    /// 隔離先の下にさらにディレクトリがある形は想定していない(rsync はファイル名を保つ)。
    /// 想定外を黙って別の場所へ向けない
    func testNestedPathUnderTheDispatchDirIsNotRewritten() {
        XCTAssertNil(RemoteReportLink.rewrittenReportPath(
            recorded: ".ftester/dispatch/20260816-130735-24451/reports/sub/scenario-1-S0010.md",
            stamp: "20260816-130735-24451",
            projectReportsPathFromRepoRoot: "TestProjects/E2E-iOS/reports"))
    }

    // MARK: - RemoteArtifactCollection.isMissingSourceFailure

    /// run が成果物を作る前に落ちたときの rsync 失敗(転送元不在)は黙る。**実際の rsync の
    /// 文言で固定する** —— これを warning にすると、本当の失敗理由の下にノイズが積まれる
    func testMissingSourceFailureIsDetectedFromRsyncStderr() {
        let stderr = """
            rsync: [sender] change_dir "/Users/ci/ftester-runner/work/.ftester/dispatch/20260816-080316-95613/reports" \
            failed: No such file or directory (2)
            rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338)
            """
        XCTAssertTrue(RemoteArtifactCollection.isMissingSourceFailure(status: 23, stderr: stderr))
    }

    /// 23 は「一部が転送できなかった」の総称。転送元不在**以外**(権限・切断)は警告のままにする
    func testOtherRsyncFailuresAreNotSilenced() {
        let stderr = """
            rsync: [receiver] mkstemp "/local/reports/.a.json.XYZ" failed: Permission denied (13)
            rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338)
            """
        XCTAssertFalse(RemoteArtifactCollection.isMissingSourceFailure(status: 23, stderr: stderr))
    }

    /// 別の exit code は文言が似ていても黙らせない(23 以外は「一部失敗」ではない)
    func testNonTwentyThreeStatusIsNotSilenced() {
        XCTAssertFalse(RemoteArtifactCollection.isMissingSourceFailure(
            status: 12, stderr: "rsync: connection unexpectedly closed: No such file or directory"))
        XCTAssertFalse(RemoteArtifactCollection.isMissingSourceFailure(status: 0, stderr: ""))
    }

    func testRemoteExecCommand() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let command = RemoteShell.remoteExecCommand(layout: layout, args: ["doctor", "--fm-only"])
        let binary = "/Users/ci/ftester-runner/foundation-tester/.build/debug/ftester"
        XCTAssertEqual(command,
            "cd '/Users/ci/ftester-runner/work' && export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\" && test -x '\(binary)' || "
            + "{ echo \"ftester binary not found on remote — run: swift build --product ftester\" >&2; exit 90; } && "
            + "'\(binary)' 'doctor' '--fm-only'")
    }

    /// 照会・単発操作が目的で、run 専用の `project sync` を混ぜてはいけない
    /// (remoteRunCommand との唯一の差分。壊すと remote exec のたびに無駄な sync が走る)
    func testRemoteExecCommandDoesNotSyncProject() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let command = RemoteShell.remoteExecCommand(layout: layout, args: ["devices", "down"])
        XCTAssertFalse(command.contains("project sync"), command)
    }

    func testRemoteExecCommandQuotesEachArgumentIndependently() {
        let layout = RemoteLayout(base: "/Users/ci/ftester-runner")
        let command = RemoteShell.remoteExecCommand(layout: layout, args: ["api", "device-catalog"])
        XCTAssertTrue(command.hasSuffix("'api' 'device-catalog'"), command)
    }
}
