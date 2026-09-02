// `fleetest run --host` (docs/remote-runner.md §3・§7・Phase 1) の純粋ロジック。
// SSH/rsync 越しの結合は e2e に残す(ここは文字列合成・判定のみ)。

import Foundation
import XCTest
@testable import FTCore
import FTRemote

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

    // MARK: - RemoteCompat.classifyRelation

    func testClassifyRelationLocalBehind() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: true, remoteIsAncestorOfLocal: false), .localBehind)
    }

    func testClassifyRelationRemoteBehind() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: false, remoteIsAncestorOfLocal: true), .remoteBehind)
    }

    func testClassifyRelationDiverged() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: false, remoteIsAncestorOfLocal: false), .diverged)
    }

    func testClassifyRelationUnknownWhenEitherSideNil() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: nil, remoteIsAncestorOfLocal: true), .unknown)
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: false, remoteIsAncestorOfLocal: nil), .unknown)
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: nil, remoteIsAncestorOfLocal: nil), .unknown)
    }

    /// 呼び手は rev が異なるときだけ呼ぶ契約なので本来起きないが、防御として unknown に落とす
    func testClassifyRelationBothTrueFallsBackToUnknown() {
        XCTAssertEqual(RemoteCompat.classifyRelation(
            localIsAncestorOfRemote: true, remoteIsAncestorOfLocal: true), .unknown)
    }

    // MARK: - RemoteCompat.relationAdvice

    /// localBehind は自分を更新する経路(update.sh)だけを案内する ―― align を実行手順として出さない
    func testRelationAdviceLocalBehindPointsToUpdateNotAlign() {
        let advice = RemoteCompat.relationAdvice(.localBehind)
        XCTAssertTrue(advice.contains("update"), advice)
        XCTAssertTrue(advice.contains("Scripts/update.sh"), advice)
        XCTAssertFalse(advice.contains("fleetest remote align"), advice)
    }

    func testRelationAdviceRemoteBehindPointsToAlignWithCanary() {
        let advice = RemoteCompat.relationAdvice(.remoteBehind)
        XCTAssertTrue(advice.contains("fleetest remote align"), advice)
        XCTAssertTrue(advice.contains("canary"), advice)
    }

    func testRelationAdviceDivergedPointsToDedicatedMachine() {
        XCTAssertTrue(RemoteCompat.relationAdvice(.diverged).contains("dedicated machine"))
    }

    func testRelationAdviceUnknownPointsToGitFetch() {
        XCTAssertTrue(RemoteCompat.relationAdvice(.unknown).contains("git fetch"))
    }

    // MARK: - RemoteLayout

    func testRemoteLayoutStripsTrailingSlashFromBase() {
        let layout = RemoteLayout(base: "/Users/x/fleetest-runner/", issuer: "alice")
        XCTAssertEqual(layout.base, "/Users/x/fleetest-runner")
    }

    func testRemoteLayoutToolRootWorkDirBinary() {
        let layout = RemoteLayout(base: "/Users/x/fleetest-runner", issuer: "alice")
        XCTAssertEqual(layout.toolRoot, "/Users/x/fleetest-runner/foundation-tester")
        XCTAssertEqual(layout.workDir, "/Users/x/fleetest-runner/users/alice/work")
        XCTAssertEqual(layout.binary, "/Users/x/fleetest-runner/foundation-tester/.build/debug/fleetest")
    }

    /// ツールクローンと dispatch.lock はホスト共有のまま(base 基準)。work だけが発行者ごとに分かれる
    func testRemoteLayoutUsersDir() {
        let layout = RemoteLayout(base: "/Users/x/fleetest-runner", issuer: "alice")
        XCTAssertEqual(layout.usersDir, "/Users/x/fleetest-runner/users")
    }

    func testRemoteLayoutProjectDir() {
        let layout = RemoteLayout(base: "/Users/x/fleetest-runner", issuer: "alice")
        XCTAssertEqual(layout.projectDir("E2E"), "/Users/x/fleetest-runner/users/alice/work/TestProjects/E2E")
    }

    /// remoteControl.workspace のミラー先はプロジェクトごとに分ける(複数プロジェクトの衝突を防ぐ)
    func testRemoteLayoutWorkspaceDir() {
        let layout = RemoteLayout(base: "/Users/x/fleetest-runner", issuer: "alice")
        XCTAssertEqual(layout.workspaceDir("E2E"), "/Users/x/fleetest-runner/users/alice/work/workspace/E2E")
    }

    func testRemoteLayoutDispatchReportDir() {
        let layout = RemoteLayout(base: "/Users/x/fleetest-runner", issuer: "alice")
        XCTAssertEqual(layout.dispatchReportDir(stamp: "20260801-120000-42"),
                       "/Users/x/fleetest-runner/users/alice/work/.fleetest/dispatch/20260801-120000-42/reports")
    }

    // MARK: - RemoteLayout.validateIssuerKey

    func testValidateIssuerKeyAcceptsOrdinaryValues() throws {
        try RemoteLayout.validateIssuerKey("alice")
        try RemoteLayout.validateIssuerKey("tanaka@dev-mbp")
        try RemoteLayout.validateIssuerKey("bob.smith-1_2")
    }

    func testValidateIssuerKeyRejectsEmpty() {
        XCTAssertThrowsError(try RemoteLayout.validateIssuerKey("")) { error in
            guard case RemoteDispatchError.invalidIssuer = error else {
                return XCTFail("expected invalidIssuer, got \(error)")
            }
        }
    }

    func testValidateIssuerKeyRejectsDisallowedCharacters() {
        for bad in ["alice/bob", "alice bob", "alice$HOME", "alice;rm -rf /", "alice`id`"] {
            XCTAssertThrowsError(try RemoteLayout.validateIssuerKey(bad), bad) { error in
                guard case RemoteDispatchError.invalidIssuer = error else {
                    return XCTFail("expected invalidIssuer for \(bad), got \(error)")
                }
            }
        }
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
        XCTAssertEqual(RemoteLayout.resolveBase("~/fleetest-runner", home: "/Users/ci"),
                       "/Users/ci/fleetest-runner")
    }

    func testResolveBaseKeepsAbsolutePathUnchanged() {
        XCTAssertEqual(RemoteLayout.resolveBase("/opt/fleetest-runner", home: "/Users/ci"),
                       "/opt/fleetest-runner")
    }

    func testResolveBaseExpandsBareTilde() {
        XCTAssertEqual(RemoteLayout.resolveBase("~", home: "/Users/ci"), "/Users/ci")
    }

    func testResolveBaseEmptyFallsBackToDefault() {
        XCTAssertEqual(RemoteLayout.resolveBase("", home: "/Users/ci"), "/Users/ci/fleetest-runner")
    }

    func testResolveBaseWhitespaceOnlyFallsBackToDefault() {
        XCTAssertEqual(RemoteLayout.resolveBase("   ", home: "/Users/ci"), "/Users/ci/fleetest-runner")
    }

    func testResolveBaseStripsTrailingSlashFromHome() {
        XCTAssertEqual(RemoteLayout.resolveBase("~/x", home: "/Users/ci/"), "/Users/ci/x")
    }

    // MARK: - RemoteTransferPlan.rsyncArgs

    func testRsyncArgs() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        XCTAssertEqual(
            RemoteTransferPlan.rsyncArgs(project: "E2E", localProjectsDir: "/local/Projects",
                                        layout: layout, sshTarget: "user@host", ignore: .none),
            [
                "-az", "--delete",
                "--exclude", "/reports", "--exclude", "/results", "--exclude", "/.fleetest",
                "/local/Projects/E2E/",
                "user@host:/Users/ci/fleetest-runner/users/alice/work/TestProjects/E2E/",
            ])
    }

    /// `.fleetest-transfer-ignore` の翻訳結果は固定除外の**後・送り元/宛先パスの前**に並ぶ
    func testRsyncArgsAppendsTransferIgnorePatternsAfterFixedExcludes() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let ignore = TransferIgnore.Scan(files: ["workspace/.fleetest-transfer-ignore"],
                                         excludePatterns: ["/workspace/*.log", "/workspace/**/*.log"])
        XCTAssertEqual(
            RemoteTransferPlan.rsyncArgs(project: "E2E", localProjectsDir: "/local/Projects",
                                        layout: layout, sshTarget: "user@host", ignore: ignore),
            [
                "-az", "--delete",
                "--exclude", "/reports", "--exclude", "/results", "--exclude", "/.fleetest",
                "--exclude", "/workspace/*.log", "--exclude", "/workspace/**/*.log",
                "/local/Projects/E2E/",
                "user@host:/Users/ci/fleetest-runner/users/alice/work/TestProjects/E2E/",
            ])
        XCTAssertEqual(
            RemoteTransferPlan.workspaceRsyncArgs(
                localWorkspaceDir: "/local/ws", project: "E2E", layout: layout, sshTarget: "user@host",
                ignore: TransferIgnore.Scan(files: [".fleetest-transfer-ignore"],
                                            excludePatterns: ["/.stub-leases/", "/**/.stub-leases/"])),
            [
                "-az", "--delete",
                "--exclude", ".git", "--exclude", ".DS_Store", "--exclude", "node_modules",
                "--exclude", "/.stub-leases/", "--exclude", "/**/.stub-leases/",
                "/local/ws/",
                "user@host:/Users/ci/fleetest-runner/users/alice/work/workspace/E2E/",
            ])
    }

    // MARK: - RemoteTransferPlan.workspaceRsyncArgs

    /// project の rsyncArgs(--exclude /reports 等)と別の除外集合(.git/.DS_Store/node_modules を
    /// 階層を問わず除外)・別の宛先(workspaceDir)であることを固定する
    func testWorkspaceRsyncArgs() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        XCTAssertEqual(
            RemoteTransferPlan.workspaceRsyncArgs(
                localWorkspaceDir: "/local/sut-ec-mobile-workspace", project: "E2E",
                layout: layout, sshTarget: "user@host", ignore: .none),
            [
                "-az", "--delete",
                "--exclude", ".git", "--exclude", ".DS_Store", "--exclude", "node_modules",
                "/local/sut-ec-mobile-workspace/",
                "user@host:/Users/ci/fleetest-runner/users/alice/work/workspace/E2E/",
            ])
    }

    // MARK: - WorkspaceRemoteDispatch.placement(2026-08-18。ワークスペースが常に有効になったため、
    // プロジェクトルート配下なら専用ミラーを組み立てない側の分岐を固定する)

    func testPlacementDefaultWorkspaceIsWithinProject() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let placement = WorkspaceRemoteDispatch.placement(
            workspaceRoot: "/repo/TestProjects/E2E/workspace",
            projectRoot: "/repo/TestProjects/E2E",
            layout: layout, project: "E2E")
        XCTAssertEqual(placement, .withinProject(
            remotePath: "/Users/ci/fleetest-runner/users/alice/work/TestProjects/E2E/workspace"))
    }

    /// プロジェクトルートそのものを指したとき(相対パスが空文字列)は projectDir 自身を返す
    func testPlacementWorkspaceEqualToProjectRootItself() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let placement = WorkspaceRemoteDispatch.placement(
            workspaceRoot: "/repo/TestProjects/E2E",
            projectRoot: "/repo/TestProjects/E2E",
            layout: layout, project: "E2E")
        XCTAssertEqual(placement, .withinProject(
            remotePath: "/Users/ci/fleetest-runner/users/alice/work/TestProjects/E2E"))
    }

    func testPlacementNestedCustomWorkspaceIsWithinProject() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let placement = WorkspaceRemoteDispatch.placement(
            workspaceRoot: "/repo/TestProjects/E2E/custom/ws",
            projectRoot: "/repo/TestProjects/E2E",
            layout: layout, project: "E2E")
        XCTAssertEqual(placement, .withinProject(
            remotePath: "/Users/ci/fleetest-runner/users/alice/work/TestProjects/E2E/custom/ws"))
    }

    func testPlacementExplicitOutsideProjectIsNotWithinProject() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let placement = WorkspaceRemoteDispatch.placement(
            workspaceRoot: "/shared/sut-workspace",
            projectRoot: "/repo/TestProjects/E2E",
            layout: layout, project: "E2E")
        XCTAssertEqual(placement, .outsideProject)
    }

    /// 似た名前の兄弟ディレクトリを配下と誤判定しない(文字列前方一致だと
    /// "…/E2E-Android-x" が "…/E2E-Android" の配下に見えてしまう)
    func testPlacementDoesNotMatchSiblingDirectoryWithSimilarName() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let placement = WorkspaceRemoteDispatch.placement(
            workspaceRoot: "/repo/TestProjects/E2E-Android-x/workspace",
            projectRoot: "/repo/TestProjects/E2E-Android",
            layout: layout, project: "E2E-Android")
        XCTAssertEqual(placement, .outsideProject)
    }

    /// 逆方向(projectRoot が子を含む長いパス)も配下と誤判定しない
    func testPlacementDoesNotMatchWhenProjectRootIsLongerThanWorkspaceRoot() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let placement = WorkspaceRemoteDispatch.placement(
            workspaceRoot: "/repo/TestProjects",
            projectRoot: "/repo/TestProjects/E2E",
            layout: layout, project: "E2E")
        XCTAssertEqual(placement, .outsideProject)
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
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        XCTAssertEqual(
            RemoteArtifactCollection.resultsRsyncArgs(
                project: "E2E", layout: layout, sshTarget: "user@host",
                localProjectsDir: "/local/Projects"),
            [
                "-az",
                "user@host:/Users/ci/fleetest-runner/users/alice/work/TestProjects/E2E/results/",
                "/local/Projects/E2E/results/",
            ])
    }

    /// --delete が無いこと(ローカルの results を巻き添えで消さない)と、両パスとも末尾スラッシュを
    /// 保つこと(rsync のディレクトリ中身コピー契約)を確認
    func testResultsRsyncArgsOmitsDeleteAndKeepsTrailingSlashes() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let args = RemoteArtifactCollection.resultsRsyncArgs(
            project: "E2E", layout: layout, sshTarget: "user@host",
            localProjectsDir: "/local/Projects")
        XCTAssertFalse(args.contains("--delete"), "\(args)")
        XCTAssertTrue(args[1].hasSuffix("/"), args[1])
        XCTAssertTrue(args[2].hasSuffix("/"), args[2])
    }

    // MARK: - RemoteArtifactCollection.recordsOnlyRsyncArgs

    /// 録画(recordings/)だけを除外し、src/dst は resultsRsyncArgs と同一であること —— on-demand
    /// でも実績 JSON は resultsRsyncArgs と同じ場所から同じ場所へ回収されることを固定する
    func testRecordsOnlyRsyncArgsExcludesRecordingsAndOmitsDelete() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let args = RemoteArtifactCollection.recordsOnlyRsyncArgs(
            project: "E2E", layout: layout, sshTarget: "user@host",
            localProjectsDir: "/local/Projects")
        XCTAssertEqual(args, [
            "-az", "--exclude", "recordings/",
            "user@host:/Users/ci/fleetest-runner/users/alice/work/TestProjects/E2E/results/",
            "/local/Projects/E2E/results/",
        ])
        XCTAssertFalse(args.contains("--delete"), "\(args)")

        let resultsArgs = RemoteArtifactCollection.resultsRsyncArgs(
            project: "E2E", layout: layout, sshTarget: "user@host",
            localProjectsDir: "/local/Projects")
        XCTAssertEqual(args.filter { $0 != "--exclude" && $0 != "recordings/" }, resultsArgs)
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
    /// して解決しようとする。**ただし渡すのは "local" 固定** —— ローカルエイリアスは発行側だけの
    /// 概念でリモートへ出さない(転送時に RunnerProfileView が畳む。2026-08-26 ユーザー決定)
    func testRemoteRunArgsRelaysTheDeviceScope() {
        let args = RemoteRunArgs.build(
            project: "E2E", profile: "mixed", scenarios: [], folders: [],
            deviceNames: ["iPhone-01", "iPhone-02"], deviceMachine: "M1Max",
            heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
            fastInput: false, enableAnimations: false, performanceMode: false,
            remoteJUnitPath: nil, reportDir: nil)
        XCTAssertEqual(
            args,
            ["run", "--project", "E2E", "--profile", "mixed", "--quiet", "--host", "local",
             "--device", "iPhone-01", "iPhone-02", "--device-machine", "local"])
        XCTAssertFalse(args.contains("M1Max"), "ローカルエイリアスが引数に出てはいけない: \(args)")
    }

    /// **束ね鍵は中継しないとリモートの run.json に載らない** —— 載らないと、その機械で撮った
    /// 録画だけが束から外れて別セッションに並ぶ(RunMetaRecord.runGroup の宣言)
    func testRemoteRunArgsRelaysTheRunGroup() {
        let args = RemoteRunArgs.build(
            project: "E2E", profile: "mixed", scenarios: [], folders: [],
            heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
            fastInput: false, enableAnimations: false, performanceMode: false,
            remoteJUnitPath: nil, reportDir: nil, runGroup: "20260826-0100Z-LDIPC96-abcd")
        XCTAssertEqual(Array(args.suffix(2)), ["--run-group", "20260826-0100Z-LDIPC96-abcd"], "\(args)")

        let api = RemoteRunArgs.buildApi(
            project: "E2E", profile: "mixed", scenarios: [],
            heal: false, noLPT: false, lptHistoryRuns: nil, performanceMode: false,
            defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil,
            runGroup: "20260826-0100Z-LDIPC96-abcd")
        XCTAssertEqual(Array(api.suffix(2)), ["--run-group", "20260826-0100Z-LDIPC96-abcd"], "\(api)")
    }

    /// 単機の run は束ねる相手が居ないので鍵を渡さない(旧レコードと同じ形を保つ)
    func testRemoteRunArgsOmitsTheRunGroupWhenAbsent() {
        let args = RemoteRunArgs.build(
            project: "E2E", profile: "mixed", scenarios: [], folders: [],
            heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
            fastInput: false, enableAnimations: false, performanceMode: false,
            remoteJUnitPath: nil, reportDir: nil)
        XCTAssertFalse(args.contains("--run-group"), "\(args)")
    }

    /// `--broadcast` は中継しないとリモートが共有キューで走る(「全台で1回ずつ」が黙って分配に化ける)
    func testRemoteRunArgsRelaysBroadcast() {
        let args = RemoteRunArgs.build(
            project: "E2E", profile: "p", scenarios: ["Warm.up"], folders: [],
            heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
            fastInput: false, enableAnimations: false, performanceMode: false, broadcast: true,
            remoteJUnitPath: nil, reportDir: nil)
        XCTAssertTrue(args.contains("--broadcast"), "\(args)")
        let without = RemoteRunArgs.build(
            project: "E2E", profile: "p", scenarios: ["Warm.up"], folders: [],
            heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
            fastInput: false, enableAnimations: false, performanceMode: false,
            remoteJUnitPath: nil, reportDir: nil)
        XCTAssertFalse(without.contains("--broadcast"))
    }

    /// remoteControl.workspace が宣言されているプロファイルだけ `--workspace` が付く(渡さないと
    /// 子は自分のリポジトリルート基準で appPath を解決し、ミラーしていない絶対パスを見に行く)
    func testRemoteRunArgsRelaysWorkspaceOnlyWhenGiven() {
        let withWorkspace = RemoteRunArgs.build(
            project: "E2E", profile: "p", scenarios: [], folders: [],
            heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
            fastInput: false, enableAnimations: false, performanceMode: false,
            remoteJUnitPath: nil, reportDir: nil,
            workspace: "/Users/ci/fleetest-runner/work/workspace/E2E")
        guard let index = withWorkspace.firstIndex(of: "--workspace") else {
            return XCTFail("--workspace が無い: \(withWorkspace)")
        }
        XCTAssertEqual(withWorkspace[index + 1], "/Users/ci/fleetest-runner/work/workspace/E2E")

        let withoutWorkspace = RemoteRunArgs.build(
            project: "E2E", profile: "p", scenarios: [], folders: [],
            heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
            fastInput: false, enableAnimations: false, performanceMode: false,
            remoteJUnitPath: nil, reportDir: nil)
        XCTAssertFalse(withoutWorkspace.contains("--workspace"), "\(withoutWorkspace)")
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

    /// リモートで走る fleetest が**もう一度ディスパッチしない**ことを固定する。転送された
    /// マシンプロファイルには host(= そのリモート自身の名前)が入っているので、--host local が
    /// 抜けると向こうの MachineDispatch が自動ディスパッチに入り、登録簿次第で
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
    /// 存在しないフラグを渡すとリモートの fleetest が起動時に落ちるので、**混入しないこと**を固定する
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
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let command = RemoteShell.remoteRunCommand(
            layout: layout,
            fleetestArgs: ["run", "--project", "E2E", "--profile", "ios-inapp", "--quiet"])
        let workDir = "/Users/ci/fleetest-runner/users/alice/work"
        let binary = "/Users/ci/fleetest-runner/foundation-tester/.build/debug/fleetest"
        XCTAssertEqual(command,
            "cd '\(workDir)' 2>/dev/null && test -f Package.swift || "
            + "{ echo \"no runner workspace at \(workDir) — run: fleetest remote setup"
            + " <this host> once for this issuer (docs/remote-runner.md §18)\" >&2; exit 91; } && "
            + "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\" && "
            + "export FT_RUNNER_BASE='/Users/ci/fleetest-runner' && test -x '\(binary)' || "
            + "{ echo \"fleetest binary not found on remote — run: swift build --product fleetest\" >&2; exit 90; } && "
            + "'\(binary)' project sync >/dev/null 2>&1 || true && "
            + "'\(binary)' 'run' '--project' 'E2E' '--profile' 'ios-inapp' '--quiet'")
    }

    /// 登録簿に枠が設定されている機械へは `FT_FM_CONCURRENCY` を運ぶ。
    /// **設定が無ければ1バイトも足さない**(ランナー側の既定に任せる)—— 両方向を固定するのは、
    /// 「常に出す」変異も「常に出さない」変異も、片方だけのテストでは素通りするため
    func testRemoteRunCommandCarriesFMConcurrencyOnlyWhenSet() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let withSlots = RemoteShell.remoteRunCommand(
            layout: layout, fleetestArgs: ["run"], fmConcurrency: 1)
        XCTAssertTrue(withSlots.contains("export FT_FM_CONCURRENCY='1' && "), withSlots)

        let without = RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: ["run"])
        XCTAssertFalse(without.contains("FT_FM_CONCURRENCY"), without)
    }

    /// 未 setup の発行者(work が無い)は exit 91 の専用ガードで fail fast する(§18.2)。
    /// バイナリ不在(exit 90)より手前に置く —— workspace 自体が無ければバイナリの有無を
    /// 問うても意味が無い
    func testRemoteRunCommandGuardsMissingIssuerWorkspaceBeforeBinaryGuard() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let command = RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: ["run"])
        guard let workspaceGuardRange = command.range(of: "exit 91"),
              let binaryGuardRange = command.range(of: "exit 90") else {
            return XCTFail("expected both guards present: \(command)")
        }
        XCTAssertTrue(workspaceGuardRange.lowerBound < binaryGuardRange.lowerBound, command)
        XCTAssertTrue(command.contains("fleetest remote setup"), command)
    }

    /// 発行者はディスパッチ側から FT_ISSUER で運ぶ(LocalConfig.resolveIssuerId が最優先で読む
    /// 契約)。ランナー機側で解決させると全員が共有アカウントの同じ値になり帰属が消える
    func testRemoteRunCommandExportsIssuerWhenGiven() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let command = RemoteShell.remoteRunCommand(
            layout: layout, fleetestArgs: ["run", "--quiet"], issuer: "tanaka@dev-mbp")
        XCTAssertTrue(command.contains("export FT_ISSUER='tanaka@dev-mbp' && "), command)
        // 位置は PATH 補正の後・バイナリ存在ガードの前(run 本体より先に環境が立っていること)。
        // 強制アンラップしない ―― 変異で FT_ISSUER が消えたとき、クラッシュはこのプロセスの
        // 後続テスト全部を巻き添えにする(失敗で止まる形に保つ)
        guard let issuerRange = command.range(of: "FT_ISSUER"),
              let pathRange = command.range(of: "export PATH"),
              let guardRange = command.range(of: "test -x") else {
            return XCTFail("expected markers missing: \(command)")
        }
        XCTAssertTrue(pathRange.lowerBound < issuerRange.lowerBound, command)
        XCTAssertTrue(issuerRange.lowerBound < guardRange.lowerBound, command)
    }

    /// ランナー機の base を子へ渡す(FTCore.RunnerBase)。**run と exec の両方**に無いと、
    /// その経路の子だけ dispatch.lock を読めず、占有中でも配信を張り続ける(§18.2 M2)
    func testBothRemoteCommandsExportTheRunnerBase() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        for command in [RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: ["run"]),
                        RemoteShell.remoteExecCommand(layout: layout, args: ["api", "monitor"])] {
            XCTAssertTrue(command.contains("export FT_RUNNER_BASE='/Users/ci/fleetest-runner' && "), command)
            guard let baseRange = command.range(of: "FT_RUNNER_BASE"),
                  let launchRange = command.range(of: "test -x") else {
                return XCTFail("expected markers missing: \(command)")
            }
            XCTAssertTrue(baseRange.lowerBound < launchRange.lowerBound, command)
        }
    }

    /// `remote exec` の子も発行者を知る必要がある(ロックの保持者が自分かを判定する = HostOccupancy)。
    /// exec が入るのは `users/<issuer>/work` なので、そのネームスペースの持ち主を渡す
    func testRemoteExecCommandExportsTheNamespaceIssuer() {
        let layout = RemoteLayout(base: "/b", issuer: "a'; rm -rf /; '")
        let command = RemoteShell.remoteExecCommand(layout: layout, args: ["api", "monitor"])
        XCTAssertTrue(command.contains("export FT_ISSUER='a'\\''; rm -rf /; '\\'''"), command)
    }

    func testRemoteRunCommandQuotesIssuerAgainstShellInjection() {
        let layout = RemoteLayout(base: "/b", issuer: "alice")
        let command = RemoteShell.remoteRunCommand(
            layout: layout, fleetestArgs: ["run"], issuer: "a'; rm -rf /; '")
        XCTAssertTrue(command.contains("export FT_ISSUER='a'\\''; rm -rf /; '\\'''"), command)
    }

    // MARK: - RemoteHooksReap / RemoteDiskUsage / 録画の後始末(共有ランナーの片付け)

    /// 孤児 hooks が掴んでいるのは**ポート = ホスト全体の資源**なので、片付けは発行者を跨ぐ。
    /// **1 ssh に収める**(発行者の数だけ往復を増やさない)
    func testHooksReapSweepsEveryIssuerAndTheLegacyWorkDirInOneCommand() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let command = RemoteHooksReap.commandAcrossIssuers(layout: layout, quiet: true)
        XCTAssertTrue(command.contains("find '/Users/ci/fleetest-runner/users'"), command)
        XCTAssertTrue(command.contains("'/Users/ci/fleetest-runner/work'"), command)
        // **グロブを使わない** —— ssh の相手は zsh で、`for w in <マッチしないグロブ>` は
        // シェルごと落ちる(まだ誰も setup していないランナーで旧 work の掃除まで消える。
        // 2026-08-31 に実機で確認)。find なら1件も無いときは空の出力になるだけ
        XCTAssertFalse(command.contains("*"), command)
        XCTAssertTrue(command.contains("'hooks' 'reap' '--quiet'"), command)
        // 終了スクリプトは adb 等を呼ぶ(非対話 ssh の PATH には Homebrew が入らない)
        XCTAssertTrue(command.contains("/opt/homebrew/bin"), command)
        // 片付けの失敗でディスパッチを止めない
        XCTAssertTrue(command.contains("|| true"), command)
        XCTAssertFalse(RemoteHooksReap.commandAcrossIssuers(layout: layout, quiet: false)
            .contains("'--quiet'"))
    }

    func testDiskUsageParsesDuOutputPerIssuer() {
        let output = "1024\t/b/users/alice/work\n4096\t/b/users/bob/work\n8\t/b/work\n"
        let rows = RemoteDiskUsage.parse(output, usersDir: "/b/users", base: "/b")
        // 大きい順(消す判断に使う欄)
        XCTAssertEqual(rows.map(\.issuer), ["bob", "alice", RemoteDiskUsage.legacyLabel])
        XCTAssertEqual(rows.map(\.kb), [4096, 1024, 8])
    }

    /// 壊れた1行で全体を失わない・想定外のパスは拾わない
    func testDiskUsageIgnoresUnparsableAndForeignLines() {
        let output = "not a row\n1024\t/other/place\nxx\t/b/users/alice/work\n7\t/b/users/carol/work\n"
        let rows = RemoteDiskUsage.parse(output, usersDir: "/b/users", base: "/b")
        XCTAssertEqual(rows.map(\.issuer), ["carol"])
    }

    /// 回収した録画はランナーに残さない(docs/remote-runner.md §15.4)。**消すのは録画だけ**
    func testDeleteRecordingsCommandTargetsOnlyRecordings() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let command = RemoteArtifactCollection.deleteRecordingsCommand(project: "E2E", layout: layout)
        // 置き場は `results/runs/<YYYY-MM>/<runID>/recordings`(RunResultsStore.runDir)。
        // **月の階層を数え間違えると1件も消えない**(黙って効かない = 気付けない失敗)
        let runs = "'/Users/ci/fleetest-runner/users/alice/work/TestProjects/E2E/results/runs'"
        XCTAssertEqual(
            command,
            "if [ -d \(runs) ]; then find \(runs) -mindepth 3 -maxdepth 3 -type d"
            + " -name recordings -exec rm -rf {} +; fi")
        // グロブは使わない(zsh のマッチ無しでコマンドが失敗し、録画の無い run のたびに警告が出る)
        XCTAssertFalse(command.contains("*"), command)
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

    /// ApiRunMachineFanout がホストごとの子(`api run --host <label>`)を立てるようになったため、
    /// `api run --host` のリモート実行にも `run --host` と同じデバイス絞り込みの中継が要る
    /// (testRemoteRunArgsRelaysTheDeviceScope と対。渡さないと向こうが全ホストぶんの台を掴む)
    func testBuildApiRelaysTheDeviceScope() {
        let args = RemoteRunArgs.buildApi(
            project: "E2E", profile: "mixed", scenarios: ["Login.S0010"],
            deviceNames: ["iPhone-01", "iPhone-02"], deviceMachine: "M1Max",
            heal: false, noLPT: false, lptHistoryRuns: nil,
            performanceMode: false,
            defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil)
        XCTAssertEqual(
            args,
            ["api", "run", "--project", "E2E", "--profile", "mixed", "--host", "local",
             "--device", "iPhone-01", "iPhone-02", "--device-machine", "local",
             "--scenario", "Login.S0010"])
        XCTAssertFalse(args.contains("M1Max"), "ローカルエイリアスが引数に出てはいけない: \(args)")
    }

    /// build() と対(testRemoteRunArgsRelaysWorkspaceOnlyWhenGiven)。`api run --host` にも
    /// 同じ規律で --workspace が中継される
    func testBuildApiRelaysWorkspaceOnlyWhenGiven() {
        let withWorkspace = RemoteRunArgs.buildApi(
            project: "E2E", profile: "p", scenarios: ["Login.S0010"],
            heal: false, noLPT: false, lptHistoryRuns: nil,
            performanceMode: false, defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil,
            workspace: "/Users/ci/fleetest-runner/work/workspace/E2E")
        guard let index = withWorkspace.firstIndex(of: "--workspace") else {
            return XCTFail("--workspace が無い: \(withWorkspace)")
        }
        XCTAssertEqual(withWorkspace[index + 1], "/Users/ci/fleetest-runner/work/workspace/E2E")

        let withoutWorkspace = RemoteRunArgs.buildApi(
            project: "E2E", profile: "p", scenarios: ["Login.S0010"],
            heal: false, noLPT: false, lptHistoryRuns: nil,
            performanceMode: false, defaultTimeout: nil, scenarioTimeout: nil, reportDir: nil)
        XCTAssertFalse(withoutWorkspace.contains("--workspace"), "\(withoutWorkspace)")
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
        // 欠陥2: scenarioCount 0 は「0本」ではなく「見積り不能」(プロファイル全体・
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

    // MARK: - RemoteDispatchFlagPolicy.forceLockRejection(リモートへ行きうる指定があれば受ける)

    func testForceLockIsAcceptedWithAnExplicitHostOrFleet() {
        XCTAssertNil(RemoteDispatchFlagPolicy.forceLockRejection(host: "M1Max", fleet: nil, profile: nil))
        XCTAssertNil(RemoteDispatchFlagPolicy.forceLockRejection(host: nil, fleet: "nightly", profile: nil))
    }

    /// **プロファイルだけでも受ける** —— マシンプロファイル経由の自動ディスパッチや、
    /// デバイスが複数の機械にまたがるプロファイル(ホスト別の子へ分かれる)では `--host` を打たない。
    /// ここを拒否していたため、中断した run が残したロックを解除する手段が無かった
    func testForceLockIsAcceptedWithAProfileAlone() {
        XCTAssertNil(RemoteDispatchFlagPolicy.forceLockRejection(
            host: nil, fleet: nil, profile: "android_local+remote"))
    }

    func testForceLockIsRejectedWhenNothingCanDispatchRemotely() {
        let message = RemoteDispatchFlagPolicy.forceLockRejection(host: nil, fleet: nil, profile: nil)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("--force-lock") == true, message ?? "")
    }

    // MARK: - RemoteDispatchFlagPolicy.waitLockRejection(forceLockRejection と同じ判定)

    func testWaitLockIsAcceptedWithAnExplicitHostOrFleetOrProfileAlone() {
        XCTAssertNil(RemoteDispatchFlagPolicy.waitLockRejection(host: "M1Max", fleet: nil, profile: nil))
        XCTAssertNil(RemoteDispatchFlagPolicy.waitLockRejection(host: nil, fleet: "nightly", profile: nil))
        XCTAssertNil(RemoteDispatchFlagPolicy.waitLockRejection(
            host: nil, fleet: nil, profile: "android_local+remote"))
    }

    func testWaitLockIsRejectedWhenNothingCanDispatchRemotely() {
        let message = RemoteDispatchFlagPolicy.waitLockRejection(host: nil, fleet: nil, profile: nil)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("--wait-lock") == true, message ?? "")
    }

    // MARK: - RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock(待つと奪うは矛盾)

    func testWaitLockAndForceLockDoNotConflictWhenOnlyOneIsSet() {
        XCTAssertNil(RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock(forceLock: false, waitLock: 30))
        XCTAssertNil(RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock(forceLock: true, waitLock: nil))
    }

    func testWaitLockAndForceLockDoNotConflictWhenNeitherIsSet() {
        XCTAssertNil(RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock(forceLock: false, waitLock: nil))
    }

    func testWaitLockAndForceLockConflictWhenBothAreSet() {
        let message = RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock(forceLock: true, waitLock: 30)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("--wait-lock") == true, message ?? "")
        XCTAssertTrue(message?.contains("--force-lock") == true, message ?? "")
    }

    // MARK: - WaitLockPolling(純粋なポーリング判断)

    func testWaitLockPollingRetriesBelowLimit() {
        XCTAssertEqual(WaitLockPolling.decide(elapsedSeconds: 0, limitSeconds: 30), .retry)
        XCTAssertEqual(WaitLockPolling.decide(elapsedSeconds: 20, limitSeconds: 30), .retry)
    }

    func testWaitLockPollingGivesUpAtOrAboveLimit() {
        XCTAssertEqual(WaitLockPolling.decide(elapsedSeconds: 30, limitSeconds: 30), .giveUp)
        XCTAssertEqual(WaitLockPolling.decide(elapsedSeconds: 40, limitSeconds: 30), .giveUp)
    }

    func testWaitLockPollingLogsProgressAtStartAndEveryProgressInterval() {
        XCTAssertTrue(WaitLockPolling.shouldLogProgress(elapsedSeconds: 0))
        XCTAssertTrue(WaitLockPolling.shouldLogProgress(elapsedSeconds: 60))
        XCTAssertTrue(WaitLockPolling.shouldLogProgress(elapsedSeconds: 120))
    }

    func testWaitLockPollingSkipsProgressBetweenIntervals() {
        XCTAssertFalse(WaitLockPolling.shouldLogProgress(elapsedSeconds: 10))
        XCTAssertFalse(WaitLockPolling.shouldLogProgress(elapsedSeconds: 30))
        XCTAssertFalse(WaitLockPolling.shouldLogProgress(elapsedSeconds: 50))
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

    /// 5行形(4行目 = CPU モデル・5行目 = コア数)。先頭3行の妥当性判定は3行形と同一
    func testParseSessionInfoFiveLinesIncludesHardware() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max\n10")
        XCTAssertEqual(info, RemoteSessionInfo(home: "/Users/ci", consoleUser: "alice", sshUser: "alice",
                                               processorModel: "Apple M1 Max", coreCount: 10))
    }

    func testParseSessionInfoFiveLinesAcceptsTrailingNewline() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max\n10\n")
        XCTAssertEqual(info?.processorModel, "Apple M1 Max")
        XCTAssertEqual(info?.coreCount, 10)
    }

    /// 4行目が空(トリム後)なら processorModel は nil。セッション情報自体は活かす
    func testParseSessionInfoFiveLinesEmptyProcessorModelBecomesNil() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\n \n10")
        XCTAssertNotNil(info)
        XCTAssertNil(info?.processorModel)
        XCTAssertEqual(info?.coreCount, 10)
    }

    /// 5行目が Int にパースできなければ coreCount は nil
    func testParseSessionInfoFiveLinesNonIntegerCoreCountBecomesNil() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max\nnot-a-number")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.processorModel, "Apple M1 Max")
        XCTAssertNil(info?.coreCount)
    }

    /// 行数が3でも5でもなければ従来どおり nil(4行・6行等)
    func testParseSessionInfoFourLinesReturnsNil() {
        XCTAssertNil(RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice\nApple M1 Max"))
    }

    /// 3行形は5行形の追加ロジックの影響を受けない(hardware は nil のまま)
    func testParseSessionInfoThreeLinesHasNilHardware() {
        let info = RemoteProbe.parseSessionInfo("/Users/ci\nalice\nalice")
        XCTAssertNil(info?.processorModel)
        XCTAssertNil(info?.coreCount)
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
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let tool = "\"/Users/ci/fleetest-runner/foundation-tester\""
        let binary = "\"/Users/ci/fleetest-runner/foundation-tester/.build/debug/fleetest\""
        let base = "\"/Users/ci/fleetest-runner\""
        XCTAssertEqual(
            RemoteStatusProbe.command(layout: layout),
            "echo $HOME; if launchctl print gui/$(id -u) >/dev/null 2>&1; then id -un;"
            + " else stat -f%Su /dev/console; fi; id -un; echo '---FT---'; "
            + "git -C \(tool) rev-parse HEAD 2>/dev/null || echo -; echo '---FT---'; "
            + "xcodebuild -version; echo '---FT---'; "
            + "xcrun --sdk iphonesimulator --show-sdk-build-version; echo '---FT---'; "
            + "test -x \(binary) && echo yes || echo no; echo '---FT---'; "
            + "df -k \(base) | tail -1; echo '---FT---'; "
            + "if [ -d \"/Users/ci/fleetest-runner/.fleetest/dispatch.lock\" ]; then echo held;"
            + " cat \"/Users/ci/fleetest-runner/.fleetest/dispatch.lock/info.json\" 2>/dev/null || true;"
            + " else echo absent; fi; echo '---FT---'; "
            // FM の死活台帳。**レイアウトの外**(~/.fleetest)を読む —— FM はホストの資源で、
            // プロジェクトにも発行者にも属さない。**実呼び出しは混ぜない**(status がホストの
            // FM を消費し、ホスト数ぶん直列化の枠を奪うことになる)
            + "cat \"$HOME/.fleetest/fm-liveness.json\" 2>/dev/null || true")
    }

    /// 占有(誰が使っているか)を **remote status の1往復に相乗りさせる**(§18.1 #1)。
    /// 別の ssh を足すとホスト数ぶん往復が増える
    func testStatusProbeParsesTheDispatchLockBlock() {
        let info = RemoteDispatchLock.encode(RemoteDispatchLockInfo(
            issuerHost: "dev-mbp", pid: 7, acquiredAt: "2026-08-31T00:00:00Z", issuer: "bob")) ?? ""
        let free = statusOutput(
            session: "/Users/ci\nalice\nalice", revision: "abc123",
            xcodeVersion: "Xcode 27.0\nBuild version 27A5228h", sdkBuild: "27A5228h",
            binary: "yes", df: "/dev/disk3s1s1  965538800 542000000 400000000   58%    /")
        XCTAssertEqual(RemoteStatusProbe.parse(free + "\n\(Self.statusSeparator)\nabsent").lock, .absent)
        let held = RemoteStatusProbe.parse(free + "\n\(Self.statusSeparator)\nheld\n\(info)").lock
        XCTAssertEqual(held, .held(RemoteDispatchLock.decode(info)))
        // **旧ランナー(ブロックが6個しか無い)は nil = 判定不能**。空きに倒すと、
        // 実際は走っている run を「空いている」と表示してしまう
        XCTAssertNil(RemoteStatusProbe.parse(free).lock)
    }

    /// $HOME を未解決のまま埋め込んだ layout(remote status の実運用形)でも
    /// 二重引用符で包むだけで壊れない(単一引用符と違い変数展開を妨げない)ことを確認
    func testStatusProbeCommandQuotesDoNotSuppressHomeExpansion() {
        let layout = RemoteLayout(base: RemoteLayout.resolveBase("~/fleetest-runner", home: "$HOME"), issuer: "alice")
        XCTAssertTrue(RemoteStatusProbe.command(layout: layout).contains("\"$HOME/fleetest-runner/foundation-tester\""))
    }

    // MARK: - RemoteStatusProbe.dquote

    func testDquotePlainPathUnaffected() {
        XCTAssertEqual(RemoteStatusProbe.dquote("/Users/ci/fleetest-runner"), "\"/Users/ci/fleetest-runner\"")
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
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 7, dryRun: true)
        XCTAssertEqual(commands.count, 7)
        for command in commands {
            XCTAssertTrue(command.hasSuffix("-print"), command)
            XCTAssertFalse(command.contains("-exec"), command)
        }
    }

    func testCleanPlanNonDryRunUsesExecRm() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 7, dryRun: false)
        for command in commands {
            XCTAssertTrue(command.hasSuffix("-exec rm -rf {} +"), command)
        }
    }

    func testCleanPlanKeepDaysReflected() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 30, dryRun: true)
        for command in commands {
            XCTAssertTrue(command.contains("-mtime +30"), command)
        }
    }

    /// 全発行者(`users/*/work`)+ 旧レイアウト(`work`)を横断する(§18.2)。ディスクはホスト共有
    /// 資源なので保持ポリシーは全員分に掛ける
    func testCleanPlanCoversAllIssuersAndTheLegacyLayout() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 7, dryRun: true)
        let base = "'/Users/ci/fleetest-runner'"
        // 配信の控えはホスト共有の1箇所(発行者ネームスペースの外)。**死んだ pid の控えが
        // 溜まると、pid が一巡したときにその台の配信が誰にも張れなくなる**ので上限を作る
        XCTAssertTrue(commands[0].contains("\(base)/.fleetest/streams"), commands[0])
        XCTAssertTrue(commands[1].contains("\(base)/users/*/work/.fleetest/dispatch"), commands[1])
        XCTAssertTrue(commands[2].contains("\(base)/users/*/work/TestProjects/*/reports"), commands[2])
        XCTAssertTrue(commands[3].contains("\(base)/users/*/work/TestProjects/*/results"), commands[3])
        XCTAssertTrue(commands[4].contains("\(base)/work/.fleetest/dispatch"), commands[4])
        XCTAssertTrue(commands[5].contains("\(base)/work/TestProjects/*/reports"), commands[5])
        XCTAssertTrue(commands[6].contains("\(base)/work/TestProjects/*/results"), commands[6])
    }

    /// `--dry-run` は**何も変えない**。`devices down` は走っている run を巻き添えにする破壊的操作
    /// なので、プレビューでは撃たない(2026-08-16 に実機で踏んだ: dry-run のつもりで
    /// ランナーのブリッジが落ちた)
    func testDryRunDoesNotStopDevices() {
        XCTAssertFalse(RemoteCleanPlan.stopsDevices(dryRun: true))
        XCTAssertTrue(RemoteCleanPlan.stopsDevices(dryRun: false))
    }

    func testCleanPlanQuotesTheBasePortion() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest runner", issuer: "alice")
        let commands = RemoteCleanPlan.commands(layout: layout, keepDays: 7, dryRun: true)
        // 添字ではなく「どのコマンドか」で選ぶ(先頭に別のターゲットが増えても意味が変わらない)
        guard let usersCommand = commands.first(where: { $0.contains("/users/") }) else {
            return XCTFail("expected a per-issuer target: \(commands)")
        }
        XCTAssertTrue(usersCommand.contains("'/Users/ci/fleetest runner'/users/*/work"), usersCommand)
    }

    // MARK: - RemoteLayout.validateBase(コマンド置換の入口ガード)

    func testValidateBaseAcceptsOrdinaryPaths() throws {
        try RemoteLayout.validateBase("~/fleetest-runner")
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
                recorded: ".fleetest/dispatch/20260816-130735-24451/reports/scenario-1-S0010.md",
                stamp: "20260816-130735-24451",
                projectReportsPathFromRepoRoot: "TestProjects/E2E-iOS/reports"),
            "TestProjects/E2E-iOS/reports/scenario-1-S0010.md")
    }

    /// **他の run の記録に触らない**。別のディスパッチ(別 stamp)の記録は対象外
    func testReportPathOfAnotherDispatchIsLeftAlone() {
        XCTAssertNil(RemoteReportLink.rewrittenReportPath(
            recorded: ".fleetest/dispatch/20260816-999999-11111/reports/scenario-1-S0010.md",
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
            recorded: ".fleetest/dispatch/20260816-130735-24451/reports/sub/scenario-1-S0010.md",
            stamp: "20260816-130735-24451",
            projectReportsPathFromRepoRoot: "TestProjects/E2E-iOS/reports"))
    }

    // MARK: - RemoteArtifactCollection.isMissingSourceFailure

    /// run が成果物を作る前に落ちたときの rsync 失敗(転送元不在)は黙る。**実際の rsync の
    /// 文言で固定する** —— これを warning にすると、本当の失敗理由の下にノイズが積まれる
    func testMissingSourceFailureIsDetectedFromRsyncStderr() {
        let stderr = """
            rsync: [sender] change_dir "/Users/ci/fleetest-runner/work/.fleetest/dispatch/20260816-080316-95613/reports" \
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
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let command = RemoteShell.remoteExecCommand(layout: layout, args: ["doctor", "--fm-only"])
        let workDir = "/Users/ci/fleetest-runner/users/alice/work"
        let binary = "/Users/ci/fleetest-runner/foundation-tester/.build/debug/fleetest"
        XCTAssertEqual(command,
            "cd '\(workDir)' 2>/dev/null && test -f Package.swift || "
            + "{ echo \"no runner workspace at \(workDir) — run: fleetest remote setup"
            + " <this host> once for this issuer (docs/remote-runner.md §18)\" >&2; exit 91; } && "
            + "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\" && "
            + "export FT_RUNNER_BASE='/Users/ci/fleetest-runner' && export FT_ISSUER='alice' && test -x '\(binary)' || "
            + "{ echo \"fleetest binary not found on remote — run: swift build --product fleetest\" >&2; exit 90; } && "
            + "'\(binary)' 'doctor' '--fm-only'")
    }

    /// 照会・単発操作が目的で、run 専用の `project sync` を混ぜてはいけない
    /// (remoteRunCommand との唯一の差分。壊すと remote exec のたびに無駄な sync が走る)
    func testRemoteExecCommandDoesNotSyncProject() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let command = RemoteShell.remoteExecCommand(layout: layout, args: ["devices", "down"])
        XCTAssertFalse(command.contains("project sync"), command)
    }

    func testRemoteExecCommandQuotesEachArgumentIndependently() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let command = RemoteShell.remoteExecCommand(layout: layout, args: ["api", "device-catalog"])
        XCTAssertTrue(command.hasSuffix("'api' 'device-catalog'"), command)
    }

    /// exec も未 setup の発行者を exit 91 で fail fast する(remoteRunCommand と同じガード)
    func testRemoteExecCommandGuardsMissingIssuerWorkspace() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice")
        let command = RemoteShell.remoteExecCommand(layout: layout, args: ["doctor"])
        XCTAssertTrue(command.contains("exit 91"), command)
        XCTAssertTrue(command.contains("fleetest remote setup"), command)
    }
}

// MARK: - 中継・回収時のパス書き換え(手元のリポジトリルートに対応するのは workDir)

extension RemoteDispatchTests {
    /// **base ではなく workDir を写す**。base を渡すと `users/<issuer>/work` が残り、
    /// 手元に存在しないパスが画面と記録に出る(2026-08-26 の実害。§18.2 の発行者
    /// ネームスペースを足したときに追随し損ねていた)
    func testRelayRewriteMapsTheRunnerWorkDirOntoTheLocalRepoRoot() {
        let layout = RemoteLayout(base: "/Users/u/fleetest-runner", issuer: "u")
        let localRoot = "/Users/u/github/foundation-tester"
        let line = #"{"reportPath":"/Users/u/fleetest-runner/users/u/work/TestProjects/P/reports/x.md"}"#

        XCTAssertEqual(
            RemotePathRewrite.rewrite(line, remoteRoot: layout.workDir, localRoot: localRoot),
            #"{"reportPath":"/Users/u/github/foundation-tester/TestProjects/P/reports/x.md"}"#)

        XCTAssertEqual(
            RemotePathRewrite.rewrite(line, remoteRoot: layout.base, localRoot: localRoot),
            #"{"reportPath":"/Users/u/github/foundation-tester/users/u/work/TestProjects/P/reports/x.md"}"#,
            "base を渡すと壊れる(この形を出さないための witness)")
    }
}
