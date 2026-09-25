// RemoteRunDispatcher.swift
// `fleetest run --runner` のプロセス起動(ssh/rsync)を集約する。純粋ロジックは
// Sources/FTRemote/RemoteDispatch.swift 側(単体テスト対象)。同一ホストへの二重ディスパッチ防止
// (dispatch.lock の取得・解放。docs/remote-runner.md §5)もここで行う。純粋ロジックは
// Sources/FTRemote/RemoteDispatchLock.swift 側。

import FTAndroid
import FTCore
import FTRemote
import Foundation

/// cliRun = `fleetest run --runner`(人間向け進行・出力とも stdout)。apiRun = `fleetest api run
/// --runner`(NDJSON 中継のため進行メッセージは stderr へ逃がす。stdout は中継行専用)
enum RemoteDispatchMode {
    case cliRun
    case apiRun
}

/// このディスパッチが自分から中断された(SIGINT/SIGTERM を受けて `InterruptRelay` が
/// 実行中の ssh へ SIGTERM を回した)かどうかの印。**参照型が要る** —— `dispatch()`/
/// `dispatchApi()` は struct(`RemoteRunDispatcher`)の非 mutating メソッドで、
/// `InterruptRelay.observing` へ渡すクロージャからは struct 自身を書けない。
/// シグナルハンドラ用スレッドと読み出し側(collectReports 呼び出し)が別スレッドなので lock で守る
private final class DispatchInterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _interrupted = false
    var interrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return _interrupted
    }
    func mark() {
        lock.lock(); defer { lock.unlock() }
        _interrupted = true
    }
}

struct RemoteRunDispatcher {
    /// `sshCapture` の timeout(秒)。ここを通るのは git/mkdir/xcodebuild -version 等の短い
    /// 照会だけで実測は数秒 —— timeout 無しだと向こうが刺さったとき手元の run が永久に待つ。
    /// 尽きたら `ShellError.timedOut` が上がって落ちる(待ち続けるより良い)
    static let sshCaptureTimeoutSeconds: Double = 120

    /// M7: ssh の断・kill(exit 255/137 等 —— 0/1/自分の中断のいずれでもない)のとき、回収へ入る前に
    /// 「ランナー上でこのディスパッチの run がもう終わったか」を待つ上限(秒)。実測
    /// (M1Max へのディスパッチの ssh を SIGKILL してネットワーク断を模した)では、
    /// リモートの後始末(run.json へ interrupted/finishedAt を書く)は 2 秒で終わっていた。
    /// 超えても実害は「手元の記録が途中版のまま回収される = 次のディスパッチの回収で埋まる」
    /// だけなので、待ちすぎない値に留める
    static let remoteRunEndWaitLimitSeconds: Double = 30
    /// 上のポーリング間隔(秒)。実測の後始末(2秒)より十分細かく、ssh を焼きすぎない値
    static let remoteRunEndPollIntervalSeconds: UInt32 = 1

    let host: RemoteHostSpec
    /// `--remote-dir` の生値(既定 "~/fleetest-runner"。チルダ展開前)。resolveLayout が
    /// リモートの $HOME を取得してから RemoteLayout.resolveBase で絶対パスへ解決する
    let remoteDirRaw: String
    let localRepoRoot: URL
    // var: default 付き let は memberwise init から除外され .apiRun を注入できない
    var mode: RemoteDispatchMode = .cliRun
    /// `--force-lock`: 既存の dispatch.lock を奪ってから取得する(docs/remote-runner.md §5)。
    /// 既定では奪わない(stuck なロックを機械的に stale 判定しない)
    var forceLock: Bool = false
    /// `--wait-lock <秒>`: 取得できない間、解放をポーリングして待つ(forceLock と併用不可 ——
    /// FTRemote.RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock が入口で弾く)
    var waitLock: Int? = nil
    /// `--runner` の生値(登録簿名 or 生 ssh 宛先)。RemoteHostFactsStore の鍵として使う
    /// (FleetSplit の機械別見積りの供給源。docs/remote-runner.md §13)。nil のまま渡された
    /// 構築箇所(facts を書く必要のない経路)では facts の保存をスキップする
    var hostLabel: String? = nil

    /// 戻り値 = リモート `fleetest run` の exit code
    func dispatch(project: TestProject, profile: String,
                  scenarios: [String], folders: [String],
                  deviceNames: [String] = [], deviceMachine: String? = nil,
                  setOverrides: [String: RunProfileSetValue] = [:],
                  noLPT: Bool, lptHistoryRuns: Int?,
                  performanceMode: Bool,
                  broadcast: Bool = false,
                  localJUnitPath: String?,
                  remoteTimeoutSeconds: Int?, runGroup: String? = nil) async throws -> Int32 {
        let setupStart = Date()
        let (layout, session) = try resolveLayout()
        cacheHardwareUUID(project: project, session: session)
        let developerDir = try checkCompatibility(layout: layout)

        // **ロック取得の前から観測を張る**(中断があっても、これから登録する
        // `defer { releaseDispatchLock }` を必ず走らせるため)。ここから下は Shell.run 越しの
        // 短い ssh 照会・rsync 転送・回収コマンドが続くが、どれも InterruptRelay に登録された
        // Process ではないので、登録が1つも無いままだと SIGINT は既定動作(即終了)のままで
        // defer が飛ばされ、リモートの dispatch.lock が握られたまま残る
        // (bug-audit-2026-09-06.md §3)。**何もしない observer で構わない** ——
        // 登録そのもの(signal(SIGINT, SIG_IGN))が defer の実行を保証する。実行中の ssh
        // セッションへの中断転送は runInherited/runInheritedWithLineRewrite 自身の Process
        // relay が別途行う(forwardToAll は登録された全ターゲットを呼ぶので共存しても害はない)。
        // **中断そのものは止めない** —— いま動いている ssh 照会/転送は自分の完了/タイムアウト
        // まで動き、そのあと通常どおり関数末尾まで進んで defer が走る。
        // defer は宣言と逆順に走るので、この stop() より先に releaseDispatchLock を宣言する
        // (release の実行中もまだ観測が生きているように)。同じ observer で「自分から中断した」
        // 印も立てる(interruptFlag。collectReports の missingNote が「失敗」と断定しないため)
        let interruptFlag = DispatchInterruptFlag()
        let lockHeldRelay = InterruptRelay.observing { interruptFlag.mark() }
        defer { lockHeldRelay.stop() }
        try acquireDispatchLock(layout: layout, runGroup: runGroup, interruptFlag: interruptFlag)
        var lockReleasedEarly = false
        defer { if !lockReleasedEarly { releaseDispatchLock(layout: layout) } }
        // **取得の直後にもう一度見る**: 待機列で待っている間の中断はループ内(acquireDispatchLock)
        // で捕まえて外に出るが、待たずに一発で取れた場合や、待機列を抜けた直後に中断が来た場合は
        // ロックを持ったまま関数末尾まで来てしまう。ここで拾わないと、既に中断済みなのに
        // このあと prepareWorkspace/transfer/runRemoteAndRelay(= 実際のリモート run を起動する)
        // まで進む — 起動より前なので、まだ何も走っていないこの時点なら無条件に外してよい
        guard !interruptFlag.interrupted else {
            // releaseDispatchLock 自身が「親が持っているロックは外さない」を見て no-op に倒すので、
            // この呼び出しはどちらの経路でも安全
            releaseDispatchLock(layout: layout)
            lockReleasedEarly = true
            throw RemoteDispatchError.remoteSetupFailed(
                "interrupted before dispatching to \(host.sshTarget) — stopping without starting"
                + " a remote run")
        }
        reapOrphanedHooksAcrossIssuers(layout: layout)

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
            setOverrides: setOverrides,
            noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            performanceMode: performanceMode, broadcast: broadcast,
            remoteJUnitPath: remoteJUnitPath, reportDir: remoteReportDir, workspace: remoteWorkspace,
            runGroup: runGroup)
        let timeoutSeconds = RemoteTimeout.seconds(
            explicit: remoteTimeoutSeconds, scenarioCount: scenarios.count)
        announceTimeout(timeoutSeconds)
        let overheadSeconds = Date().timeIntervalSince(setupStart)
        let exitCode: Int32
        do {
            exitCode = try runRemoteAndRelay(
                fleetestArgs: fleetestArgs, layout: layout, timeoutSeconds: timeoutSeconds,
                stamp: stamp, project: project.name, developerDir: developerDir)
        } catch {
            // timeout (throws from runInheritedWithLineRewrite): the remote run may still be
            // alive — the ssh session was just signalled, but the runner's teardown is
            // asynchronous. Release only if it has actually ended (same M7 judgment as the
            // ssh-disconnect path below), never unconditionally
            lockReleasedEarly = releaseLockIfRunEnded(layout: layout, reportDir: remoteReportDir)
            if !lockReleasedEarly {
                log("==> the remote run may still be finishing — keeping the dispatch lock"
                    + " (the next dispatch on \(host.sshTarget) reclaims it once the run has ended)")
            }
            throw error
        }
        lockReleasedEarly = awaitRemoteRunEnd(
            exitCode: exitCode, interrupted: interruptFlag.interrupted, layout: layout,
            reportDir: remoteReportDir)

        collectReports(project: project, remoteReportDir: remoteReportDir,
                      interrupted: interruptFlag.interrupted)
        if let localJUnitPath, let remoteJUnitPath {
            collectJUnit(remotePath: remoteJUnitPath, localPath: localJUnitPath, layout: layout,
                        stamp: stamp, project: project.name)
        }
        let transferredScenarioPaths = collectArtifacts(project: project, layout: layout)
        // 今回の回収で転送された scenario JSON だけを読む。**読んだ結果は1回だけ作り**、
        // saveHostFacts/relinkCollectedReports/writeLastResults の3箇所へ共有する
        // (同じ全件走査(過去2か月分)を毎ディスパッチ2回行うと重い)
        let texts = collectedScenarioTexts(
            project: project, stamp: stamp, transferredScenarioPaths: transferredScenarioPaths)
        // relink より先に撃つ(relink が reportPath を書き換えると stamp がファイルから消え、
        // stamp 走査で machine を採れなくなる。実ディスパッチで machine 欠落を確認)
        saveHostFacts(project: project, overheadSeconds: overheadSeconds, session: session, texts: texts)
        relinkCollectedReports(project: project, stamp: stamp, texts: texts)
        // リモートで走った分の `--failed` 記録を手元へ書く。リモート側の
        // ScenarioHost.run() は手元の LastResultsStore を書けないので、回収した scenario JSON
        // (scenarioID/passed/profile)から直接書く
        writeLastResults(texts: texts, project: project)
        cleanupDispatchDir(layout: layout, stamp: stamp)

        log("==> remote run finished (exit \(exitCode))")
        return exitCode
    }

    /// `fleetest api run --runner`: dispatch と同じ流れ(レイアウト解決→適合チェック→転送→実行→回収)
    /// だが JUnit は扱わない(拡張連携は NDJSON 中継のみで完結する)。戻り値 = リモート
    /// `fleetest api run` の exit code
    func dispatchApi(project: TestProject, profile: String, scenarios: [String],
                     deviceNames: [String] = [], deviceMachine: String? = nil,
                     setOverrides: [String: RunProfileSetValue] = [:], noLPT: Bool, lptHistoryRuns: Int?,
                     performanceMode: Bool,
                     defaultTimeout: Double?, scenarioTimeout: Double?,
                     remoteTimeoutSeconds: Int?, runGroup: String? = nil) async throws -> Int32 {
        let setupStart = Date()
        let (layout, session) = try resolveLayout()
        cacheHardwareUUID(project: project, session: session)
        let developerDir = try checkCompatibility(layout: layout)

        // 中断があっても解放の defer を必ず走らせる(理由・順序は dispatch() のコメント参照)。
        // interruptFlag の理由も dispatch() と同じ
        let interruptFlag = DispatchInterruptFlag()
        let lockHeldRelay = InterruptRelay.observing { interruptFlag.mark() }
        defer { lockHeldRelay.stop() }
        try acquireDispatchLock(layout: layout, runGroup: runGroup, interruptFlag: interruptFlag)
        var lockReleasedEarly = false
        defer { if !lockReleasedEarly { releaseDispatchLock(layout: layout) } }
        // 理由は dispatch() の同じガード参照(取得の直後にもう一度見る)
        guard !interruptFlag.interrupted else {
            releaseDispatchLock(layout: layout)
            lockReleasedEarly = true
            throw RemoteDispatchError.remoteSetupFailed(
                "interrupted before dispatching to \(host.sshTarget) — stopping without starting"
                + " a remote run")
        }
        reapOrphanedHooksAcrossIssuers(layout: layout)

        // 順序の理由は dispatch() のコメント参照(prepareWorkspace は transfer() より先)
        let remoteWorkspace = try prepareWorkspace(project: project, profile: profile, layout: layout)
        try transfer(project: project, layout: layout)

        let stamp = Self.makeStamp()
        let remoteReportDir = layout.dispatchReportDir(stamp: stamp)
        let fleetestArgs = RemoteRunArgs.buildApi(
            project: project.name, profile: profile, scenarios: scenarios,
            deviceNames: deviceNames, deviceMachine: deviceMachine,
            setOverrides: setOverrides, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            performanceMode: performanceMode,
            defaultTimeout: defaultTimeout, scenarioTimeout: scenarioTimeout, reportDir: remoteReportDir,
            workspace: remoteWorkspace, runGroup: runGroup)
        let timeoutSeconds = RemoteTimeout.seconds(
            explicit: remoteTimeoutSeconds, scenarioCount: scenarios.count)
        announceTimeout(timeoutSeconds)
        let overheadSeconds = Date().timeIntervalSince(setupStart)
        let exitCode: Int32
        do {
            exitCode = try runRemoteAndRelay(
                fleetestArgs: fleetestArgs, layout: layout, timeoutSeconds: timeoutSeconds,
                stamp: stamp, project: project.name, developerDir: developerDir)
        } catch {
            // 理由は dispatch() の同じ catch 参照(timeout でも生きていれば外さない)
            lockReleasedEarly = releaseLockIfRunEnded(layout: layout, reportDir: remoteReportDir)
            if !lockReleasedEarly {
                log("==> the remote run may still be finishing — keeping the dispatch lock"
                    + " (the next dispatch on \(host.sshTarget) reclaims it once the run has ended)")
            }
            throw error
        }
        lockReleasedEarly = awaitRemoteRunEnd(
            exitCode: exitCode, interrupted: interruptFlag.interrupted, layout: layout,
            reportDir: remoteReportDir)

        collectReports(project: project, remoteReportDir: remoteReportDir,
                      interrupted: interruptFlag.interrupted)
        let transferredScenarioPaths = collectArtifacts(project: project, layout: layout)
        // 理由は dispatch() と同じ(読むのは今回転送された分だけ・結果は1回だけ作って共有)
        let texts = collectedScenarioTexts(
            project: project, stamp: stamp, transferredScenarioPaths: transferredScenarioPaths)
        // relink より先に撃つ(relink が reportPath を書き換えると stamp がファイルから消え、
        // stamp 走査で machine を採れなくなる。実ディスパッチで machine 欠落を確認)
        saveHostFacts(project: project, overheadSeconds: overheadSeconds, session: session, texts: texts)
        relinkCollectedReports(project: project, stamp: stamp, texts: texts)
        // 理由は dispatch() と同じ
        writeLastResults(texts: texts, project: project)
        cleanupDispatchDir(layout: layout, stamp: stamp)

        log("==> remote run finished (exit \(exitCode))")
        return exitCode
    }

    // MARK: - 0. レイアウト解決

    /// remoteDirRaw を絶対パスへ解決する。到達性プローブ兼用の1往復
    /// (`echo $HOME; <RemoteProbe.consoleUserCommand>; id -un; sysctl -n machdep.cpu.brand_string 2>/dev/null;
    /// sysctl -n hw.ncpu 2>/dev/null; <RemoteProbe.hardwareUUIDCommand>`)に相乗りさせて、
    /// コンソールユーザー(§16.3)と CPU 情報(RemoteHostFacts の processorModel/coreCount。
    /// §8 の事前係数)とハードウェア UUID(同 hardwareUUID)を同時に取る —— 別の ssh を
    /// 足すと往復が増える。戻り値の session は 3行形(古い macOS 等・parseSessionInfo が判定不能で
    /// ログインチェックだけスキップした経路)では nil になり、saveHostFacts は既存値を保持する
    private func resolveLayout() throws -> (layout: RemoteLayout, session: RemoteSessionInfo?) {
        log("==> checking compatibility with \(host.sshTarget)")
        // 期限なしだと刺さった ssh で永久に待つ(sshCapture と同じ 120 秒)
        let result = try Shell.run(
            sshBase + [host.sshTarget, "echo $HOME; \(RemoteProbe.consoleUserCommand); id -un; "
                + "sysctl -n machdep.cpu.brand_string 2>/dev/null; sysctl -n hw.ncpu 2>/dev/null; "
                + RemoteProbe.hardwareUUIDCommand],
            timeout: Self.sshCaptureTimeoutSeconds)
        guard result.status == 0 else {
            throw RemoteDispatchError.remoteSetupFailed(
                "cannot reach \(host.sshTarget) over ssh (status \(result.status))"
                + " — check the host name and keys; BatchMode disables password prompts\n\(result.tail)")
        }
        guard let session = RemoteProbe.parseSessionInfo(result.output) else {
            // 想定外の出力(古い macOS 等): ログイン判定はスキップするが $HOME は必須のまま
            let firstLine = (result.output.split(separator: "\n", maxSplits: 1,
                                                 omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !firstLine.isEmpty else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "could not determine $HOME on \(host.sshTarget)")
            }
            log("warning: could not determine the remote console login state — skipping the login check")
            return (RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: firstLine),
                                 issuer: try resolveLayoutIssuer(), home: firstLine), nil)
        }
        guard session.isLoggedIn else {
            throw RemoteDispatchError.remoteSetupFailed(
                "\(host.sshTarget) is sitting at the login window (console user: \(session.consoleUser), "
                + "expected: \(session.sshUser)) — unlock and log in on the runner, then retry"
                + " (docs/remote-runner.md §5)")
        }
        return (RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: session.home),
                             issuer: try resolveLayoutIssuer(), home: session.home), session)
    }

    /// ディスパッチ単位の一意ディレクトリ名(reports/junit の隔離・回収後の削除に使う)
    private static func makeStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "\(formatter.string(from: Date()))-\(ProcessInfo.processInfo.processIdentifier)"
    }

    // MARK: - 1. 適合チェック

    /// `git status --porcelain`(未フィルタ)の出力から、`TestProjects/` 配下**以外**
    /// (= ツール本体)に変更があるかを判定する。`TestProjects/<project>/` は run のたびに
    /// rsync で運ばれる(§13)ので、そこだけの変更を「リモートへ届かない」と警告するのは誤誘導 ——
    /// 未追跡のプロファイル JSON 等、受け手が日常的に持つ差分で毎回鳴っていた。
    /// **rename 行("R  old -> new")は新パスで判定する**(旧パスがツール本体でも、置き場所が
    /// 最終的に TestProjects 配下なら rsync で届く)。空・空白のみは false
    static func hasUncommittedToolChanges(porcelain: String?) -> Bool {
        guard let porcelain else { return false }
        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            var path = String(rawLine.dropFirst(min(3, rawLine.count)))
            if let arrowRange = path.range(of: " -> ") {
                path = String(path[arrowRange.upperBound...])
            }
            path = path.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                path = String(path.dropFirst().dropLast())
            }
            guard !path.isEmpty else { continue }
            if !path.hasPrefix("TestProjects/") { return true }
        }
        return false
    }

    /// 戻り値 = このディスパッチで使う `DEVELOPER_DIR`(nil = ambient)。**このディスパッチの
    /// toolchain probe と、あとで撃つ run(runRemoteAndRelay → RemoteShell.remoteRunCommand)は
    /// 必ずこの1つの戻り値を使う** —— 別々に解決すると、ここで照合した Xcode と実際に走る Xcode が
    /// 食い違う(緑のまま別の Xcode で走る沈黙の退行)
    private func checkCompatibility(layout: RemoteLayout) throws -> String? {
        let localRevision = localCapture(["git", "-C", localRepoRoot.path, "rev-parse", "HEAD"])
        // TestProjects/<project>/ は run のたびに rsync で届く(§13)ので、そこだけの変更
        // (未追跡のプロファイル JSON 等)で鳴らすのは誤誘導 —— 判定は hasUncommittedToolChanges の1箇所
        let status = localCapture(["git", "-C", localRepoRoot.path, "status", "--porcelain"])
        if Self.hasUncommittedToolChanges(porcelain: status) {
            log("warning: uncommitted changes to the tool itself (outside TestProjects/)"
                + " will NOT reach the remote")
        }

        let revisionProbe = probeRemote("git revision") {
            try sshCapture("git -C \(RemoteShell.quote(layout.toolRoot)) rev-parse HEAD")
        }
        let localToolchain = ToolchainFingerprint.current()

        // Xcode の選択(docs/remote-runner.md §7)。**適合照合(toolchain probe)より前に解決する**
        // —— refused はここで即座に止め、選べた場合はその DEVELOPER_DIR を toolchain probe に
        // 使わせる(ambient のまま照合すると、あとで run が選ぶ Xcode と食い違いうる)
        let xcodeOutcome = resolveXcodeSelection(layout: layout)
        if case .refused(let reason) = xcodeOutcome {
            throw RemoteDispatchError.incompatible([reason])
        }
        let developerDir = xcodeOutcome.developerDir

        let toolchainProbe = probeRemote("toolchain") { try remoteToolchainFingerprint(developerDir: developerDir) }
        let remoteRevision = revisionProbe.capturedValue
        let verdict = RemoteCompat.verdict(
            localRevision: localRevision, remoteRevision: revisionProbe,
            localToolchain: localToolchain, remoteToolchain: toolchainProbe)
        // advisory(toolchain のベータ seed 差)はディスパッチを止めない —— 1行ずつ警告して続行する
        for advisory in verdict.advisory { log("warning: \(advisory)") }
        var reasons = verdict.blocking
        // rev 不一致の**いちばん多い原因は「まだ push していない」**。ランナーは origin から
        // fetch するので、押していないコミットへは remote setup でも合わせられない
        // (そのままだと checkout が exit 128 で落ちるだけ。実際に踏んだ)
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
        // (§12 の既知の罠と同型。実ディスパッチで確認)
        let workspaceProbe = try sshCapture(
            "test -f \(RemoteShell.quote(layout.workDir))/Package.swift && echo yes || echo no")
        guard workspaceProbe.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" else {
            throw RemoteDispatchError.remoteSetupFailed(
                "no runner workspace at \(layout.workDir) on \(host.sshTarget)"
                + " — run `fleetest remote setup \(host.sshTarget)` once for this issuer"
                + " (docs/remote-runner.md §18)")
        }
        return developerDir
    }

    /// **1回だけ**(probeRemote のような引き直しは無い)。失敗は「列挙できなかった」と同じ扱いで
    /// ambient に倒す(空の候補一覧なら XcodeSelection.resolve が .ambient を返す) ——
    /// 見えないだけで運用を止めない(候補が実在するのに一致しないケースだけを refused にする)
    private func resolveXcodeSelection(layout: RemoteLayout) -> XcodeSelection.Outcome {
        let pin = registeredEntry?.developerDir
        let listing = (try? sshCapture(XcodeSelection.listCommand)) ?? ""
        let installed = XcodeSelection.parse(listing)
        return XcodeSelection.resolve(
            localFingerprint: ToolchainFingerprint.current(), installed: installed, pin: pin)
    }

    private func remoteToolchainFingerprint(developerDir: String?) throws -> String {
        let prefix = developerDir.map { "export DEVELOPER_DIR=\(RemoteShell.quote($0)) && " } ?? ""
        let xcodeVersion = try sshCapture("\(prefix)xcodebuild -version")
        let sdkBuild = try sshCapture("\(prefix)xcrun --sdk iphonesimulator --show-sdk-build-version")
        return ToolchainFingerprint.compose(xcodeVersionOutput: xcodeVersion, sdkBuild: sdkBuild)
    }

    // MARK: - 2. 同一ホストへの二重ディスパッチ防止(docs/remote-runner.md §5)

    /// **この宛先の**ロックを親(fan-out)が先に取っているか(`FT_DISPATCH_LOCK_HELD`)。
    /// 印が無ければ自分で取る —— 単発 `run --runner`(親が居ない)はこの縮退で
    /// そのまま動くので、モードの分岐を持たない
    private var parentHoldsThisLock: Bool {
        DispatchLockHandoff.isHeldByParent(
            environment: ProcessInfo.processInfo.environment, sshTarget: host.sshTarget)
    }

    /// **親(fan-out)が子より先にこのホストのロックを取る口**(`DispatchPrelock` が唯一の呼び手)。
    /// 取得は子とまったく同じ `acquireDispatchLock`(待機列 FIFO 経由)を通す ——
    /// 2つ目の取得実装を作らない。ついでに接続で採れたハードウェア UUID を控える
    /// (**順序の鍵**。キャッシュに無い機械はこれより前に `probeHardwareUUIDAsParent` が採る)。
    ///
    /// **info.json に載る pid はこの親の pid** になる —— 親が死んでロックが残った場合の
    /// 自動回収(`autoReleaseOurStaleLock` → `RemoteDispatchUnlock.decideAutomaticSweep`)は
    /// 「自分の発行者・この機械・死んだ pid」で判定するので、**子が取っていたときと同じに効く**。
    ///
    /// **この呼び出し専用の中断観測を張る** —— `dispatch()`/`dispatchApi()` と違い、ここは
    /// `DispatchPrelock` から直接呼ばれるので囲む観測が無い。待機列で待っている間の Ctrl-C を
    /// 待ち続けさせない(1と同じ理由)。`InterruptRelay` は多重登録を許すので、呼び出し元
    /// (`DispatchPrelock`)が自分の中断観測を別に持っていても共存する
    func acquireDispatchLockAsParent(project: TestProject, runGroup: String?) throws -> RemoteLayout {
        let (layout, session) = try resolveLayout()
        cacheHardwareUUID(project: project, session: session)
        let interruptFlag = DispatchInterruptFlag()
        let relay = InterruptRelay.observing { interruptFlag.mark() }
        defer { relay.stop() }
        try acquireDispatchLock(layout: layout, runGroup: runGroup, interruptFlag: interruptFlag)
        return layout
    }

    /// 上で取ったロックを外す(親の defer から。成功・失敗・中断のいずれでも1回)。
    /// **`exitCode` が 0/1(正常終了)なら無条件に外す**。それ以外(timeout・ssh 断・
    /// SIGKILL 等。**不明(nil)も含む** —— 不明を正常と混同しない)は、親はこの子が使った
    /// `reportDir`(ディスパッチ単位の stamp)を知らないので `releaseLockIfRunEnded` は使えない ——
    /// 代わりに `liveDispatchedRunPIDs`(このホストの base 配下に生きているディスパッチが
    /// **どれか**あるか)で確かめてから外す。`autoReleaseOurStaleLock` と同じ生死判定を共有する
    /// (2つ目の判定を作らない)
    func releaseDispatchLockAsParent(layout: RemoteLayout, exitCode: Int32?) {
        guard exitCode == 0 || exitCode == 1 else {
            guard let livePIDs = liveDispatchedRunPIDs(layout: layout), livePIDs.isEmpty else {
                log("==> \(host.sshTarget): keeping the dispatch lock (the sub-run did not exit"
                    + " normally and a dispatched run may still be alive there — the next dispatch"
                    + " reclaims it once it has ended)")
                return
            }
            releaseDispatchLock(layout: layout)
            return
        }
        releaseDispatchLock(layout: layout)
    }

    /// **親が順序を決める前に、ハードウェア UUID だけを先に採る口**(`DispatchPrelock` が唯一の呼び手)。
    /// ロックには触らない —— 順序は取得より前に決まっている必要があるので、この1往復だけが先に走る。
    ///
    /// 採取は接続の1往復(`resolveLayout`)に相乗りし、控えるのも既存の `cacheHardwareUUID` ——
    /// **2つ目の採取実装(ssh コマンドの組み立て・facts への書き込み)を作らない**。
    /// **呼ぶのはキャッシュに無い機械だけ**(呼び手の責任。ここは無条件に1往復する)。
    /// 戻り値 nil = 接続はできたが読めなかった(不明のまま最後尾)
    func probeHardwareUUIDAsParent(project: TestProject) throws -> String? {
        let (_, session) = try resolveLayout()
        return cacheHardwareUUID(project: project, session: session)
    }

    /// フリート内の重複は FleetProfile.validate で防げるが、別フリート・別人・CLI/GUI 併走に
    /// よる同一ホストへの二重実行はここでしか防げない。**単発の `run --runner` でも常に取得する**
    /// (フリート専用の仕組みにしない ―― 競合はフリートかどうかと無関係にホスト単位で起きる)。
    ///
    /// 取得は **FIFO の待機列経由**(`RemoteDispatchQueue`)。1往復で「並ぶ → 失効チケットを掃く →
    /// 先頭なら mkdir でロックを取る」まで行い、`--wait-lock` の撃ち直しがそのままチケットの
    /// ハートビートを兼ねる(別に touch を撃たない)。**中断・クラッシュでチケットが残っても
    /// `RemoteDispatchQueue.staleSeconds`(30秒)で失効する**ので defer で消しに行かない
    /// (中断時に ssh を1本増やさない)。
    ///
    /// **待機ループは毎周 `interruptFlag` を見る**(`LocalDispatchLock.acquire` と同じ挙動へ揃える)。
    /// 見ないと、待機列で順番待ちの間に Ctrl-C を受けても止まらず、順番が来た瞬間にロックを取って
    /// 実際のリモート run(prepareWorkspace 以降)まで進んでしまう
    private func acquireDispatchLock(layout: RemoteLayout, runGroup: String?,
                                     interruptFlag: DispatchInterruptFlag) throws {
        if parentHoldsThisLock {
            // 親(fan-out)が全機械ぶんを順序どおりに取り切ってから起こした子。ここで取りに行くと
            // **自分の親が握っているロックを待って**進まない
            log("==> the dispatch lock on \(host.sshTarget) is already held by this run's parent")
            return
        }
        log("==> acquiring dispatch lock on \(host.sshTarget)")
        let info = RemoteDispatchLockInfo.now(
            issuerHost: ProcessInfo.processInfo.hostName, pid: ProcessInfo.processInfo.processIdentifier,
            issuer: LocalConfig.resolveIssuerId())
        let ticket = RemoteDispatchQueue.resolveTicket(
            environment: ProcessInfo.processInfo.environment, issuer: LocalConfig.resolveIssuerId(),
            runGroup: runGroup, pid: ProcessInfo.processInfo.processIdentifier, now: Date())
        if forceLock {
            log("warning: --force-lock is stealing the dispatch lock on \(host.sshTarget)"
                + " (any dispatch it was protecting may still be running)")
            // 奪う側が列に残り続けないよう、先に自分のチケットを消す
            dequeueTicket(layout: layout, ticket: ticket)
            _ = try sshCapture(RemoteDispatchLock.forceAcquireCommand(home: layout.home, info: info))
            return
        }
        var elapsed = 0
        while true {
            let result = try Shell.run(sshBase + [host.sshTarget,
                                                  RemoteDispatchQueue.enqueueAndTryAcquireCommand(
                                                    home: layout.home, ticket: ticket, info: info)])
            // 到達不能は待って直る種類の失敗ではない。**チケットを消しに行かない**(向こうへ届かない)
            guard result.status != 255 else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "cannot reach \(host.sshTarget) over ssh (status 255)\n\(result.tail)")
            }
            guard let outcome = RemoteDispatchQueue.parseOutcome(result.output, ticket: ticket) else {
                // 並べなかった/シェルのエラーで判定語が読めない ―― 既存のエラー経路へ倒す
                dequeueTicket(layout: layout, ticket: ticket)
                let existing = try? sshCapture(RemoteDispatchLock.readCommand(home: layout.home))
                throw RemoteDispatchError.remoteSetupFailed(Self.dispatchLockFailureMessage(
                    status: result.status, lockRead: existing, tail: result.tail,
                    sshTarget: host.sshTarget))
            }
            let position: Int
            let total: Int
            let holder: RemoteDispatchLockInfo?
            switch outcome {
            case .acquired:
                // 向こうで自分のチケットは消えている(enqueueAndTryAcquireCommand が消す)
                return
            case .waiting(let p, let t, let h), .held(let p, let t, let h):
                position = p
                total = t
                holder = h
            }
            // 先頭なのに取れなかった = 誰かが掴んでいる。**自分の死んだディスパッチなら回収する**
            // (毎周試す ―― 待ち始めた時点では保持者が生きているのが普通なので初回はほぼ必ず
            // 空振りし、待っている間に保持者が死ぬことがある。判定は pid の生死だけなので
            // 毎周撃っても安い。LocalDispatchLock.acquire と同じ規律)
            if case .held = outcome {
                switch autoReleaseOurStaleLock(layout: layout) {
                case .released:
                    continue // 待機列経由で撃ち直す
                case .keptBecauseRunIsAlive(let reason):
                    // 向こうで run が生きているので、待てるなら待つ(待たないならそのまま落とす)。
                    // 定型文(heldMessage)は unlock を勧めるので使わない(unlock も同じ理由で断る)
                    guard waitLock != nil else {
                        dequeueTicket(layout: layout, ticket: ticket)
                        throw RemoteDispatchError.remoteSetupFailed(
                            "the dispatch lock on \(host.sshTarget) belongs to an earlier dispatch of yours"
                            + " from this Mac that is no longer running here, so it was not released:"
                            + " \(reason)")
                    }
                case .notOurs:
                    break
                }
            }
            let status = DispatchWaitStatus(
                target: host.sshTarget, position: position, total: total,
                holder: holder,
                elapsedSeconds: elapsed, limitSeconds: waitLock)
            guard let limitSeconds = waitLock else {
                dequeueTicket(layout: layout, ticket: ticket)
                throw RemoteDispatchError.remoteSetupFailed(
                    status.refusalMessage)
            }
            // **ログと NDJSON イベントは同じ式で出す**(判断を2つ持たない ―― 片方だけ刻みが
            // 変わると端末と拡張で見える回数が食い違う)。shouldLogProgress は elapsed == 0 でも
            // true を返すので、分岐は「初回の文言か経過の文言か」だけ
            if WaitLockPolling.shouldLogProgress(elapsedSeconds: elapsed) {
                log(elapsed == 0 ? status.queuedLine : status.stillQueuedLine)
                emitDispatchWaiting(status)
            }
            // **中断は待機列から抜けて throw する**(LocalDispatchLock.acquire と同じ挙動)。
            // ロックはまだ取れていないので外す物は無い ―― 消すのはチケットだけ
            guard !interruptFlag.interrupted else {
                dequeueTicket(layout: layout, ticket: ticket)
                throw RemoteDispatchError.remoteSetupFailed(
                    "interrupted while queued for the dispatch lock on \(host.sshTarget)"
                    + " (waited \(elapsed)s) — left the queue")
            }
            guard WaitLockPolling.decide(elapsedSeconds: elapsed,
                                         limitSeconds: limitSeconds) == .retry else {
                dequeueTicket(layout: layout, ticket: ticket)
                throw RemoteDispatchError.remoteSetupFailed(
                    status.refusalMessage)
            }
            Thread.sleep(forTimeInterval: Double(WaitLockPolling.pollIntervalSeconds))
            elapsed += WaitLockPolling.pollIntervalSeconds
        }
    }

    /// 待機の事実を `fleetest api run` の NDJSON へ出す(**apiRun のときだけ** ―― cliRun の
    /// stdout は人間向けなので普段どおりのログのまま)。押した人に無言で止まって見えるのを防ぐのが目的で、
    /// 数字・保持者はログと同じ1つの値(`DispatchWaitStatus`)から採る。
    /// **machine は拡張のモニタータイル・run レーンと同じ名前空間**にする ―― `hostLabel`
    /// (`--runner` の生値 = 登録簿の machine 名)があればそれ、無ければ ssh 宛先
    /// (エイリアスが無い経路。host をそのまま名乗るほうが、拡張に空欄を出すより読める)。
    /// 1行の組み立ては `ApiDispatchWaitingEvent.emit`(手元のロックと共有する1箇所)
    private func emitDispatchWaiting(_ status: DispatchWaitStatus) {
        guard mode == .apiRun else { return }
        ApiDispatchWaitingEvent.emit(machine: hostLabel ?? host.sshTarget, status: status)
    }

    /// 待つのをやめた/失敗したときに**自分のチケットだけ**消す(他人の待機には触らない)。
    /// 失敗は無視する ―― 消せなくても staleSeconds で失効するので、ここで run を落とす価値は無い
    private func dequeueTicket(layout: RemoteLayout, ticket: DispatchTicket) {
        _ = try? sshCapture(RemoteDispatchQueue.dequeueCommand(home: layout.home, ticket: ticket))
    }

    private enum StaleLockDecision {
        case released
        /// 自分の死んだディスパッチのロックだが、ランナー上でその run は生きていた/確かめられなかった
        case keptBecauseRunIsAlive(String)
        /// 他人・他機・自分の生きているディスパッチのロック(そのまま待たせる)
        case notOurs
    }

    /// **自分の死んだディスパッチが残したロックは自動で回収する**。判定は `remote unlock`/
    /// モニター起動時の自動掃除(StaleLockSweep)と同じ `RemoteDispatchUnlock.decideAutomaticSweep`
    /// を共有する(同じ規則を2箇所に持たない)。他人・他機のロックは release を返さない(refuse)
    private func autoReleaseOurStaleLock(layout: RemoteLayout) -> StaleLockDecision {
        let existing = try? sshCapture(RemoteDispatchLock.readCommand(home: layout.home))
        let sweep = Self.staleLockAutoRelease(
            lockRead: existing, myIssuer: LocalConfig.resolveIssuerId(),
            myHost: ProcessInfo.processInfo.hostName, pidAlive: ProcessLiveness.isAlive)
        guard case .release = sweep else { return .notOurs }
        switch RemoteDispatchUnlock.guardingLiveRemoteRun(
            sweep, livePIDs: liveDispatchedRunPIDs(layout: layout)) {
        case .release(let reason):
            log("==> auto-releasing a stale dispatch lock on \(host.sshTarget) left by a dead process"
                + " of ours (\(reason))")
            _ = try? sshCapture(RemoteDispatchLock.releaseCommand(home: layout.home))
            return .released
        case .refuse(let reason):
            return .keptBecauseRunIsAlive(reason)
        case .nothingToDo:
            return .notOurs
        }
    }

    /// ランナー上でディスパッチの run が生きている pid(`RemoteDispatchLock.liveDispatchedRunsCommand`)。
    /// ssh に失敗したら nil(= 確かめられなかった。guardingLiveRemoteRun は外さない側に倒す)
    private func liveDispatchedRunPIDs(layout: RemoteLayout) -> [Int32]? {
        guard let probe = try? Shell.run(sshBase + [host.sshTarget,
                                                    RemoteDispatchLock.liveDispatchedRunsCommand(base: layout.base)]),
              probe.status == 0 else { return nil }
        return RemoteDispatchLock.parseLivePIDs(probe.output)
    }

    /// 取得失敗のあと、既存ロックの控え(生の JSON テキスト。読めなければ nil・空はロック不在)から
    /// 「自分のこの機械の死んだディスパッチなら自動回収してよいか」を判定する。純粋関数
    /// (I/O は呼び出し側)。空(誰も掴んでいない)・読めない(ssh 失敗)は `.nothingToDo` —— 回収する
    /// 対象が無い/判定できないので、通常のエラー文言(dispatchLockFailureMessage)に任せる
    static func staleLockAutoRelease(
        lockRead: String?, myIssuer: String, myHost: String, pidAlive: (Int32) -> Bool,
        startTime: (Int32) -> Date? = ProcessLiveness.startTime
    ) -> RemoteDispatchUnlock.Decision {
        guard let lockRead, !lockRead.isEmpty else { return .nothingToDo }
        let probe = RemoteDispatchLock.Probe.held(RemoteDispatchLock.decode(lockRead))
        return RemoteDispatchUnlock.decideAutomaticSweep(
            probe: probe, myIssuer: myIssuer, myHost: myHost, pidAlive: pidAlive, startTime: startTime)
    }

    /// 取得失敗(status ≠ 0・≠ 255)の文言。読めた控えが**空**(readCommand は不在でも exit 0 で
    /// 空を返す)なら誰も掴んでいない = mkdir 自体が失敗した(権限・ディスク・base の誤り)ので
    /// 「held by …」ではなく stderr をそのまま出す。控えが読めない(nil)・壊れている(decode 不能)
    /// ときは holder unknown の held 文言のまま。
    /// **`scope` は文言だけ**を分ける(手元のロック = `LocalDispatchLock` もこの仕分けを共有する
    /// = 2つ目の実装を作らない)。既定はリモート
    static func dispatchLockFailureMessage(status: Int32, lockRead: String?, tail: String,
                                           sshTarget: String,
                                           scope: DispatchLockScope = .remoteHost) -> String {
        if let lockRead, lockRead.isEmpty {
            let detail = tail.isEmpty
                ? " — no error output; if another dispatch finished just now, retry"
                : ":\n\(tail)"
            let statusLabel = scope == .remoteHost ? "ssh status" : "shell status"
            return "could not create the dispatch lock on \(sshTarget) (\(statusLabel) \(status))\(detail)"
        }
        return RemoteDispatchLock.heldMessage(lockRead.flatMap(RemoteDispatchLock.decode), scope: scope)
    }

    /// **ロックを取った直後に、全発行者ぶんの孤児 hooks を代行実行する**(§18.1 #6)。
    /// 孤児が掴んでいるのはポート = ホスト全体の資源なので、他人の死んだ run の残骸でも自分の
    /// run が詰まる。ロック保持中に撃つので、**生きている run の hooks を触ることはない**
    /// (加えて `hooks reap` 自身が pid の生死で判定する)。
    /// 失敗も出力も run の成否には効かせない —— 片付けの失敗でディスパッチを止めない
    private func reapOrphanedHooksAcrossIssuers(layout: RemoteLayout) {
        let command = RemoteHooksReap.commandAcrossIssuers(layout: layout, quiet: true)
        guard let result = try? Shell.run(sshBase + [host.sshTarget, command]) else { return }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            log("==> reaped teardown scripts left behind on \(host.sshTarget)\n\(trimmed)")
        }
    }

    /// **正常終了(exit 0/1)以外(中断・timeout・ssh 断)は、回収へ入る前にこの判定を通してから
    /// ロックを外す**(正常終了は呼び出し側の末尾の defer が無条件に外す)。
    /// 中断の場合は回収(録画の rsync)が数十秒かかり、その間に中断の猶予が尽きて SIGKILL されると
    /// defer に届かずロックが残る(実測: 3 機とも `collecting recordings` の最中に刺されて
    /// 残った)。timeout・ssh 断の場合は向こうの run がまだ後始末中かもしれず、無条件に外すと
    /// 次の run が同じ機械に重なる。外すのはこのディスパッチの run がランナーに居ないと
    /// 確かめられたときだけ(`releaseIfRunEndedCommand`)。回収は日時付きの dispatch
    /// ディレクトリと results/ しか読まないのでロックは要らない。外せなかったら呼び出し側が
    /// ロックを残したまま進む(次のディスパッチの自動回収 = `autoReleaseOurStaleLock` に任せる)
    private func releaseLockIfRunEnded(layout: RemoteLayout, reportDir: String) -> Bool {
        // 親が握っているロックはここでは外さない(解放の持ち主は親の1箇所だけ)
        guard !parentHoldsThisLock else { return false }
        guard let output = try? sshCapture(RemoteDispatchLock.releaseIfRunEndedCommand(
            home: layout.home, reportDir: reportDir)) else { return false }
        let released = RemoteDispatchLock.releasedEarly(output)
        if released { log("==> released the dispatch lock before collecting"
                          + " (the run had already ended on \(host.sshTarget))") }
        return released
    }

    /// 自分から中断したとき、または exit 0/1 でない(ssh の断・kill = 255/137 等)ときは、
    /// 回収(collectReports)の前に「このディスパッチの run がランナー上でもう終わったか」を待つ
    /// (**中断も待つ** —— ssh は SIGHUP で即座に閉じるが、向こうの run はそこから後始末して run.json を
    /// 書き終えるので、待たないと手元は開始欄だけの写しを回収し「クラッシュ」に見える(実測: 約 2 秒差)。
    /// 終わっていれば待ちは1周で抜ける。
    /// **待った後、外せるなら外す**(`releaseLockIfRunEnded` と同じ「run が終わっていたら外す」
    /// 判定を通す ―― 生きているかもしれない run に、次の run を無条件で重ねない(呼び出し側の
    /// defer は無条件に `rm -rf` するので、その前にここで判定を通す)。戻り値 = 外したか
    /// (呼び出し側が `lockReleasedEarly` へそのまま渡す)。
    /// 待たずに回収へ進むと、リモートの後始末(run.json への interrupted/finishedAt の書き込み)
    /// より先に手元が途中版を回収し、結果 DB でその run が走り続けているように見える
    /// (実測: M1Max へのディスパッチの ssh を SIGKILL してネットワーク断を模した)。
    /// ssh 自体が通らない(sshCapture が throw)なら待たずに下の条件付き解放へ進む
    /// (そちらも同じ ssh 失敗で false を返すので安全側に倒れる)
    /// 回収の前に向こうの run の終わりを待つか(中断・exit 0/1 以外 = 待つ)
    static func shouldAwaitRemoteRunEnd(exitCode: Int32, interrupted: Bool) -> Bool {
        interrupted || (exitCode != 0 && exitCode != 1)
    }

    private func awaitRemoteRunEnd(exitCode: Int32, interrupted: Bool, layout: RemoteLayout,
                                   reportDir: String) -> Bool {
        guard Self.shouldAwaitRemoteRunEnd(exitCode: exitCode, interrupted: interrupted) else { return false }
        let deadline = Date().addingTimeInterval(Self.remoteRunEndWaitLimitSeconds)
        waitLoop: while Date() < deadline {
            guard let output = try? sshCapture(RemoteDispatchLock.runEndedCommand(reportDir: reportDir))
            else { break waitLoop }  // ssh 自体が通らない ―― 下の条件付き解放も同じ理由で失敗し kept 側に倒れる
            if RemoteDispatchLock.runHasEnded(output) { break waitLoop }
            sleep(Self.remoteRunEndPollIntervalSeconds)
        }
        let released = releaseLockIfRunEnded(layout: layout, reportDir: reportDir)
        if !released {
            log("==> the remote run may still be finishing — keeping the dispatch lock"
                + " (the next dispatch on \(host.sshTarget) reclaims it once the run has ended;"
                + " collecting what is there now)")
        }
        return released
    }

    /// 成功・失敗・タイムアウト・例外いずれでも defer から呼ばれる。解放の失敗は run の成否を
    /// 変えない(warn のみ。他の回収処理と同じ規律)が、ロックが残るのは事故なので隠さず言う
    private func releaseDispatchLock(layout: RemoteLayout) {
        // 取っていないロックは外さない(外すと親のロックが消え、後続の run が割り込む)
        guard !parentHoldsThisLock else { return }
        do {
            _ = try sshCapture(RemoteDispatchLock.releaseCommand(home: layout.home))
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
        // エイリアスそのものなので、生の ssh 宛先しか無いときは差し替えずそのまま送る
        if let hostLabel, let failure = RunnerProfileTransfer.localizeAndUpload(
            localProjectDir: project.rootURL, project: project.name, alias: hostLabel,
            layout: layout, sshTarget: host.sshTarget) {
            throw RemoteDispatchError.remoteSetupFailed(failure)
        }
        transferWebViewCache()
    }

    /// WebView レベリング(AndroidWebViewUpdate)の供給元キャッシュをランナーへ届ける。
    /// 実機の無い機械は機内にドナーが居らず永遠に古いまま(M1Max が 124 で取り残され
    /// WebView シナリオがリモートレーンでだけ落ちた)。**失敗しても run は止めない**
    /// (レベリング自体が best-effort。版差は run を落とすより軽い)。android を含まない構成でも
    /// 一度だけ払う(この層では platform を解決しない。rsync は同版なら no-op)
    private func transferWebViewCache() {
        let localDir = AndroidWebViewUpdate.cacheDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: localDir.path),
              names.contains(where: { $0.hasSuffix(".apk") }) else { return }
        let remoteDir = "Library/Caches/fleetest/webview"
        // グロブ無しの固定コマンド(ssh 越しのグロブ禁止。docs/remote-runner.md §18.7)。
        // sshBase を通す(BatchMode/ConnectTimeout 無しだとパスワード入力で止まる・75 秒固まる)
        guard (try? runInherited(sshBase + [host.sshTarget, "mkdir -p \(remoteDir)"])) == 0 else {
            log("⚠️ could not prepare the WebView cache directory on \(host.sshTarget)"
                + " (continuing; WebView levelling on that runner keeps its local donors only)")
            return
        }
        let args = ["rsync"] + RemoteTransferPlan.webViewCacheRsyncArgs(
            localCacheDir: localDir.path, sshTarget: host.sshTarget, remoteCacheDir: remoteDir)
        if (try? runInherited(args)) != 0 {
            log("⚠️ could not transfer the WebView cache to \(host.sshTarget)"
                + " (continuing; WebView levelling on that runner keeps its local donors only)")
        }
    }

    /// ワークスペース(既定 `<project.rootURL>/workspace`。常に有効 = docs/remote-runner.md §17)を
    /// 用意し、リモートの子へ渡す `--workspace` の絶対パスを返す。**呼び出しは
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
        // (ProfileResolver.resolve が ResolvedAppTarget.appPath を計算するのと同じ規則)。
        // installPath には entry.declared(宣言の生文字列)を渡す —— entry.source(絶対パス)は
        // このホストの repoRoot を含むため、リモートの子が自分自身で resolve() し直したときと
        // 名前空間がずれてしまう(WorkspaceAppStaging.installPath の doc)
        for (key, entry) in ProfileResolver.declaredAppPaths(project: project, runName: profile)
            .sorted(by: { ($0.key.platform, $0.key.physical ? 1 : 0)
                          < ($1.key.platform, $1.key.physical ? 1 : 0) }) {
            let dest = WorkspaceAppStaging.installPath(declared: entry.declared,
                                                       workspaceRoot: localWorkspaceURL,
                                                       physical: key.physical)
            if try WorkspaceAppStaging.stageApp(source: entry.source, dest: dest) {
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
    /// 登録簿の `fmConcurrency` を **ssh 宛先で**引く。マシン名ではなく host で引くのは、
    /// ここまで来た時点でエイリアスは解決済みで、手元にあるのが ssh 実体だから。
    /// 未登録・未設定なら nil = ランナー側の既定に任せる
    /// 登録簿のこの機械の行。**鍵は host(ssh 実体)** —— エイリアス(machine)は頻繁に変わりうるので
    /// 引く鍵にしない(docs/remote-runner.md §0)
    private var registeredEntry: RemoteHostEntry? {
        LocalConfig.load().remoteHosts?.first { $0.host == host.sshTarget }
    }

    private var registeredFMConcurrency: Int? { registeredEntry?.fmConcurrency }

    private func runRemoteAndRelay(fleetestArgs: [String], layout: RemoteLayout,
                                   timeoutSeconds: Int?, stamp: String, project: String,
                                   developerDir: String?) throws -> Int32 {
        log("==> running on \(host.sshTarget): fleetest \(fleetestArgs.joined(separator: " "))")
        let command = RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: fleetestArgs,
                                                   issuer: LocalConfig.resolveIssuerId(),
                                                   fmConcurrency: registeredFMConcurrency,
                                                   developerDir: developerDir)
        // ssh を「このプロセスが死んだら止まる」包みに入れる(孤児の ssh がリモートの run を出力の write で
        // 止めたままにする。理由は ParentBoundCommand の冒頭)
        let status = try runInheritedWithLineRewrite(
            ParentBoundCommand.wrap(sshRunBase + [host.sshTarget, command],
                                    parentPID: ProcessInfo.processInfo.processIdentifier),
            layout: layout, timeoutSeconds: timeoutSeconds, stamp: stamp, project: project)
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
    /// ローカル実行のレポート・録画と混ざらない)。
    /// **interrupted**: このディスパッチが自分から中断した(SIGINT/SIGTERM)かどうか。
    /// 中断は正常に閉じて0件なだけで「失敗」ではない(実測: 4機ファンアウトへの
    /// SIGTERM 中断でも「the run failed」と出ていた。reportsMissingNote の宣言参照)
    private func collectReports(project: TestProject, remoteReportDir: String, interrupted: Bool) {
        log("==> collecting reports")
        let localReports = project.reportsDir
        try? FileManager.default.createDirectory(at: localReports, withIntermediateDirectories: true)
        let remoteReports = "\(host.sshTarget):\(remoteReportDir)/"
        // --safe-links の理由は RemoteArtifactCollection.rsyncArgs のコメント(回収は共有ディレクトリからの入力)
        collectRsync(["rsync", "-az", "--safe-links", remoteReports, localReports.path + "/"],
                     what: "reports", missingNote: Self.reportsMissingNote(interrupted: interrupted))
    }

    /// 実績 JSON(run.json/scenarios/*.json/host-metrics.ndjson)と録画を含め results/ を
    /// 丸ごと回収する。失敗は warn のみ(run の成否は変えない。collectReports と同じ規律)。
    /// **戻り値 = この回収で実際に転送された scenario JSON の相対パス**(rsync
    /// `--out-format=%n` の出力から拾う。一部だけ転送できた回もその分は返す。何も転送されなかったときは空配列 ——
    /// `collectedScenarioTexts` はこの一覧しか読まないので、そのときは何も読めない)
    @discardableResult
    private func collectArtifacts(project: TestProject, layout: RemoteLayout) -> [String] {
        let localResults = project.rootURL.appendingPathComponent("results")
        try? FileManager.default.createDirectory(at: localResults, withIntermediateDirectories: true)
        let localProjectsDir = project.rootURL.deletingLastPathComponent().path

        log("==> collecting recordings and run logs")
        let args = ["rsync"] + RemoteArtifactCollection.resultsRsyncArgs(
            project: project.name, layout: layout, sshTarget: host.sshTarget,
            localProjectsDir: localProjectsDir)
        let (collected, output) = collectRsyncCapturingOutput(
            args, what: "recordings and run logs",
            missingNote: "note: the remote produced no recordings or run logs")
        // **回収できたときだけ**リモートの録画を消す(docs/remote-runner.md §15.4:
        // 録画にはテスト資格情報の入力画面が写り込み、共有ランナーでは同じ UNIX アカウントの
        // 全員が読める)。回収に失敗したまま消すと唯一の証拠を失うので、失敗時は残す
        if collected { deleteRemoteRecordings(project: project, layout: layout) }
        // 一部だけ転送できた回も、転送できた分は読む(collectRsyncCapturingOutput が出力を返す)
        return RemoteArtifactCollection.transferredScenarioJSONPaths(rsyncOutput: output)
    }

    /// 回収した results の `reportPath` を、回収先(ローカルの `TestProjects/<project>/reports/`)へ
    /// 向け直す。リモートは**ディスパッチ単位の隔離先**を記録しており、そこは回収後に消えるので、
    /// 直さないと**リモート実行の結果だけ results からレポートへ飛べない**(規則は
    /// `RemoteReportLink`)。`texts` は `collectedScenarioTexts` の結果を呼び出し側と共有したもの
    /// (同じ走査を2回行わない)。失敗は warn のみ(run の成否は変えない)
    private func relinkCollectedReports(project: TestProject, stamp: String,
                                        texts: [(url: URL, text: String)]) {
        let reportsFromRepoRoot = "\(RemoteLayout.projectsDirName)/\(project.name)/reports"
        var relinked = 0
        for (url, text) in texts {
            guard let recorded = Self.recordedField(in: text, key: "reportPath"),
                  let rewritten = RemoteReportLink.rewrittenReportPath(
                    recorded: recorded, stamp: stamp,
                    projectReportsPathFromRepoRoot: reportsFromRepoRoot) else { continue }
            let rewrittenText = text.replacingOccurrences(of: recorded, with: rewritten)
            if (try? rewrittenText.write(to: url, atomically: true, encoding: .utf8)) != nil { relinked += 1 }
        }
        if relinked > 0 { log("==> relinked \(relinked) report path(s) to the collected copies") }
    }

    /// **この stamp を含む・今回の回収で転送された** scenario JSON だけを読む。
    /// 「当月+前月の runs ディレクトリを全件 String で読み `contains(stamp)`」という走査を
    /// `saveHostFacts`/`relinkCollectedReports` がそれぞれ独立に行うと、
    /// 手元の E2E-CMP 規模(46,945 ファイル)で1回23.6秒 × 2回 = ディスパッチごとに約50秒
    /// 手元レーンを遊ばせる。`transferredScenarioPaths` は `collectArtifacts` が
    /// rsync `--out-format=%n` から拾った一覧(このディスパッチで新規に転送されたファイルだけ)
    /// なので、件数は「今回走った本数」程度で済む。`stamp` を含むかの確認は残す(このディスパッチの
    /// stamp は一意なので理屈上は不要だが、判定を一箇所(この関数)に保つ)。
    /// 呼び出し側は結果を1回だけ作り、saveHostFacts/relinkCollectedReports/writeLastResults へ渡す
    // internal(not private): RemoteDispatcherScenarioTextsTests exercises this directly with a
    // fake results/ tree to prove the "only the transferred paths" scoping
    func collectedScenarioTexts(
        project: TestProject, stamp: String, transferredScenarioPaths: [String]
    ) -> [(url: URL, text: String)] {
        let localResults = project.rootURL.appendingPathComponent("results")
        var results: [(URL, String)] = []
        for relative in transferredScenarioPaths {
            let url = localResults.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(stamp) else { continue }
            results.append((url, text))
        }
        return results
    }

    /// scenario JSON の `"<key>": "…"` の値だけを取り出す(JSON を再エンコードすると
    /// 鍵の順序や表現が変わり、他のツールが読む記録を無用に書き換えるため文字列置換にする)
    // internal(not private): tested directly (RemoteDispatcherScenarioTextsTests)
    static func recordedField(in json: String, key: String) -> String? {
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
    /// **接続のたび**にハードウェア UUID を採ってキャッシュへ書く(ユーザー決定)。
    /// ここが唯一の書き手で、**run の最後(saveHostFacts)ではなく接続直後**に置く ——
    /// ロックも取れずに落ちた run でも控えが残り、「この host は前回と別の Mac を指している」を
    /// run の頭で言える。触るのは UUID 欄だけ(他の欄は既存値のまま)。
    /// 判定は `RemoteHardwareUUIDChange` の1箇所・**run は止めない**
    /// 戻り値は控えた値(= 順序の鍵。読めなければ nil)
    @discardableResult
    private func cacheHardwareUUID(project: TestProject, session: RemoteSessionInfo?) -> String? {
        let dir = RemoteHostFactsStore.dir(project: project)
        let key = host.sshTarget
        let existing = RemoteHostFactsStore.load(dir: dir, host: key)
        let outcome = RemoteHardwareUUIDChange.resolve(
            cached: existing?.hardwareUUID, observed: session?.hardwareUUID, host: key)
        if let warning = outcome.warning { log(warning) }
        // 値が動いていなければ書かない(毎ディスパッチ updatedAt だけを書き換えない)
        guard outcome.stored != existing?.hardwareUUID else { return outcome.stored }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var facts = existing ?? RemoteHostFacts(updatedAt: stamp)
        facts.hardwareUUID = outcome.stored
        facts.updatedAt = stamp
        RemoteHostFactsStore.save(facts, dir: dir, host: key)
        return outcome.stored
    }

    private func saveHostFacts(project: TestProject, overheadSeconds: Double,
                               session: RemoteSessionInfo?, texts: [(url: URL, text: String)]) {
        let dir = RemoteHostFactsStore.dir(project: project)
        let key = host.sshTarget
        let existing = RemoteHostFactsStore.load(dir: dir, host: key)
        let recorded = recordedMachine(texts: texts) ?? existing?.host
        let concurrentDevices = recordedConcurrentDevices(texts: texts) ?? existing?.concurrentDevices
        let facts = RemoteHostFacts(
            host: recorded,
            // 表示用のエイリアス(鍵ではない。RemoteHostFacts.machineAlias の宣言参照)
            machineAlias: hostLabel ?? existing?.machineAlias,
            // 書き手は接続直後の cacheHardwareUUID だけ(ここは読み直した値を持ち越す)
            hardwareUUID: existing?.hardwareUUID,
            dispatchOverheadSeconds: overheadSeconds,
            processorModel: session?.processorModel ?? existing?.processorModel,
            coreCount: session?.coreCount ?? existing?.coreCount,
            concurrentDevices: concurrentDevices,
            updatedAt: ISO8601DateFormatter().string(from: Date()))
        RemoteHostFactsStore.save(facts, dir: dir, host: key)
    }

    private func recordedMachine(texts: [(url: URL, text: String)]) -> String? {
        for (_, text) in texts {
            // 記録側のキーは "host"(改名済み)。旧記録の "machine" も読む
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

    /// リモートで走ったシナリオの `--failed` 記録を手元へ書く。リモート機の
    /// `ScenarioHost.run()` はリモート機自身の `.fleetest/last-results/` へ書くだけなので、
    /// 手元は何も記録されず `--failed` がリモートで落ちた分を拾えなかった
    /// )。回収済み scenario JSON の
    /// `scenarioID`/`passed`/`profile`(profile は `RunRecorder` が既に書いている実効プロファイル名。
    /// profile-less な run では欄自体が無い = nil → `LastResultsStore.noProfileKey` へ畳まれる)
    /// から直接書く。**同じ stamp に複数シナリオが乗る(broadcast 含む)のは後勝ちでよい** ——
    /// LastResultsStore はローカル実行でも「直近の1件」の記録
    // internal(not private): tested directly (RemoteDispatcherScenarioTextsTests)
    func writeLastResults(texts: [(url: URL, text: String)], project: TestProject) {
        for (_, text) in texts {
            guard let scenarioID = Self.recordedField(in: text, key: "scenarioID"),
                  let passed = Self.recordedBoolField(in: text, key: "passed") else { continue }
            LastResultsStore.record(project: project, scenarioID: scenarioID, passed: passed,
                                    profile: Self.recordedField(in: text, key: "profile"))
        }
    }

    /// reports が1件も回収できなかったときの注記(純粋関数)。**中断(こちらから
    /// SIGINT/SIGTERM で止めた)と本当の失敗(何も書く前に落ちた)を混同しない** —— 中断は
    /// 正常に閉じて0件なだけで「失敗」ではない
    // internal(not private): tested directly (RemoteDispatcherScenarioTextsTests)
    static func reportsMissingNote(interrupted: Bool) -> String {
        interrupted
            ? "note: the remote produced no reports (the run was interrupted before writing any)"
            : "note: the remote produced no reports (the run failed before writing any)"
    }

    /// scenario JSON の `"<key>": true|false` の値を取り出す(`recordedField` は引用符付きの
    /// 文字列専用なので、Bool の `passed` はこちらで読む)
    // internal(not private): tested directly (RemoteDispatcherScenarioTextsTests)
    static func recordedBoolField(in json: String, key: String) -> Bool? {
        guard let keyRange = json.range(of: "\"\(key)\"") else { return nil }
        let rest = json[keyRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let afterColon = rest[rest.index(after: colon)...].drop(while: { $0 == " " })
        if afterColon.hasPrefix("true") { return true }
        if afterColon.hasPrefix("false") { return false }
        return nil
    }

    /// 回収の rsync。**転送元不在(= run が成果物を作る前に落ちた)は警告にしない** ——
    /// 本当の失敗理由の下にノイズを積まないため(RemoteArtifactCollection.isMissingSourceFailure)。
    /// stderr を見る必要があるので継承ではなく捕捉する(回収は少量で進行表示が要らない)
    /// 戻り値 = 転送が成功したか(**回収できていない物を消さない**ための判定に使う。
    /// 転送元不在は「消す物も無い」なので成功と同じ扱いでよいが、区別できるよう false を返す)
    @discardableResult
    private func collectRsync(_ args: [String], what: String, missingNote: String) -> Bool {
        collectRsyncCapturingOutput(args, what: what, missingNote: missingNote).ok
    }

    /// collectRsync と同じ規律だが、**成功時の stdout(rsync の出力)も返す**(
    /// `--out-format=%n` を付けた呼び出しから転送済みファイル一覧を得るため)。output を使わない
    /// 呼び出し元は collectRsync を使う
    private func collectRsyncCapturingOutput(
        _ args: [String], what: String, missingNote: String
    ) -> (ok: Bool, output: String) {
        guard let result = try? Shell.run(args) else {
            log("warning: failed to collect \(what) from the remote (could not run rsync)")
            return (false, "")
        }
        guard result.status != 0 else { return (true, result.output) }
        if RemoteArtifactCollection.isMissingSourceFailure(status: result.status, stderr: result.tail) {
            log(missingNote)
            return (false, "")
        }
        log("warning: failed to collect \(what) from the remote (rsync exited with \(result.status))\n\(result.tail)")
        // **出力は捨てない** —— 一部だけ転送(23/24 等)でも、`--out-format=%n` の行は実際に転送できた
        // ファイルだけなので、その分の後処理(relink・facts・`--failed` の記録)は進められる
        return (false, result.output)
    }

    /// 回収済みの録画をランナーから消す。実績 JSON(run.json / scenarios/*.json)は**消さない** ——
    /// LPT がリモートの実績を見るのはランナー側のファイルではなく回収した手元のものだが、
    /// 向こうの results をまるごと消すと `remote clean` の保持ポリシーと二重管理になる。
    /// 失敗は warn のみ(run の成否を変えない)
    private func deleteRemoteRecordings(project: TestProject, layout: RemoteLayout) {
        do {
            _ = try sshCapture(RemoteArtifactCollection.deleteRecordingsCommand(
                project: project.name, layout: layout))
        } catch {
            log("warning: failed to delete the collected recordings on \(host.sshTarget)"
                + " (\(error.localizedDescription)) — `fleetest remote clean` removes them later")
        }
    }

    private func collectJUnit(remotePath: String, localPath: String, layout: RemoteLayout,
                              stamp: String, project: String) {
        guard let xml = try? sshCapture("cat \(RemoteShell.quote(remotePath))"), !xml.isEmpty else {
            log("warning: failed to collect the remote JUnit report (\(remotePath))")
            return
        }
        // **ディスパッチ単位の隔離先 → 回収先(reports/)を先に当ててから** workDir → localRoot を
        // 当てる。順序を逆にする(workDir 置換だけ)と、隔離先(回収後にリモートで削除される)
        // を指す**手元に存在しないパス**が JUnit の report 属性に残る
        let reportsRedirected = RemoteReportLink.rewriteDispatchReportPaths(
            xml, stamp: stamp, project: project)
        // **写す先は workDir**(base ではない)。base のまま置換すると `users/<issuer>/work` が
        // 残って手元に存在しないパスができる(実害。§18.2 の発行者ネームスペースを
        // 足したときに追随し損ねていた)
        let rewritten = RemotePathRewrite.rewrite(
            reportsRedirected, remoteRoot: layout.workDir, localRoot: localRepoRoot.path)
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
            // ConsoleOut は libc のバッファを通さないのでそのまま届く(かつ他の書き手と
            // ロックを共有するので割り込まれない)
            ConsoleOut.out(message)
        case .apiRun:
            ConsoleOut.err(message)
        }
    }

    // MARK: - process helpers

    private func localCapture(_ args: [String]) -> String? {
        guard let result = try? Shell.run(args), result.status == 0 else { return nil }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    /// 全 ssh 共通の基底引数。ConnectTimeout が無いと到達不能ホストで TCP 既定(75秒超)固まる。
    /// キープアライブ(`SSHOptions.keepAliveArgs`)は接続**後**に黙って死んだ回線を切るためのもので
    /// ConnectTimeout(接続そのものの上限)とは効く場面が別 — 両方要る
    private var sshBase: [String] {
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"] + SSHOptions.keepAliveArgs
    }

    /// リモート実行専用(§16.1): `-tt` で疑似 TTY を強制割り当てると、ローカル ssh が
    /// SIGTERM/SIGKILL で落ちたとき SIGHUP がリモートのプロセスグループへ伝わり、キャンセルが
    /// 伝播する。照会系(sshBase)には付けない — TTY 化で stdout に CR が混ざり
    /// git rev-parse 等のキャプチャ結果を汚す
    private var sshRunBase: [String] { sshBase + ["-tt"] }

    /// 適合チェックの照会。**失敗を「値が無い」に潰さず理由を持ち帰る**(RemoteCompat.ProbeOutcome)。
    /// 判定は緩めない —— 2回とも失敗すれば非互換のまま落ちる。
    ///
    /// **1回だけ引き直す**: ssh の単発失敗はレーンごと(= シナリオ数本)を捨てるのに対し、
    /// 引き直しの費用は ssh 1往復。**待ち時間は置かない** —— 何秒待てば直るかを言える根拠が
    /// 無い定数はここに要らない(CLAUDE.md「根拠のない定数は排除」)
    private func probeRemote(_ label: String,
                             _ body: () throws -> String) -> RemoteCompat.ProbeOutcome {
        do {
            return .value(try body())
        } catch {
            log("warning: could not query the remote \(label) (\(describe(error))) — retrying once")
            do {
                return .value(try body())
            } catch {
                return .failed(detail: describe(error))
            }
        }
    }

    /// LocalizedError は errorDescription、それ以外は説明を採る(ShellError は
    /// CustomStringConvertible なので "\(error)" が期限切れの文面になる)
    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private func sshCapture(_ command: String) throws -> String {
        let result = try Shell.run(sshBase + [host.sshTarget, command],
                                    timeout: Self.sshCaptureTimeoutSeconds)
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
    /// ConsoleOut.out(stdout) する。stderr は継承のまま。パイプ 64KB 飽和で子がブロックする罠を避けるため
    /// 読み取りは別スレッドで行う。期限超過時は SIGTERM→2秒猶予→SIGKILL(Shell.runRaw の
    /// timeout 経路と同じ規律)。stdin は /dev/null に固定する(`-tt` は TTY として stdin を
    /// 要求するが、ディスパッチは対話しない)。**timeoutSeconds nil = 無期限**
    /// (`.distantFuture` を渡す。欠陥2: RemoteTimeout.seconds がシナリオ数不明を表す nil)
    private func runInheritedWithLineRewrite(_ argv: [String], layout: RemoteLayout,
                                             timeoutSeconds: Int?, stamp: String,
                                             project: String) throws -> Int32 {
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
            // ディスパッチ単位の隔離先 → 回収先(reports/)を**先に**当てる(collectJUnit と
            // 同じ順序 — 理由は RemoteReportLink.rewriteDispatchReportPaths の宣言)
            let reportsRedirected = RemoteReportLink.rewriteDispatchReportPaths(
                line, stamp: stamp, project: project)
            let rewritten = RemotePathRewrite.rewrite(
                reportsRedirected, remoteRoot: remoteRoot, localRoot: localRoot)
            // `-tt`(擬似 TTY)はリモートの stderr を stdout に合流させる。apiRun の stdout は
            // NDJSON 専用の契約なので、機械可読行だけを stdout へ流し、リモートの人間向け診断は
            // stderr へ振り分け直す(localhost E2E で混入を実測)
            if mode == .apiRun, !RemoteRelay.isMachineReadableLine(rewritten) {
                ConsoleOut.err(rewritten)
                return
            }
            ConsoleOut.out(rewritten)
        }
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            while true {
                // availableData = 届いた分だけ返す(readData(ofLength:) は length か EOF まで
                // 貯めるので、NDJSON 中継が ssh の終了時の一括になる。実測)。
                // **1回ごとに解放の区切り**(autoreleasepool)—— 自動解放の NSData が抜けないループで溜まる
                let eof: Bool = autoreleasepool {
                    let chunk = readHandle.availableData
                    if chunk.isEmpty { return true }   // 子の終了/kill による書込端クローズで EOF
                    for line in splitter.feed(chunk) { relayLine(line) }
                    return false
                }
                if eof { break }
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
