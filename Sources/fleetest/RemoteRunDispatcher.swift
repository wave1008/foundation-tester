// RemoteRunDispatcher.swift
// `fleetest run --host` のプロセス起動(ssh/rsync)を集約する。純粋ロジックは
// Sources/FTCore/RemoteDispatch.swift 側(単体テスト対象)。同一ホストへの二重ディスパッチ防止
// (dispatch.lock の取得・解放。docs/remote-runner.md §5)もここで行う。純粋ロジックは
// Sources/FTCore/RemoteDispatchLock.swift 側。

import FTCore
import Foundation

/// cliRun = `fleetest run --host`(人間向け進行・出力とも stdout)。apiRun = `fleetest api run
/// --host`(NDJSON 中継のため進行メッセージは stderr へ逃がす。stdout は中継行専用)
enum RemoteDispatchMode {
    case cliRun
    case apiRun
}

struct RemoteRunDispatcher {
    let host: RemoteHostSpec
    /// `--remote-dir` の生値(既定 "~/fleetest-runner"。チルダ展開前)。resolveLayout が
    /// リモートの $HOME を取得してから RemoteLayout.resolveBase で絶対パスへ解決する
    let remoteDirRaw: String
    let localRepoRoot: URL
    // var: default 付き let は memberwise init から除外され .apiRun を注入できない
    var mode: RemoteDispatchMode = .cliRun
    var artifacts: RemoteArtifactsMode = .collect
    /// `--force-lock`: 既存の dispatch.lock を奪ってから取得する(docs/remote-runner.md §5)。
    /// 既定では奪わない(stuck なロックを機械的に stale 判定しない)
    var forceLock: Bool = false
    /// `--wait-lock <秒>`: 取得できない間、解放をポーリングして待つ(forceLock と併用不可 ——
    /// FTCore.RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock が入口で弾く)
    var waitLock: Int? = nil
    /// `--host` の生値(登録簿名 or 生 ssh 宛先)。RemoteHostFactsStore の鍵として使う
    /// (FleetSplit の機械別見積りの供給源。docs/remote-runner.md §13)。nil のまま渡された
    /// 構築箇所(facts を書く必要のない経路)では facts の保存をスキップする
    var hostLabel: String? = nil

    /// 戻り値 = リモート `fleetest run` の exit code
    func dispatch(project: TestProject, profile: String,
                  scenarios: [String], folders: [String],
                  deviceNames: [String] = [], deviceMachine: String? = nil,
                  heal: Bool, noHeal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                  fastInput: Bool, enableAnimations: Bool, performanceMode: Bool,
                  broadcast: Bool = false,
                  localJUnitPath: String?,
                  remoteTimeoutSeconds: Int?, runGroup: String? = nil) async throws -> Int32 {
        let setupStart = Date()
        let (layout, session) = try resolveLayout()
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
            ? "\(layout.workDir)/.fleetest/dispatch/\(stamp)/junit.xml" : nil
        let fleetestArgs = RemoteRunArgs.build(
            project: project.name, profile: profile, scenarios: scenarios, folders: folders,
            deviceNames: deviceNames, deviceMachine: deviceMachine,
            heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            fastInput: fastInput, enableAnimations: enableAnimations,
            performanceMode: performanceMode, broadcast: broadcast,
            remoteJUnitPath: remoteJUnitPath, reportDir: remoteReportDir, workspace: remoteWorkspace,
            runGroup: runGroup)
        let timeoutSeconds = RemoteTimeout.seconds(
            explicit: remoteTimeoutSeconds, scenarioCount: scenarios.count)
        announceTimeout(timeoutSeconds)
        let overheadSeconds = Date().timeIntervalSince(setupStart)
        let exitCode = try runRemoteAndRelay(
            fleetestArgs: fleetestArgs, layout: layout, timeoutSeconds: timeoutSeconds)

        collectReports(project: project, remoteReportDir: remoteReportDir)
        if let localJUnitPath, let remoteJUnitPath {
            collectJUnit(remotePath: remoteJUnitPath, localPath: localJUnitPath, layout: layout)
        }
        collectArtifactsIfRequested(project: project, layout: layout)
        // relink より先に撃つ(relink が reportPath を書き換えると stamp がファイルから消え、
        // stamp 走査で machine を採れなくなる。2026-08-18 に実ディスパッチで machine 欠落を確認)
        saveHostFacts(project: project, stamp: stamp, overheadSeconds: overheadSeconds, session: session)
        relinkCollectedReports(project: project, stamp: stamp)
        cleanupDispatchDir(layout: layout, stamp: stamp)

        log("==> remote run finished (exit \(exitCode))")
        return exitCode
    }

    /// `fleetest api run --host`: dispatch と同じ流れ(レイアウト解決→適合チェック→転送→実行→回収)
    /// だが JUnit は扱わない(拡張連携は NDJSON 中継のみで完結する)。戻り値 = リモート
    /// `fleetest api run` の exit code
    func dispatchApi(project: TestProject, profile: String, scenarios: [String],
                     deviceNames: [String] = [], deviceMachine: String? = nil,
                     heal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
                     performanceMode: Bool,
                     defaultTimeout: Double?, scenarioTimeout: Double?,
                     remoteTimeoutSeconds: Int?, runGroup: String? = nil) async throws -> Int32 {
        let setupStart = Date()
        let (layout, session) = try resolveLayout()
        try checkCompatibility(layout: layout)

        try acquireDispatchLock(layout: layout)
        defer { releaseDispatchLock(layout: layout) }

        // 順序の理由は dispatch() のコメント参照(prepareWorkspace は transfer() より先)
        let remoteWorkspace = try prepareWorkspace(project: project, profile: profile, layout: layout)
        try transfer(project: project, layout: layout)

        let stamp = Self.makeStamp()
        let remoteReportDir = layout.dispatchReportDir(stamp: stamp)
        let fleetestArgs = RemoteRunArgs.buildApi(
            project: project.name, profile: profile, scenarios: scenarios,
            deviceNames: deviceNames, deviceMachine: deviceMachine,
            heal: heal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            performanceMode: performanceMode,
            defaultTimeout: defaultTimeout, scenarioTimeout: scenarioTimeout, reportDir: remoteReportDir,
            workspace: remoteWorkspace, runGroup: runGroup)
        let timeoutSeconds = RemoteTimeout.seconds(
            explicit: remoteTimeoutSeconds, scenarioCount: scenarios.count)
        announceTimeout(timeoutSeconds)
        let overheadSeconds = Date().timeIntervalSince(setupStart)
        let exitCode = try runRemoteAndRelay(
            fleetestArgs: fleetestArgs, layout: layout, timeoutSeconds: timeoutSeconds)

        collectReports(project: project, remoteReportDir: remoteReportDir)
        collectArtifactsIfRequested(project: project, layout: layout)
        // relink より先に撃つ(relink が reportPath を書き換えると stamp がファイルから消え、
        // stamp 走査で machine を採れなくなる。2026-08-18 に実ディスパッチで machine 欠落を確認)
        saveHostFacts(project: project, stamp: stamp, overheadSeconds: overheadSeconds, session: session)
        relinkCollectedReports(project: project, stamp: stamp)
        cleanupDispatchDir(layout: layout, stamp: stamp)

        log("==> remote run finished (exit \(exitCode))")
        return exitCode
    }

    // MARK: - 0. レイアウト解決

    /// remoteDirRaw を絶対パスへ解決する。到達性プローブ兼用の1往復
    /// (`echo $HOME; stat -f%Su /dev/console; id -un; sysctl -n machdep.cpu.brand_string 2>/dev/null;
    /// sysctl -n hw.ncpu 2>/dev/null`)に相乗りさせて、コンソールユーザー(§16.3)と CPU 情報
    /// (RemoteHostFacts の processorModel/coreCount。§8 の事前係数)を同時に取る —— 別の ssh を
    /// 足すと往復が増える。戻り値の session は 3行形(古い macOS 等・parseSessionInfo が判定不能で
    /// ログインチェックだけスキップした経路)では nil になり、saveHostFacts は既存値を保持する
    private func resolveLayout() throws -> (layout: RemoteLayout, session: RemoteSessionInfo?) {
        log("==> checking compatibility with \(host.sshTarget)")
        let result = try Shell.run(
            sshBase + [host.sshTarget, "echo $HOME; stat -f%Su /dev/console; id -un; "
                + "sysctl -n machdep.cpu.brand_string 2>/dev/null; sysctl -n hw.ncpu 2>/dev/null"])
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
            return (RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: firstLine),
                                 issuer: try resolveLayoutIssuer()), nil)
        }
        guard session.isLoggedIn else {
            throw RemoteDispatchError.remoteSetupFailed(
                "\(host.sshTarget) is sitting at the login window (console user: \(session.consoleUser), "
                + "expected: \(session.sshUser)) — unlock and log in on the runner, then retry"
                + " (docs/remote-runner.md §5)")
        }
        return (RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: session.home),
                             issuer: try resolveLayoutIssuer()), session)
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
           !revisionIsPublished(repoRoot: localRepoRoot, revision: localRevision) {
            reasons.append(RemoteSetupPlan.unpublishedRevisionMessage(revision: localRevision))
        } else if reasons.contains(where: { $0.hasPrefix("git revision") }),
                  let localRevision, let remoteRevision {
            // published のときだけ向きの案内を出す(未 push なら上の unpublishedRevisionMessage だけ ——
            // このケースで align を案内すると誤誘導になる)
            let relation = revisionRelation(
                repoRoot: localRepoRoot, localRevision: localRevision, remoteRevision: remoteRevision)
            reasons.append(RemoteCompat.relationAdvice(relation))
        }
        guard reasons.isEmpty else { throw RemoteDispatchError.incompatible(reasons) }

        // ワークスペースの実在は転送より前に確かめる(§18.6)。remoteRunCommand の 91 ガードに
        // 任せると、その前の rsync が users/<issuer>/work/TestProjects/… を部分的に作ってしまい、
        // 後から remote setup してもプロジェクト作成がディレクトリ存在でスキップされて壊れる
        // (§12 の既知の罠と同型。2026-08-18 に実ディスパッチで確認)
        let workspaceProbe = try sshCapture(
            "test -f \(RemoteShell.quote(layout.workDir))/Package.swift && echo yes || echo no")
        guard workspaceProbe.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" else {
            throw RemoteDispatchError.remoteSetupFailed(
                "no runner workspace at \(layout.workDir) on \(host.sshTarget)"
                + " — run `fleetest remote setup \(host.sshTarget)` once for this issuer"
                + " (docs/remote-runner.md §18)")
        }
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
            issuerHost: ProcessInfo.processInfo.hostName, pid: ProcessInfo.processInfo.processIdentifier,
            issuer: LocalConfig.resolveIssuerId())
        if forceLock {
            log("warning: --force-lock is stealing the dispatch lock on \(host.sshTarget)"
                + " (any dispatch it was protecting may still be running)")
            _ = try sshCapture(RemoteDispatchLock.forceAcquireCommand(base: layout.base, info: info))
            return
        }
        if let waitLock {
            try acquireDispatchLockWithWait(layout: layout, info: info, limitSeconds: waitLock)
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

    /// `--wait-lock`: 取得できない間、解放をポーリングして待つ(奪わない。時刻での自動奪取は無い)。
    /// ssh 到達不能(255)は待たずに即 throw ―― 待って直る種類の失敗ではない。同じ `info`
    /// (acquiredAt はこのディスパッチが待ち始めた時刻)を毎回の再試行で使い回す
    private func acquireDispatchLockWithWait(
        layout: RemoteLayout, info: RemoteDispatchLockInfo, limitSeconds: Int
    ) throws {
        var elapsed = 0
        while true {
            let result = try Shell.run(sshBase + [host.sshTarget, RemoteDispatchLock.acquireCommand(
                base: layout.base, info: info)])
            if result.status == 0 { return }
            guard result.status != 255 else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "cannot reach \(host.sshTarget) over ssh (status 255)\n\(result.tail)")
            }
            let existing = try? sshCapture(RemoteDispatchLock.readCommand(base: layout.base))
            let existingInfo = existing.flatMap(RemoteDispatchLock.decode)
            if elapsed == 0 {
                log("==> dispatch lock on \(host.sshTarget) is \(RemoteDispatchLock.holderSummary(existingInfo))"
                    + " — waiting up to \(limitSeconds)s")
            }
            guard WaitLockPolling.decide(elapsedSeconds: elapsed, limitSeconds: limitSeconds) == .retry else {
                throw RemoteDispatchError.remoteSetupFailed(
                    RemoteDispatchLock.heldMessage(existingInfo) + " (waited \(elapsed)s)")
            }
            Thread.sleep(forTimeInterval: Double(WaitLockPolling.pollIntervalSeconds))
            elapsed += WaitLockPolling.pollIntervalSeconds
            if elapsed > 0, WaitLockPolling.shouldLogProgress(elapsedSeconds: elapsed) {
                log("==> still waiting on \(host.sshTarget)'s dispatch lock (\(elapsed)s of \(limitSeconds)s)")
            }
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
        let localProjectsDir = project.rootURL.deletingLastPathComponent().path
        let ignore = RemoteTransferPlan.projectIgnore(project: project.name, localProjectsDir: localProjectsDir)
        logTransferIgnore(ignore)
        let args = ["rsync"] + RemoteTransferPlan.rsyncArgs(
            project: project.name, localProjectsDir: localProjectsDir,
            layout: layout, sshTarget: host.sshTarget, ignore: ignore)
        let status = try runInherited(args)
        guard status == 0 else {
            throw RemoteDispatchError.remoteSetupFailed("rsync exited with status \(status)")
        }
        // **ローカルエイリアスをランナーへ残さない**(FTCore.RunnerProfileView)。転送した
        // profiles/ を「そのランナーから見た姿」へ差し替える —— 向こうの台は "local" になり、
        // 他機の台は消える。子へ渡す --device-machine も local になる(RemoteRunArgs)
        // hostLabel が無い構築箇所(旧経路)では畳めない —— 畳む鍵はプロファイルが書く
        // エイリアスそのものなので、生の ssh 宛先しか無いときは差し替えず従来どおり送る
        if let hostLabel, let failure = RunnerProfileTransfer.localizeAndUpload(
            localProjectDir: project.rootURL, project: project.name, alias: hostLabel,
            layout: layout, sshTarget: host.sshTarget) {
            throw RemoteDispatchError.remoteSetupFailed(failure)
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
        for (key, source) in ProfileResolver.declaredAppPaths(project: project, runName: profile)
            .sorted(by: { ($0.key.platform, $0.key.physical ? 1 : 0)
                          < ($1.key.platform, $1.key.physical ? 1 : 0) }) {
            let dest = WorkspaceAppStaging.installPath(source: source,
                                                       workspaceRoot: localWorkspaceURL,
                                                       physical: key.physical)
            if try WorkspaceAppStaging.stageApp(source: source, dest: dest) {
                log("==> staged \(key.platform)\(key.physical ? " physical-device" : "")"
                    + " app package into the workspace")
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
            let ignore = RemoteTransferPlan.workspaceIgnore(localWorkspaceDir: localWorkspaceURL.path)
            logTransferIgnore(ignore)
            let args = ["rsync"] + RemoteTransferPlan.workspaceRsyncArgs(
                localWorkspaceDir: localWorkspaceURL.path, project: project.name,
                layout: layout, sshTarget: host.sshTarget, ignore: ignore)
            let status = try runInherited(args)
            guard status == 0 else {
                throw RemoteDispatchError.remoteSetupFailed("workspace rsync exited with status \(status)")
            }
            return layout.workspaceDir(project.name)
        }
    }

    /// 除外が効いているかを受け手が転送ログで確かめられるようにする(宣言があるときだけ1行。
    /// 黙って効くと「ランナーの台帳がまだ上書きされる」ときに宣言が読まれたのか分からない)
    private func logTransferIgnore(_ ignore: TransferIgnore.Scan) {
        guard !ignore.files.isEmpty else { return }
        log("==> \(TransferIgnore.fileName): \(ignore.excludePatterns.count) exclude pattern(s)"
            + " from \(ignore.files.joined(separator: ", ")) (kept out of the transfer and of --delete)")
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
    private func runRemoteAndRelay(fleetestArgs: [String], layout: RemoteLayout,
                                   timeoutSeconds: Int?) throws -> Int32 {
        log("==> running on \(host.sshTarget): fleetest \(fleetestArgs.joined(separator: " "))")
        let command = RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: fleetestArgs,
                                                   issuer: LocalConfig.resolveIssuerId())
        let status = try runInheritedWithLineRewrite(
            sshRunBase + [host.sshTarget, command], layout: layout, timeoutSeconds: timeoutSeconds)
        if status == 90 {
            log("==> the remote fleetest binary is missing — build it on the remote first"
                + " (swift build --product fleetest)")
        } else if status == 91 {
            log("==> this issuer has no runner workspace on \(host.sshTarget) yet"
                + " — run `fleetest remote setup \(host.sshTarget)` once for this issuer (docs/remote-runner.md §18)")
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

    /// .onDemand でも実績 JSON(run.json/scenarios/*.json/host-metrics.ndjson)は常に回収する ——
    /// 回収しないと LPT がリモートで走ったシナリオを永久に「実績なし」として扱う。重いのは
    /// 録画だけなので、それだけリモートに残す。.collect: 録画も含め results/ を丸ごと回収する。
    /// 失敗は warn のみ(run の成否は変えない。collectReports と同じ規律)
    private func collectArtifactsIfRequested(project: TestProject, layout: RemoteLayout) {
        let localResults = project.rootURL.appendingPathComponent("results")
        try? FileManager.default.createDirectory(at: localResults, withIntermediateDirectories: true)
        let localProjectsDir = project.rootURL.deletingLastPathComponent().path

        guard artifacts == .collect else {
            log("==> collecting run records")
            let args = ["rsync"] + RemoteArtifactCollection.recordsOnlyRsyncArgs(
                project: project.name, layout: layout, sshTarget: host.sshTarget,
                localProjectsDir: localProjectsDir)
            collectRsync(args, what: "run records",
                         missingNote: "note: the remote produced no run records (the run failed before writing any)")
            log("note: recordings stay on \(host.sshTarget) "
                + "(\(layout.projectDir(project.name))/results) — set remote artifacts to \"collect\" to pull them")
            return
        }
        log("==> collecting recordings and run logs")
        let args = ["rsync"] + RemoteArtifactCollection.resultsRsyncArgs(
            project: project.name, layout: layout, sshTarget: host.sshTarget,
            localProjectsDir: localProjectsDir)
        collectRsync(args, what: "recordings and run logs",
                     missingNote: "note: the remote produced no recordings or run logs")
    }

    /// 回収した results の `reportPath` を、回収先(ローカルの `TestProjects/<project>/reports/`)へ
    /// 向け直す。リモートは**ディスパッチ単位の隔離先**を記録しており、そこは回収後に消えるので、
    /// 直さないと**リモート実行の結果だけ results からレポートへ飛べない**(規則は
    /// `RemoteReportLink`)。走査は当月と前月の run ディレクトリに限り、**この stamp を含む
    /// 記録だけ**書き換える(他の run に触らない)。失敗は warn のみ(run の成否は変えない)
    private func relinkCollectedReports(project: TestProject, stamp: String) {
        let reportsFromRepoRoot = "\(RemoteLayout.projectsDirName)/\(project.name)/reports"
        var relinked = 0
        for (url, text) in collectedScenarioTexts(project: project, stamp: stamp) {
            guard let recorded = Self.recordedField(in: text, key: "reportPath"),
                  let rewritten = RemoteReportLink.rewrittenReportPath(
                    recorded: recorded, stamp: stamp,
                    projectReportsPathFromRepoRoot: reportsFromRepoRoot) else { continue }
            let rewrittenText = text.replacingOccurrences(of: recorded, with: rewritten)
            if (try? rewrittenText.write(to: url, atomically: true, encoding: .utf8)) != nil { relinked += 1 }
        }
        if relinked > 0 { log("==> relinked \(relinked) report path(s) to the collected copies") }
    }

    /// この stamp を含む今回の回収済み scenario JSON(当月・前月の runs ディレクトリのみ)。
    /// relinkCollectedReports と saveHostFacts が共有する
    private func collectedScenarioTexts(project: TestProject, stamp: String) -> [(url: URL, text: String)] {
        let fm = FileManager.default
        let runsDir = project.rootURL.appendingPathComponent("results/runs")
        let months = ((try? fm.contentsOfDirectory(atPath: runsDir.path)) ?? []).sorted().suffix(2)
        var results: [(URL, String)] = []
        for month in months {
            let monthDir = runsDir.appendingPathComponent(month)
            for runID in (try? fm.contentsOfDirectory(atPath: monthDir.path)) ?? [] {
                let scenariosDir = monthDir.appendingPathComponent("\(runID)/scenarios")
                for file in (try? fm.contentsOfDirectory(atPath: scenariosDir.path)) ?? [] {
                    let url = scenariosDir.appendingPathComponent(file)
                    guard let text = try? String(contentsOf: url, encoding: .utf8),
                          text.contains(stamp) else { continue }
                    results.append((url, text))
                }
            }
        }
        return results
    }

    /// scenario JSON の `"<key>": "…"` の値だけを取り出す(JSON を再エンコードすると
    /// 鍵の順序や表現が変わり、他のツールが読む記録を無用に書き換えるため文字列置換にする)
    private static func recordedField(in json: String, key: String) -> String? {
        guard let keyRange = json.range(of: "\"\(key)\"") else { return nil }
        let rest = json[keyRange.upperBound...]
        guard let open = rest.range(of: "\""), let close = rest[open.upperBound...].range(of: "\"") else {
            return nil
        }
        return String(rest[open.upperBound..<close.lowerBound])
    }

    /// FleetSplit の機械別見積り(ディスパッチ固定費・実績のホスト解決・§8 の事前係数)の供給源として、
    /// このディスパッチが分かったホストの事実をキャッシュする。**鍵は ssh 宛先(ホスト名/IP)**で、
    /// ローカルエイリアスは使わない(RemoteHostFactsStore.fileKey)。host はプローブでなく
    /// 回収済みレコードから採る —— プローブの推測は FT_MACHINE 上書きやホスト名変化とズレるが、
    /// レコードの値は実績照合そのものに使われている正だから。**CPU 情報(processorModel/coreCount)は
    /// これと逆にプローブ由来**(machdep.cpu.brand_string/hw.ncpu はレコードに乗らない)。
    /// いずれも今回採れなかった項目は既存の facts の値を保持する(上書きで消さない)。
    /// concurrentDevices はレコードの "worker" の相異なる値の個数(この stamp のぶんだけ)。
    /// hostLabel が無い構築箇所(旧経路)では何もしない。失敗は黙って握る(advisory キャッシュ。
    /// run の成否・ログを汚さない)
    private func saveHostFacts(project: TestProject, stamp: String, overheadSeconds: Double,
                               session: RemoteSessionInfo?) {
        let dir = RemoteHostFactsStore.dir(project: project)
        let key = host.sshTarget
        let existing = RemoteHostFactsStore.load(dir: dir, host: key)
        let texts = collectedScenarioTexts(project: project, stamp: stamp)
        let recorded = recordedMachine(texts: texts) ?? existing?.host
        let concurrentDevices = recordedConcurrentDevices(texts: texts) ?? existing?.concurrentDevices
        let facts = RemoteHostFacts(
            host: recorded,
            // 表示用のエイリアス(鍵ではない。RemoteHostFacts.machineAlias の宣言参照)
            machineAlias: hostLabel ?? existing?.machineAlias,
            dispatchOverheadSeconds: overheadSeconds,
            processorModel: session?.processorModel ?? existing?.processorModel,
            coreCount: session?.coreCount ?? existing?.coreCount,
            concurrentDevices: concurrentDevices,
            updatedAt: ISO8601DateFormatter().string(from: Date()))
        RemoteHostFactsStore.save(facts, dir: dir, host: key)
    }

    private func recordedMachine(texts: [(url: URL, text: String)]) -> String? {
        for (_, text) in texts {
            // 記録側のキーは "host"(2026-08-26 改名)。旧記録の "machine" も読む
            if let host = Self.recordedField(in: text, key: "host") { return host }
            if let machine = Self.recordedField(in: text, key: "machine") { return machine }
        }
        return nil
    }

    /// この stamp の回収済みレコードに乗っている "worker" の相異なる**デバイス**の個数
    /// (worker label はブリッジのポートを含み回復で変わるので RunWorker.laneKey で台に寄せる。
    /// 0 = 何も取れなかった = 呼び出し側で既存値を保持させる)
    private func recordedConcurrentDevices(texts: [(url: URL, text: String)]) -> Int? {
        var workers = Set<String>()
        for (_, text) in texts {
            if let worker = Self.recordedField(in: text, key: "worker") {
                workers.insert(RunWorker.laneKey(fromLabel: worker))
            }
        }
        return workers.isEmpty ? nil : workers.count
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
        // **写す先は workDir**(base ではない)。base のまま置換すると `users/<issuer>/work` が
        // 残って手元に存在しないパスができる(2026-08-26 の実害。§18.2 の発行者ネームスペースを
        // 足したときに追随し損ねていた)
        let rewritten = RemotePathRewrite.rewrite(
            xml, remoteRoot: layout.workDir, localRoot: localRepoRoot.path)
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
        let dispatchDir = layout.workDir + "/.fleetest/dispatch/\(stamp)"
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
        // 中断はこの ssh へ伝える(親を殺しただけでは子は死なず、リモートが走り続ける。
        // InterruptRelay の宣言)
        let relay = InterruptRelay.forwarding(to: process)
        defer { relay.stop() }
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
        // **写す先は workDir**(base ではない。collectJUnit と同じ理由)
        let remoteRoot = layout.workDir
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
                // availableData = 届いた分だけ返す(readData(ofLength:) は length か EOF まで
                // 貯めるので、NDJSON 中継が ssh の終了時の一括になる。2026-08-18 実測)
                let chunk = readHandle.availableData
                if chunk.isEmpty { break }   // 子の終了/kill による書込端クローズで EOF
                for line in splitter.feed(chunk) { relayLine(line) }
            }
            readDone.signal()
        }
        // 中断をこの ssh へ伝える(runInherited と同じ理由。これが無いと fleetest を kill しても
        // ssh が生き残り、-tt による SIGHUP がリモートへ届かない)
        let relay = InterruptRelay.forwarding(to: process)
        defer { relay.stop() }
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
                + " run `fleetest remote clean <host>` if devices remain busy)")
        }
        readDone.wait()
        if let remaining = splitter.flush() { relayLine(remaining) }
        return process.terminationStatus
    }
}
