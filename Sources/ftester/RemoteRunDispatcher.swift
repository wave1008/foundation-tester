// RemoteRunDispatcher.swift
// `ftester run --host` のプロセス起動(ssh/rsync)を集約する。純粋ロジックは
// Sources/FTCore/RemoteDispatch.swift 側(単体テスト対象)。同一ホストへの二重ディスパッチ防止
// (dispatch.lock の取得・解放。docs/remote-runner.md §5)もここで行う。純粋ロジックは
// Sources/FTCore/RemoteDispatchLock.swift 側。

import FTCore
import Foundation

/// cliRun = `ftester run --host`(人間向け進行・出力とも stdout)。apiRun = `ftester api run
/// --host`(NDJSON 中継のため進行メッセージは stderr へ逃がす。stdout は中継行専用)
enum RemoteDispatchMode {
    case cliRun
    case apiRun
}

struct RemoteRunDispatcher {
    let host: RemoteHostSpec
    /// `--remote-dir` の生値(既定 "~/ftester-runner"。チルダ展開前)。resolveLayout が
    /// リモートの $HOME を取得してから RemoteLayout.resolveBase で絶対パスへ解決する
    let remoteDirRaw: String
    let localRepoRoot: URL
    // var: default 付き let は memberwise init から除外され .apiRun を注入できない
    var mode: RemoteDispatchMode = .cliRun
    var artifacts: RemoteArtifactsMode = .collect
    /// 登録簿エントリの machine(キャッシュ。docs/remote-runner.md §13)。nil なら
    /// `--force-lock`: 既存の dispatch.lock を奪ってから取得する(docs/remote-runner.md §5)。
    /// 既定では奪わない(stuck なロックを機械的に stale 判定しない)
    var forceLock: Bool = false

    /// 戻り値 = リモート `ftester run` の exit code
    func dispatch(project: TestProject, profile: String,
                  scenarios: [String], folders: [String],
                  deviceNames: [String] = [], deviceHost: String? = nil,
                  heal: Bool, noHeal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                  fastInput: Bool, enableAnimations: Bool, performanceMode: Bool,
                  localJUnitPath: String?,
                  remoteTimeoutSeconds: Int?) async throws -> Int32 {
        let layout = try resolveLayout()
        try checkCompatibility(layout: layout)

        try acquireDispatchLock(layout: layout)
        defer { releaseDispatchLock(layout: layout) }

        // ワークスペースの用意(ステージング)は project の rsync より先に行う。ワークスペースは
        // 既定でプロジェクトルート配下(prepareWorkspace 参照)なので、順序を逆にすると
        // 直前にステージングしたファイルが transfer() の対象から漏れる
        let remoteWorkspace = try prepareWorkspace(project: project, profile: profile, layout: layout)
        try transfer(project: project, layout: layout)

        let stamp = Self.makeStamp()
        let remoteReportDir = layout.dispatchReportDir(stamp: stamp)
        let remoteJUnitPath = localJUnitPath != nil
            ? "\(layout.workDir)/.ftester/dispatch/\(stamp)/junit.xml" : nil
        let ftesterArgs = RemoteRunArgs.build(
            project: project.name, profile: profile, scenarios: scenarios, folders: folders,
            deviceNames: deviceNames, deviceHost: deviceHost,
            heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            fastInput: fastInput, enableAnimations: enableAnimations,
            performanceMode: performanceMode,
            remoteJUnitPath: remoteJUnitPath, reportDir: remoteReportDir, workspace: remoteWorkspace)
        let timeoutSeconds = RemoteTimeout.seconds(
            explicit: remoteTimeoutSeconds, scenarioCount: scenarios.count)
        announceTimeout(timeoutSeconds)
        let exitCode = try runRemoteAndRelay(
            ftesterArgs: ftesterArgs, layout: layout, timeoutSeconds: timeoutSeconds)

        collectReports(project: project, remoteReportDir: remoteReportDir)
        if let localJUnitPath, let remoteJUnitPath {
            collectJUnit(remotePath: remoteJUnitPath, localPath: localJUnitPath, layout: layout)
        }
        collectArtifactsIfRequested(project: project, layout: layout)
        relinkCollectedReports(project: project, stamp: stamp)
        cleanupDispatchDir(layout: layout, stamp: stamp)

        log("==> remote run finished (exit \(exitCode))")
        return exitCode
    }

    /// `ftester api run --host`: dispatch と同じ流れ(レイアウト解決→適合チェック→転送→実行→回収)
    /// だが JUnit は扱わない(拡張連携は NDJSON 中継のみで完結する)。戻り値 = リモート
    /// `ftester api run` の exit code
    func dispatchApi(project: TestProject, profile: String, scenarios: [String],
                     deviceNames: [String] = [], deviceHost: String? = nil,
                     heal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                     performanceMode: Bool,
                     defaultTimeout: Double?, scenarioTimeout: Double?,
                     remoteTimeoutSeconds: Int?) async throws -> Int32 {
        let layout = try resolveLayout()
        try checkCompatibility(layout: layout)

        try acquireDispatchLock(layout: layout)
        defer { releaseDispatchLock(layout: layout) }

        // 順序の理由は dispatch() のコメント参照(prepareWorkspace は transfer() より先)
        let remoteWorkspace = try prepareWorkspace(project: project, profile: profile, layout: layout)
        try transfer(project: project, layout: layout)

        let stamp = Self.makeStamp()
        let remoteReportDir = layout.dispatchReportDir(stamp: stamp)
        let ftesterArgs = RemoteRunArgs.buildApi(
            project: project.name, profile: profile, scenarios: scenarios,
            deviceNames: deviceNames, deviceHost: deviceHost,
            heal: heal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            performanceMode: performanceMode,
            defaultTimeout: defaultTimeout, scenarioTimeout: scenarioTimeout, reportDir: remoteReportDir,
            workspace: remoteWorkspace)
        let timeoutSeconds = RemoteTimeout.seconds(
            explicit: remoteTimeoutSeconds, scenarioCount: scenarios.count)
        announceTimeout(timeoutSeconds)
        let exitCode = try runRemoteAndRelay(
            ftesterArgs: ftesterArgs, layout: layout, timeoutSeconds: timeoutSeconds)

        collectReports(project: project, remoteReportDir: remoteReportDir)
        collectArtifactsIfRequested(project: project, layout: layout)
        relinkCollectedReports(project: project, stamp: stamp)
        cleanupDispatchDir(layout: layout, stamp: stamp)

        log("==> remote run finished (exit \(exitCode))")
        return exitCode
    }

    // MARK: - 0. レイアウト解決

    /// remoteDirRaw を絶対パスへ解決する。`ssh <host> 'echo $HOME; stat -f%Su /dev/console; id -un'`
    /// を到達性プローブ兼用にする(以前の "true" プローブを置き換え。rev/toolchain は
    /// fail-closed で nil = 不一致扱いになるため、到達不能はここで先に切り分けないと compat
    /// mismatch と誤報する)。コンソールユーザー(§16.3)も同じ往復に相乗りさせて取得する
    /// — 素の $HOME だけの ssh 1本を別に足すと往復が倍になる
    private func resolveLayout() throws -> RemoteLayout {
        log("==> checking compatibility with \(host.sshTarget)")
        let result = try Shell.run(
            sshBase + [host.sshTarget, "echo $HOME; stat -f%Su /dev/console; id -un"])
        guard result.status == 0 else {
            throw RemoteDispatchError.remoteSetupFailed(
                "cannot reach \(host.sshTarget) over ssh (status \(result.status))"
                + " — check the host name and keys; BatchMode disables password prompts\n\(result.tail)")
        }
        guard let session = RemoteProbe.parseSessionInfo(result.output) else {
            // 想定外の出力(古い macOS 等): ログイン判定はスキップするが $HOME は従来どおり必須
            let firstLine = (result.output.split(separator: "\n", maxSplits: 1,
                                                 omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !firstLine.isEmpty else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "could not determine $HOME on \(host.sshTarget)")
            }
            log("warning: could not determine the remote console login state — skipping the login check")
            return RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: firstLine))
        }
        guard session.isLoggedIn else {
            throw RemoteDispatchError.remoteSetupFailed(
                "\(host.sshTarget) is sitting at the login window (console user: \(session.consoleUser), "
                + "expected: \(session.sshUser)) — unlock and log in on the runner, then retry"
                + " (docs/remote-runner.md §5)")
        }
        return RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: session.home))
    }

    /// ディスパッチ単位の一意ディレクトリ名(reports/junit の隔離・回収後の削除に使う)
    private static func makeStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "\(formatter.string(from: Date()))-\(ProcessInfo.processInfo.processIdentifier)"
    }

    // MARK: - 1. 適合チェック

    private func checkCompatibility(layout: RemoteLayout) throws {
        let localRevision = localCapture(["git", "-C", localRepoRoot.path, "rev-parse", "HEAD"])
        if let status = localCapture(["git", "-C", localRepoRoot.path, "status", "--porcelain"]),
           !status.isEmpty {
            log("warning: uncommitted local changes will NOT reach the remote")
        }

        let remoteRevision = try? sshCapture("git -C \(RemoteShell.quote(layout.toolRoot)) rev-parse HEAD")
        let localToolchain = ToolchainFingerprint.current()
        let remoteToolchain = try? remoteToolchainFingerprint()
        var reasons = RemoteCompat.mismatches(
            localRevision: localRevision, remoteRevision: remoteRevision,
            localToolchain: localToolchain, remoteToolchain: remoteToolchain)
        // rev 不一致の**いちばん多い原因は「まだ push していない」**。ランナーは origin から
        // fetch するので、押していないコミットへは remote setup でも合わせられない
        // (そのままだと checkout が exit 128 で落ちるだけ。2026-08-16 に実際に踏んだ)
        if reasons.contains(where: { $0.hasPrefix("git revision") }), let localRevision,
           !revisionIsPublished(revision: localRevision) {
            reasons.append(RemoteSetupPlan.unpublishedRevisionMessage(revision: localRevision))
        }
        guard reasons.isEmpty else { throw RemoteDispatchError.incompatible(reasons) }
    }

    /// そのコミットがリモート追跡ブランチに含まれるか。判定不能なら published 扱い
    /// (助言を足すかどうかの判断であって、実行を止める判定ではない)
    private func revisionIsPublished(revision: String) -> Bool {
        guard let result = try? Shell.run(
            ["git", "-C", localRepoRoot.path, "branch", "-r", "--contains", revision]),
              result.status == 0 else { return true }
        return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func remoteToolchainFingerprint() throws -> String {
        let xcodeVersion = try sshCapture("xcodebuild -version")
        let sdkBuild = try sshCapture("xcrun --sdk iphonesimulator --show-sdk-build-version")
        return ToolchainFingerprint.compose(xcodeVersionOutput: xcodeVersion, sdkBuild: sdkBuild)
    }

    // MARK: - 2. 同一ホストへの二重ディスパッチ防止(docs/remote-runner.md §5)

    /// フリート内の重複は FleetProfile.validate で防げるが、別フリート・別人・CLI/GUI 併走に
    /// よる同一ホストへの二重実行はここでしか防げない。**単発の `run --host` でも常に取得する**
    /// (フリート専用の仕組みにしない ―― 競合はフリートかどうかと無関係にホスト単位で起きる)
    private func acquireDispatchLock(layout: RemoteLayout) throws {
        log("==> acquiring dispatch lock on \(host.sshTarget)")
        let info = RemoteDispatchLockInfo.now(
            issuerHost: ProcessInfo.processInfo.hostName, pid: ProcessInfo.processInfo.processIdentifier)
        if forceLock {
            log("warning: --force-lock is stealing the dispatch lock on \(host.sshTarget)"
                + " (any dispatch it was protecting may still be running)")
            _ = try sshCapture(RemoteDispatchLock.forceAcquireCommand(base: layout.base, info: info))
            return
        }
        let result = try Shell.run(sshBase + [host.sshTarget, RemoteDispatchLock.acquireCommand(
            base: layout.base, info: info)])
        guard result.status == 0 else {
            guard result.status != 255 else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "cannot reach \(host.sshTarget) over ssh (status 255)\n\(result.tail)")
            }
            let existing = try? sshCapture(RemoteDispatchLock.readCommand(base: layout.base))
            let existingInfo = existing.flatMap(RemoteDispatchLock.decode)
            throw RemoteDispatchError.remoteSetupFailed(RemoteDispatchLock.heldMessage(existingInfo))
        }
    }

    /// 成功・失敗・タイムアウト・例外いずれでも defer から呼ばれる。解放の失敗は run の成否を
    /// 変えない(warn のみ。他の回収処理と同じ規律)が、ロックが残るのは事故なので隠さず言う
    private func releaseDispatchLock(layout: RemoteLayout) {
        do {
            _ = try sshCapture(RemoteDispatchLock.releaseCommand(base: layout.base))
        } catch {
            log("warning: failed to release the dispatch lock on \(host.sshTarget)"
                + " (\(error.localizedDescription)) — clear it manually if the next dispatch is refused")
        }
    }

    // MARK: - 3. 転送

    private func transfer(project: TestProject, layout: RemoteLayout) throws {
        log("==> transferring \(project.name) to \(host.sshTarget)")
        let args = ["rsync"] + RemoteTransferPlan.rsyncArgs(
            project: project.name,
            localProjectsDir: project.rootURL.deletingLastPathComponent().path,
            layout: layout, sshTarget: host.sshTarget)
        let status = try runInherited(args)
        guard status == 0 else {
            throw RemoteDispatchError.remoteSetupFailed("rsync exited with status \(status)")
        }
    }

    /// ワークスペース(既定 `<project.rootURL>/workspace`。常に有効 = docs/remote-runner.md §17・
    /// 2026-08-18)を用意し、リモートの子へ渡す `--workspace` の絶対パスを返す。**呼び出しは
    /// transfer() より先であること**(プロジェクトルート配下のときはここでのステージングだけを
    /// 行い、専用の rsync は行わない —— project の rsync(transfer)がそのまま運ぶので、
    /// 順序が逆だと直前にステージングしたファイルが漏れる)。
    ///
    /// 配下かどうかの判定は `WorkspaceRemoteDispatch.placement`(パス計算だけの純粋関数。
    /// Tests/FTCoreTests/RemoteDispatchTests.swift が固定する)。配下でない(明示指定で
    /// プロジェクト外を指した)ときだけ専用ミラー rsync を行う ―― ワークスペースを
    /// リポジトリ外(TestProjects/ の隣・上位等)に置く場合はプロジェクト転送の対象に
    /// 含まれないため
    private func prepareWorkspace(
        project: TestProject, profile: String, layout: RemoteLayout
    ) throws -> String {
        let localWorkspaceURL = ProfileResolver.effectiveWorkspaceRoot(project: project, runName: profile)
        let created = (try? WorkspaceScaffold.ensure(root: localWorkspaceURL)) ?? []
        for name in created {
            log("==> created workspace/\(name)/ (missing scaffold directory)")
        }
        // マシン/デバイス解決を経由しない軽量読み(declaredWorkspace と同じ理由)。
        // インストール先の規則は WorkspaceAppStaging.installPath 1箇所と共有する
        // (ProfileResolver.resolve が ResolvedAppTarget.appPath を計算するのと同じ規則)
        for (platform, source) in ProfileResolver.declaredAppPaths(project: project, runName: profile)
            .sorted(by: { $0.key < $1.key }) {
            let dest = WorkspaceAppStaging.installPath(source: source, workspaceRoot: localWorkspaceURL)
            if try WorkspaceAppStaging.stageApp(source: source, dest: dest) {
                log("==> staged \(platform) app package into the workspace")
            }
        }

        switch WorkspaceRemoteDispatch.placement(
            workspaceRoot: localWorkspaceURL.path, projectRoot: project.rootURL.path,
            layout: layout, project: project.name
        ) {
        case .withinProject(let remotePath):
            return remotePath
        case .outsideProject:
            log("==> mirroring the workspace to \(host.sshTarget)")
            let args = ["rsync"] + RemoteTransferPlan.workspaceRsyncArgs(
                localWorkspaceDir: localWorkspaceURL.path, project: project.name,
                layout: layout, sshTarget: host.sshTarget)
            let status = try runInherited(args)
            guard status == 0 else {
                throw RemoteDispatchError.remoteSetupFailed("workspace rsync exited with status \(status)")
            }
            return layout.workspaceDir(project.name)
        }
    }

    // MARK: - 4. 実行(行単位で中継)

    /// timeoutSeconds が nil(見積り不能。RemoteTimeout.seconds 参照)のときだけ知らせる ——
    /// 30分の下限で気づかず打ち切られていた欠陥2の裏返しで、今度は「本当に無期限で待つ」ことを
    /// 黙らせない(欠陥1の skipBuild ignoredWithNote と同じ規律)
    private func announceTimeout(_ timeoutSeconds: Int?) {
        guard timeoutSeconds == nil else { return }
        log("note: no automatic timeout (the scenario count is not known ahead of the run) —"
            + " waiting indefinitely; pass --remote-timeout to cap it")
    }

    /// ssh の stdout を StreamLineSplitter で行に割り、リモート絶対パスをローカルパスへ
    /// 書き換えて即 stdout へ中継する(cliRun/apiRun 共通。apiRun は中継行=NDJSON そのものなので
    /// 常に本物の stdout へ出す。進行メッセージは log() 経由で別に stderr へ逃がす)
    private func runRemoteAndRelay(ftesterArgs: [String], layout: RemoteLayout,
                                   timeoutSeconds: Int?) throws -> Int32 {
        log("==> running on \(host.sshTarget): ftester \(ftesterArgs.joined(separator: " "))")
        let command = RemoteShell.remoteRunCommand(layout: layout, ftesterArgs: ftesterArgs)
        let status = try runInheritedWithLineRewrite(
            sshRunBase + [host.sshTarget, command], layout: layout, timeoutSeconds: timeoutSeconds)
        if status == 90 {
            log("==> the remote ftester binary is missing — build it on the remote first"
                + " (swift build --product ftester)")
        }
        return status
    }

    // MARK: - 5. 成果物回収

    /// 回収の失敗は run 全体の成否を変えない(実行結果は既に確定している。
    /// writeJUnitIfRequested と同じ規律)。ディスパッチ単位の reportDir だけを引く
    /// (--delete は付けない = リモートの reports/ 丸ごとは触らない。同じマシンで走る
    /// ローカル実行のレポート・録画と混ざらない)
    private func collectReports(project: TestProject, remoteReportDir: String) {
        log("==> collecting reports")
        let localReports = project.reportsDir
        try? FileManager.default.createDirectory(at: localReports, withIntermediateDirectories: true)
        let remoteReports = "\(host.sshTarget):\(remoteReportDir)/"
        collectRsync(["rsync", "-az", remoteReports, localReports.path + "/"],
                     what: "reports",
                     missingNote: "note: the remote produced no reports (the run failed before writing any)")
    }

    /// .onDemand: results(録画・run ログ)はリモートに残す(場所だけ知らせる)。.collect: rsync で
    /// 回収する。失敗は warn のみ(run の成否は変えない。collectReports と同じ規律)
    private func collectArtifactsIfRequested(project: TestProject, layout: RemoteLayout) {
        guard artifacts == .collect else {
            log("note: recordings and run logs stay on \(host.sshTarget) "
                + "(\(layout.projectDir(project.name))/results) — set remote artifacts to \"collect\" to pull them")
            return
        }
        log("==> collecting recordings and run logs")
        let localResults = project.rootURL.appendingPathComponent("results")
        try? FileManager.default.createDirectory(at: localResults, withIntermediateDirectories: true)
        let args = ["rsync"] + RemoteArtifactCollection.resultsRsyncArgs(
            project: project.name, layout: layout, sshTarget: host.sshTarget,
            localProjectsDir: project.rootURL.deletingLastPathComponent().path)
        collectRsync(args, what: "recordings and run logs",
                     missingNote: "note: the remote produced no recordings or run logs")
    }

    /// 回収した results の `reportPath` を、回収先(ローカルの `TestProjects/<project>/reports/`)へ
    /// 向け直す。リモートは**ディスパッチ単位の隔離先**を記録しており、そこは回収後に消えるので、
    /// 直さないと**リモート実行の結果だけ results からレポートへ飛べない**(規則は
    /// `RemoteReportLink`)。走査は当月と前月の run ディレクトリに限り、**この stamp を含む
    /// 記録だけ**書き換える(他の run に触らない)。失敗は warn のみ(run の成否は変えない)
    private func relinkCollectedReports(project: TestProject, stamp: String) {
        let fm = FileManager.default
        let runsDir = project.rootURL.appendingPathComponent("results/runs")
        let months = ((try? fm.contentsOfDirectory(atPath: runsDir.path)) ?? []).sorted().suffix(2)
        let reportsFromRepoRoot = "\(RemoteLayout.projectsDirName)/\(project.name)/reports"
        var relinked = 0
        for month in months {
            let monthDir = runsDir.appendingPathComponent(month)
            for runID in (try? fm.contentsOfDirectory(atPath: monthDir.path)) ?? [] {
                let scenariosDir = monthDir.appendingPathComponent("\(runID)/scenarios")
                for file in (try? fm.contentsOfDirectory(atPath: scenariosDir.path)) ?? [] {
                    let url = scenariosDir.appendingPathComponent(file)
                    guard var text = try? String(contentsOf: url, encoding: .utf8),
                          text.contains(stamp) else { continue }
                    guard let recorded = Self.recordedReportPath(in: text),
                          let rewritten = RemoteReportLink.rewrittenReportPath(
                            recorded: recorded, stamp: stamp,
                            projectReportsPathFromRepoRoot: reportsFromRepoRoot) else { continue }
                    text = text.replacingOccurrences(of: recorded, with: rewritten)
                    if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { relinked += 1 }
                }
            }
        }
        if relinked > 0 { log("==> relinked \(relinked) report path(s) to the collected copies") }
    }

    /// scenario JSON の `"reportPath": "…"` の値だけを取り出す(JSON を再エンコードすると
    /// 鍵の順序や表現が変わり、他のツールが読む記録を無用に書き換えるため文字列置換にする)
    private static func recordedReportPath(in json: String) -> String? {
        guard let keyRange = json.range(of: "\"reportPath\"") else { return nil }
        let rest = json[keyRange.upperBound...]
        guard let open = rest.range(of: "\""), let close = rest[open.upperBound...].range(of: "\"") else {
            return nil
        }
        return String(rest[open.upperBound..<close.lowerBound])
    }

    /// 回収の rsync。**転送元不在(= run が成果物を作る前に落ちた)は警告にしない** ——
    /// 本当の失敗理由の下にノイズを積まないため(RemoteArtifactCollection.isMissingSourceFailure)。
    /// stderr を見る必要があるので継承ではなく捕捉する(回収は少量で進行表示が要らない)
    private func collectRsync(_ args: [String], what: String, missingNote: String) {
        guard let result = try? Shell.run(args) else {
            log("warning: failed to collect \(what) from the remote (could not run rsync)")
            return
        }
        guard result.status != 0 else { return }
        if RemoteArtifactCollection.isMissingSourceFailure(status: result.status, stderr: result.tail) {
            log(missingNote)
            return
        }
        log("warning: failed to collect \(what) from the remote (rsync exited with \(result.status))\n\(result.tail)")
    }

    private func collectJUnit(remotePath: String, localPath: String, layout: RemoteLayout) {
        guard let xml = try? sshCapture("cat \(RemoteShell.quote(remotePath))"), !xml.isEmpty else {
            log("warning: failed to collect the remote JUnit report (\(remotePath))")
            return
        }
        let rewritten = RemotePathRewrite.rewrite(xml, remoteRoot: layout.base, localRoot: localRepoRoot.path)
        let url = URL(fileURLWithPath: localPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
            log("📄 JUnit report: \(localPath)")
        } catch {
            log("warning: failed to write the JUnit report: \(localPath) (\(error.localizedDescription))")
        }
    }

    /// ディスパッチ単位ディレクトリ(reports/junit の親)をリモートから削除する。
    /// 失敗は run の成否を変えない(warn のみ。同じ規律を上の回収群と共有)
    private func cleanupDispatchDir(layout: RemoteLayout, stamp: String) {
        let dispatchDir = layout.workDir + "/.ftester/dispatch/\(stamp)"
        do {
            _ = try sshCapture("rm -rf \(RemoteShell.quote(dispatchDir))")
        } catch {
            log("warning: failed to remove the remote dispatch directory: \(dispatchDir)")
        }
    }

    /// 進行メッセージの出し分け(cliRun=stdout / apiRun=stderr)。apiRun の stdout は
    /// runRemoteAndRelay が中継する NDJSON 専用のため、人間向け行を混ぜると拡張側の
    /// 行パースが壊れる
    private func log(_ message: String) {
        switch mode {
        case .cliRun:
            // **stdout が端末でないときは行バッファが効かず、進行が最後まで出ない**。
            // ディスパッチは分単位で無音になり得るので(リモートのビルド)、CI やエージェントが
            // ログへリダイレクトすると「止まったのか進んでいるのか」を判断できない。
            // FileHandle は libc のバッファを通さないのでそのまま届く
            FileHandle.standardOutput.write(Data((message + "\n").utf8))
        case .apiRun:
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }

    // MARK: - process helpers

    private func localCapture(_ args: [String]) -> String? {
        guard let result = try? Shell.run(args), result.status == 0 else { return nil }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    /// 全 ssh 共通の基底引数。ConnectTimeout が無いと到達不能ホストで TCP 既定(75秒超)固まる
    private var sshBase: [String] { ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"] }

    /// リモート実行専用(§16.1): `-tt` で疑似 TTY を強制割り当てると、ローカル ssh が
    /// SIGTERM/SIGKILL で落ちたとき SIGHUP がリモートのプロセスグループへ伝わり、キャンセルが
    /// 伝播する。照会系(sshBase)には付けない — TTY 化で stdout に CR が混ざり
    /// git rev-parse 等のキャプチャ結果を汚す
    private var sshRunBase: [String] { sshBase + ["-tt"] }

    private func sshCapture(_ command: String) throws -> String {
        let result = try Shell.run(sshBase + [host.sshTarget, command])
        guard result.status == 0 else {
            throw RemoteDispatchError.remoteSetupFailed(
                "ssh command failed (status \(result.status)): \(command)\n\(result.tail)")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// stdout/stderr を継承して起動する(バッファせずそのまま端末へ流す。rsync 転送は
    /// 進行を人間が見る対話用途のため両モード共通でそのまま継承する — 既定の rsyncArgs
    /// (-az --delete のみ)は成功時 stdout に何も出さないため apiRun の NDJSON 契約を汚さない)
    @discardableResult
    private func runInherited(_ argv: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        let waitForExit = ProcessExitWait.prepareBlocking(process)
        try process.run()
        waitForExit()
        return process.terminationStatus
    }

    /// ssh の stdout を Pipe で受け行単位に組み立て直し、各行を RemotePathRewrite にかけて
    /// print(stdout) する。stderr は継承のまま。パイプ 64KB 飽和で子がブロックする罠を避けるため
    /// 読み取りは別スレッドで行う。期限超過時は SIGTERM→2秒猶予→SIGKILL(Shell.runRaw の
    /// timeout 経路と同じ規律)。stdin は /dev/null に固定する(`-tt` は TTY として stdin を
    /// 要求するが、ディスパッチは対話しない)。**timeoutSeconds nil = 無期限**
    /// (`.distantFuture` を渡す。欠陥2: RemoteTimeout.seconds がシナリオ数不明を表す nil)
    private func runInheritedWithLineRewrite(_ argv: [String], layout: RemoteLayout,
                                             timeoutSeconds: Int?) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        let waitExit = ProcessExitWait.prepareTimed(process)  // 契約: run() より前に設定
        let readHandle = stdoutPipe.fileHandleForReading
        let readDone = DispatchSemaphore(value: 0)
        let splitter = StreamLineSplitter()
        let remoteRoot = layout.base
        let localRoot = localRepoRoot.path
        let mode = self.mode
        func relayLine(_ line: String) {
            let rewritten = RemotePathRewrite.rewrite(line, remoteRoot: remoteRoot, localRoot: localRoot)
            // `-tt`(擬似 TTY)はリモートの stderr を stdout に合流させる。apiRun の stdout は
            // NDJSON 専用の契約なので、機械可読行だけを stdout へ流し、リモートの人間向け診断は
            // stderr へ振り分け直す(2026-07-31 の localhost E2E で混入を実測)
            if mode == .apiRun, !RemoteRelay.isMachineReadableLine(rewritten) {
                FileHandle.standardError.write(Data((rewritten + "\n").utf8))
                return
            }
            print(rewritten)
        }
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = readHandle.readData(ofLength: 65536)
                if chunk.isEmpty { break }   // 子の終了/kill による書込端クローズで EOF
                for line in splitter.feed(chunk) { relayLine(line) }
            }
            readDone.signal()
        }
        let deadline = timeoutSeconds.map { DispatchTime.now() + .seconds($0) } ?? .distantFuture
        if waitExit(deadline) == .timedOut {
            process.terminate()                        // SIGTERM; -tt が SIGHUP をリモートへ伝える(§16.1)
            if waitExit(.now() + 2.0) == .timedOut {   // 猶予後も生存していれば強制終了
                kill(process.processIdentifier, SIGKILL)
                _ = waitExit(.distantFuture)            // reap(terminationHandler 発火)を待つ
            }
            readDone.wait()
            if let remaining = splitter.flush() { relayLine(remaining) }
            throw RemoteDispatchError.remoteSetupFailed(
                "remote run timed out after \(timeoutSeconds ?? 0)s (the remote process was signalled;"
                + " run `ftester remote clean <host>` if devices remain busy)")
        }
        readDone.wait()
        if let remaining = splitter.flush() { relayLine(remaining) }
        return process.terminationStatus
    }
}
