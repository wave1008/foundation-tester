// VSCode拡張等向け機械可読 CLI(ftester api run)。シナリオを実行し NDJSON(1行1イベント)を
// stdout に流す: runStarted/(workersReady)/ScenarioEvent相当の各種イベント/runFinished 以外は
// 出さない(診断は stderr のみ)。
//
// --profile 指定時はプロファイルを解決してワーカー(iOSブリッジ供給+Android照合。実体は
// ProfileWorkerFactory)を構築する。--dry-run/--debug 以外は RunOrchestrator(FTCore)へ全
// ワーカーを渡し並列実行(ftester run --profile の ProfileRunner と同じ並列度)。この経路では
// runStarted 直後に workersReady を1回 emit し、各イベントに worker フィールド
// ("<platform>:<デバイス論理名>"。api monitor の monitorDevices.id と同一規則)を付ける。
// --dry-run --profile / --debug は platform に合う最初のワーカー(単体 --dry-run はワーカー
// 無し)で逐次実行し worker フィールドは付けない。--dry-run はワーカー構築自体を省略する。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run scenarios and stream NDJSON events (runStarted -> ScenarioEvent... -> "
            + "runFinished) on stdout. With --profile, runs workers in parallel except for "
            + "--dry-run/--debug. Diagnostics go to stderr only. With --debug, control "
            + "commands from stdin are passed straight through to the runner")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json). Includes device provisioning and auto-install. Cannot be combined with --platform/--port/--serial")
    var profile: String?

    @Option(name: .customLong("scenario"), parsing: .upToNextOption,
            help: "Scenario IDs to run (Class.method; a class name alone runs all of its scenarios). Repeatable, at least one required. @Deleted scenarios run only on an exact match")
    var scenarios: [String] = []

    @Flag(help: "Allow FM-based locator self-healing (with --profile it overrides the profile heal setting only when true)")
    var heal = false

    @Option(name: .customLong("report-dir"),
            help: "Directory to write reports to (defaults to TestProjects/<name>/reports; with --profile it overrides the profile reportDir)")
    var reportDir: String?

    @Option(name: .customLong("default-timeout"),
            help: "Default timeout in seconds for assertions such as exist/textIs (decimals allowed, default 5; with --profile the profile defaultTimeout wins)")
    var defaultTimeout: Double?

    @Option(name: .customLong("scenario-timeout"),
            help: "Per-scenario wall-clock timeout in seconds (host-side watchdog; on overrun the child is killed and the scenario fails. Default 90; with --profile the profile scenarioTimeout wins)")
    var scenarioTimeout: Int?

    @Flag(name: .customLong("dry-run"),
          help: "Record every command without touching a device (for listing and reviewing steps; with --profile it also skips worker construction)")
    var dryRun = false

    @Flag(help: "Accept pause/resume control commands (NDJSON) on stdin (only usable with exactly one --scenario)")
    var debug = false

    @Option(name: .customLong("breakpoint"),
            help: "Breakpoint (<file>:<line>). Only effective with --debug; repeatable")
    var breakpoints: [String] = []

    @Flag(name: .customLong("pause-on-start"),
          help: "Start paused before the first step (only effective with --debug)")
    var pauseOnStart = false

    @Flag(name: .customLong("skip-build"), help: "Skip the swift build before running")
    var skipBuild = false

    @Flag(name: .customLong("no-lpt"),
          help: "Disable LPT ordering (longest past runtime first) and dispatch in scenario ID order")
    var noLPT = false

    @Option(name: .customLong("lpt-history-runs"),
            help: "Number of past runs to read for LPT ordering (newest first, default 5)")
    var lptHistoryRuns: Int?

    @Option(help: "Target platform: ios / android (default ios; cannot be combined with --profile)")
    var platform: String?

    @Option(name: .long, help: "Bridge port number (iOS only; cannot be combined with --profile)")
    var port: UInt16?

    @Option(help: "Android device serial (adb -s; defaults to the only connected device. Cannot be combined with --profile)")
    var serial: String?

    @Option(help: "Dispatch this run to a remote Mac over SSH: a registered name (ftester remote hosts) or a raw user@host/host. Relays its NDJSON stream. Requires --profile. Experimental (docs/remote-runner.md)")
    var host: String?

    @Option(name: .customLong("remote-dir"),
            help: "Runner-only base directory on the remote host (holds its own clone and workspace; default: the host registry's entry, or ~/ftester-runner). Must NOT point at an existing local install of foundation-tester")
    var remoteDir: String?

    @Option(name: .customLong("remote-timeout"),
            help: "Timeout in seconds for the whole remote dispatch (default: auto, sized from the scenario count; see docs/remote-runner.md)")
    var remoteTimeout: Int?

    @Option(name: .customLong("remote-artifacts"),
            help: "Collect recordings and run logs (results/) from the remote after the run: collect (default) or on-demand (leave them on the remote; docs/remote-runner.md)")
    var remoteArtifacts: String = "collect"

    @Flag(name: .customLong("performance"),
          help: "Performance-testing mode (--profile only): if a dead lane cannot be revived before the run starts, fail instead of dropping it and continuing on the remaining lanes. iOS lanes are built before the run starts (no late join) so a missing one is reported before the run, not in the middle of it")
    var performanceMode = false

    @Option(name: .customLong("device"), parsing: .upToNextOption,
            help: ArgumentHelp("Run on only these devices of the run profile (device names as written in "
                + "the machine profile). Repeatable; defaults to every device the run profile lists. "
                + "Used by the per-host sub-runs when one run profile spans devices on several machines "
                + "(docs/remote-runner.md §13)"))
    var devices: [String] = []

    /// **どの機械のデバイスを使うか**。`--device` は名前でしか絞れないが、一意なのは (host, name)
    /// なので、名前だけだと別の機械の同名デバイスまで掴む(run の同名オプションと同じ規律)。
    /// ホスト別サブ実行(ApiRunHostFanout)が自分で付ける値で、手で打つものではない
    @Option(name: .customLong("device-host"),
            help: ArgumentHelp(
                "Only use the devices assigned to this machine (\"local\" or a registered host name). "
                + "Set by the per-host sub-runs; not for hand use",
                visibility: .hidden))
    var deviceHost: String?

    /// **手で打つものではない**。RunScenarios.workspace と同じ契約(RemoteRunDispatcher が
    /// ミラー後の絶対パスを渡す)
    @Option(help: ArgumentHelp(
        "Override this run profile's remoteControl.workspace (where the staged appPath package is "
        + "installed from). Set by the remote dispatcher on the far side; not for hand use",
        visibility: .hidden))
    var workspace: String?

    func run() async throws {
        // pause等のイベントが既定の全バッファに滞留すると読み手(VSCode拡張)と相互待ちになる
        // (ScenarioRunnerMain.swift の --debug 実装と同じ理由)。--debug 以外も常に行バッファにする
        setvbuf(stdout, nil, _IOLBF, 0)

        guard !scenarios.isEmpty else {
            throw ValidationError("specify at least one --scenario")
        }
        if debug && scenarios.count != 1 {
            throw ValidationError("--debug can only be used with exactly one --scenario")
        }
        if profile != nil && (platform != nil || port != nil || serial != nil) {
            throw ValidationError("--profile cannot be combined with --platform/--port/--serial")
        }

        let testProject = try ScenarioHost.project(named: project)

        // NDJSON はここより後でしか出さない(emitLine(ApiRunStartedEvent) 以降)。--host/マシン
        // プロファイルの host はローカルでは何も実行せずリモートの出力を中継するだけなので、
        // 必ずそれより前に分岐する。--host 明示 + --dry-run は dispatchToRemoteHost が明示的に
        // 拒否する(既存どおり)ため常に解決へ進める一方、自動側(host 未指定)は dry-run のとき
        // マシン側 host を見ない(requireMachineHost: !dryRun)= ローカルで dry-run が走る。
        // 優先順位・食い違いは FTCore.MachineHostDispatch に委譲(ユーザー決定 2026-08-17)
        // デバイスが複数の機械にまたがる実行プロファイルは、ホストごとの子プロセス(`ftester api
        // run --host <label>`)へ分け、NDJSON を ApiRunHostFanout が1本へ多重化する
        // (docs/remote-runner.md §13)。--host 明示や全台が同じ機械なら nil が返り従来経路のまま。
        // --debug は子プロセスの stdin へ橋渡しする経路が無いため、ここでだけ明示的に拒否する
        // (単一ホストの --host + --debug は dispatchToRemoteHost が同様に拒否している)
        if !dryRun, let profile,
           let groups = try DeviceHostRunner.plan(
               project: testProject, profileName: profile, explicitHost: host, deviceFilter: devices) {
            if debug {
                throw ValidationError(
                    "--debug is not supported with a profile that spans multiple machines"
                    + " (\(groups.map(\.hostLabel).joined(separator: ", ")))")
            }
            let exitCode = try await ApiRunHostFanout.run(
                project: testProject, profileName: profile, groups: groups, scenarios: scenarios,
                options: ApiRunHostFanout.Options(
                    heal: heal, defaultTimeout: defaultTimeout, scenarioTimeout: scenarioTimeout,
                    noLPT: noLPT, lptHistoryRuns: lptHistoryRuns, performanceMode: performanceMode,
                    remoteDir: remoteDir, remoteTimeout: remoteTimeout, remoteArtifacts: remoteArtifacts))
            if exitCode != 0 { throw ExitCode(exitCode) }
            return
        }
        if let dispatch = try resolveEffectiveHostDispatch(
            explicitHost: host, profile: profile, project: project,
            requireMachineHost: !dryRun, warn: { logStderr($0) }) {
            try await dispatchToRemoteHost(dispatch, project: testProject)
            return
        }

        // --debug: stdin を専用スレッドで読み行をそのままランナーへ渡す。ScenarioHost.run が
        // 起動直後に onControl で渡す ScenarioRunControl を待つ必要があるため小箱経由で受け渡す
        var debugOptions: ScenarioDebugOptions?
        if debug {
            let controlBox = DebugControlBox()
            let reader = Thread {
                while let line = readLine(strippingNewline: true) {
                    controlBox.control?.sendLine(line)
                }
            }
            reader.name = "ftester-api-run-control"
            reader.start()
            debugOptions = ScenarioDebugOptions(
                breakpoints: breakpoints, pauseOnStart: pauseOnStart) { control in
                controlBox.control = control
            }
        }

        // --profile の解決は runStarted 送出前に済ませる: タイポ等の検証エラーは他の事前検証と
        // 同様 NDJSON を1行も出さず失敗させたい(runStarted だけ出て runFinished が来ない尻切れを
        // 避ける)。デバイス接続等の実行時失敗は runWithProfile 側で扱う(VSCode拡張は
        // runFinished 無しの異常終了を exit code で検知するため許容される)
        var resolvedProfile: ResolvedProfile?
        if let profile {
            let machine = try ProfileResolver.determineMachine(
                project: testProject,
                runProfileName: profile)
            if machine.auto {
                logStderr("→ Using machine profile \(machine.name) automatically (it is the only one in machines/)")
            }
            let resolvedAll = try ProfileResolver.resolve(
                project: testProject, runName: profile, machineName: machine.name,
                workspaceOverride: workspace)
            // ワークスペースは常に有効(既定 `<project.rootURL>/workspace`。docs/remote-runner.md §17・
            // 2026-08-18)なので毎回雛形作成(ProfileRunner.run と同じ規律。既に揃っていれば
            // 何もしない。リモートディスパッチは別途ミラー前のローカル側で同じ呼び出しを行う
            // = RemoteRunDispatcher.prepareWorkspace)。続けて appPath の原本を apps/ へ
            // ステージング(WorkspaceAppStaging。ProfileRunner.run と同じ規律 ——
            // dest も原本も無ければ throw する)
            if let workspaceRoot = resolvedAll.workspaceRoot {
                let created = (try? WorkspaceScaffold.ensure(root: workspaceRoot)) ?? []
                if !created.isEmpty {
                    logStderr("→ Created workspace scaffold: "
                        + created.map { "\($0)/" }.joined(separator: ", "))
                }
                let staged = try WorkspaceAppStaging.stageWorkspaceApps(resolvedAll)
                if !staged.isEmpty {
                    logStderr("→ Staged app package(s) into the workspace: "
                        + staged.joined(separator: ", "))
                }
            }
            // --device / --device-host: ApiRunHostFanout の子(ホスト別サブ実行)が自分のぶんだけを
            // 回すのに使う(ProfileRunner.run と同じ順序・同じメッセージ規律 —— ホストで絞らないと
            // 別の機械の同名デバイスまで掴む。filteringDevices の宣言)
            //
            // 明示 --host local はこの機械で走らせる指定なので、ホスト混在プロファイルでは
            // local 枠だけに絞る(他ホスト担当分まで手元で解決すると存在しない台を掴む。
            // ホスト別サブ実行は --device/--device-host を持つのでこの分岐に入らない)
            let effectiveDeviceHost = deviceHost
                ?? ((devices.isEmpty && MachineHostDispatch.isExplicitLocal(host))
                    ? DeviceHostGrouping.localDisplayName : nil)
            let full = resolvedAll.filteringDevices(names: devices, deviceHost: effectiveDeviceHost)
            // 絞り込みを指定したときだけ「合致0」を報告する。指定していないのに0台なのは
            // プロファイル自体の誤りで、それは resolve 側が自分の言葉で報告する
            if full.devices.isEmpty, !devices.isEmpty || deviceHost != nil {
                let scope = [devices.isEmpty ? nil : "--device \(devices.joined(separator: ", "))",
                             deviceHost.map { "--device-host \($0)" }]
                    .compactMap { $0 }.joined(separator: " ")
                throw ValidationError(
                    "\(scope) matched no device in run profile \(profile)"
                    + " (available: \(resolvedAll.devices.map(\.name).joined(separator: ", ")))")
            }
            // **回す本数を超える台数を用意しない**(ResolvedProfile.limitingDevices)。
            // ここではシナリオ一覧がまだ無い(ビルドと並行に解決するため。下の先行構築のコメント参照)
            // ので、**確定している情報だけ**で絞る —— 明示 ID(`Class.method`)だけの指定なら
            // 1つの ID は高々1本なので本数が決まる。クラス名指定・全件は絞らない
            // (そこは並列度が要る場面で、絞ると遅くなる)。platform はまだ分からないので両方に同じ数を使う
            let exactCount = ApiRun.exactScenarioCount(scenarios)
            let resolved = full.limitingDevices(iosScenarios: exactCount, androidScenarios: exactCount)
            if resolved.devices.count < full.devices.count {
                logStderr("→ Using \(resolved.devices.count) of \(full.devices.count) device(s)"
                    + " for \(scenarios.count) scenario(s)")
            }
            for warning in resolved.warnings { logStderr("⚠️ \(warning)") }
            if resolved.iosFastInput { setenv("FT_FAST_INPUT", "1", 1) }  // BridgeClient.fastInput 参照
            // 未指定でも必ず書く(既定の "0" を明示し、前段の値を残さない)。環境変数側で
            // 既に ON なら尊重する(`ftester run --enable-animations` と手動 export の上書き)
            let animations = resolved.enableAnimations || AnimationPolicy.animationsEnabled()
            setenv(AnimationPolicy.environmentKey, animations ? "1" : "0", 1)
            await BackendHealthCheck.warnIfUnreachable(resolved: resolved) { logStderr($0) }
            resolvedProfile = resolved
        }

        // 開始/終了スクリプト(docs/remote-runner.md §17。ProfileRunner.run と同じ規律 ——
        // デバイスに触る前に撃ち、終了スクリプトは defer で必ず撃つ)。**resolvedAll ではなく
        // 絞り込み後の resolved を渡す**(スクリプトが受け取るデバイス一覧は、この run が実際に
        // 使う台と一致していないと `adb reverse` の宛先がずれる)
        var hookSession: RunHookSession?
        if let resolved = resolvedProfile {
            let hookStateDir = (try? RepoRoot.find())?.appendingPathComponent(".ftester")
            hookSession = try RunHookRunner.begin(
                resolved: resolved, stateDir: hookStateDir) { logStderr($0) }
        }
        defer {
            if let hookSession { RunHookRunner.end(hookSession) { logStderr($0) } }
        }

        // ワーカー並列実行経路のときだけビルドと並行してワーカー(iOSブリッジ起動/Android照合+
        // インストール)を先行構築する。build/list/selected の解決が途中で throw した場合、この
        // Task は待たずプロセスごと終了してよい: detach 起動されたブリッジ(xcodebuild/simctl)は
        // 常駐資産として残り次回再利用されるため無害
        // Android(serial 照合+インストール確認=数秒)と iOS(ブリッジ供給=壊れたブリッジの
        // 置き換えで数十秒かかりうる)を分離する。Android は先行ワーカーとして即時実行を開始し、
        // iOS は RunOrchestrator の lateWorkers として供給完了後に合流する(実測: 供給待ちで
        // 全ワーカーの開始が 10s→81s に悪化した対策。2026-07-18)。
        let triageBox = BlankTriageBox()
        // 供給フェーズ(install・凍結triage)の間も run-lease を保つ。RunOrchestrator の lease は
        // シナリオ実行中しか書かれず、その手前に device-up が割り込む穴が空くため
        let supplyLease = (try? RepoRoot.find())
            .map { SupplyLeaseHolder(stateDir: $0.appendingPathComponent(".ftester")) }
        defer { supplyLease?.release() }
        let androidWorkersTask: Task<[RunWorker], Error>?
        var iosWorkersTask: Task<[RunWorker], Never>?
        if let resolvedProfile, !dryRun, debugOptions == nil {
            let resolved = resolvedProfile
            androidWorkersTask = Task {
                let deviceList = resolved.devices
                    .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
                logStderr("🧩 Profile \(resolved.runName): \(resolved.appName) @ \(resolved.machineName)")
                logStderr("   Devices: \(deviceList)")
                var wipedAndroid: [String] = []
                if resolved.wipeDataOnBloat {
                    wipedAndroid = await AndroidDataWiper.wipeBloatedAVDs(
                        devices: resolved.androidDevices,
                        thresholdGB: resolved.wipeDataThresholdGB,
                        locale: resolved.locale,
                        status: { self.emitLine(ApiWipeStatusEvent(device: $0, phase: $1)) },
                        log: { logStderr($0) })
                }
                // CPU 描画フォールバック機の GPU 復帰は buildAndroidWorkers より前(emulator
                // プロセスを入れ替えるため serial が変わりうる。Wipe Data と同じ理由・同じ位置)
                if resolved.recoverCpuFallbackToGpu {
                    _ = await AndroidGpuRecovery.recoverCpuFallbackDevices(
                        devices: resolved.androidDevices, locale: resolved.locale) { logStderr($0) }
                }
                // 死んだレーンの復活(両モード共通)。buildAndroidWorkers の直前(GPU 復帰の後)で
                // 起動していない仮想デバイスを先に起こす。復活できなかった場合の扱いは
                // performanceMode の有無で分岐する(このあとの LaneGate 判定。runWithProfileParallel 側)
                if let running = try? AndroidDeviceCatalog.runningAVDs() {
                    let laneTargets = AndroidLaneRecovery.plan(
                        devices: resolved.androidDevices, runningAVDIDs: Set(running.values))
                    if !laneTargets.isEmpty {
                        let outcome = await AndroidLaneRecovery.bootMissingDevices(
                            devices: laneTargets.map(\.device), locale: resolved.locale) { logStderr($0) }
                        // 起こせた分は、ブリッジが定着するまで待ってから先へ進む(理由は
                        // awaitDurableAndroidBridges の宣言)
                        await ProfileWorkerFactory.awaitDurableAndroidBridges(
                            devices: laneTargets.map(\.device)
                                .filter { outcome.booted.contains($0.name) }) { logStderr($0) }
                    }
                }
                await ProfileWorkerFactory.preparePhysicalAndroidDevices(
                    resolved: resolved) { logStderr($0) }
                var workers = try ProfileWorkerFactory.buildAndroidWorkers(
                    resolved: resolved) { logStderr($0) }
                supplyLease?.hold(
                    keys: workers.compactMap { $0.connection.serial ?? $0.connection.udid })
                // 凍結機は修復→不発なら guest reboot 待ちで本 run に復帰・それでも駄目な個体のみ除外
                // (CLI の ProfileRunner と同じ。全滅しても throw せず
                // 空で返す=iOS の合流を殺さない。android シナリオはワーカー不在ドレインで失敗確定)
                let triage = await ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers(
                workers, stateDir: (try? RepoRoot.find())?.appendingPathComponent(".ftester")) { logStderr($0) }
                workers = triage.workers
                triageBox.set(repaired: triage.repaired, excluded: triage.excluded)
                workers = try await ProfileWorkerFactory.installIfNeeded(
                    apps: resolved.apps, workers: workers,
                    forceAndroidInstall: !wipedAndroid.isEmpty) { logStderr($0) }
                if !workers.isEmpty {
                    logStderr("🚀 Starting with \(workers.count) Android worker(s) (iOS joins once bridge provisioning finishes)")
                }
                return workers
            }
            if !resolved.iosDevices.isEmpty {
                iosWorkersTask = Task {
                    do {
                        var workers = try await ProfileWorkerFactory.buildIOSWorkers(
                            resolved: resolved, repoRoot: try RepoRoot.find()) { logStderr($0) }
                        supplyLease?.hold(
                            keys: workers.compactMap { $0.connection.serial ?? $0.connection.udid })
                        workers = (try? await ProfileWorkerFactory.installIfNeeded(
                            apps: resolved.apps, workers: workers,
                            forceAndroidInstall: false) { logStderr($0) }) ?? workers
                        // 画面だけ死んだシミュレータを**投入前に**弾く(BlankWorkerTriage 参照)。
                        // Android は buildAndroidWorkers 直後に同等の処理(修復つき)を通している
                        let repoRoot = try RepoRoot.find()
                        workers = await BlankWorkerTriage.excludeBlankScreenWorkers(
                            workers,
                            recover: { @Sendable frozen, currentWorkers in
                                await ProfileWorkerFactory.recoverFrozenIOSWorkers(
                                    labels: frozen, workers: currentWorkers, resolved: resolved,
                                    repoRoot: repoRoot, apps: resolved.apps) { logStderr($0) }
                            },
                            // 判定をモニターへ配る(DeviceFrozenStore)。run が知っている凍結を
                            // モニターが知らない状態を作らないための唯一の口
                            stateDir: repoRoot.appendingPathComponent(".ftester"),
                            nudge: { @Sendable [bundleID = ProfileWorkerFactory.iosBundleID(apps: resolved.apps)] in
                                await ProfileWorkerFactory.nudgeIOSScreen(worker: $0, restoring: bundleID) },
                            log: { logStderr($0) }).workers
                        await ProfileWorkerFactory.pressHomeOnStart(
                            workers, enabled: resolved.homeOnStart) { logStderr($0) }
                        logStderr("🚀 \(workers.count) iOS worker(s) joined")
                        return workers
                    } catch {
                        // iOS 供給失敗は run 全体を落とさない(iOS シナリオはワーカー不在として
                        // ドレインで失敗確定し、Android の結果は生きる)
                        logStderr("❌ Failed to build iOS workers: \(error.localizedDescription)")
                        return []
                    }
                }
            }
        } else {
            androidWorkersTask = nil
        }

        // ビルドはホスト側で 1 回だけ(サブプロセスは自らビルドしない)
        if !skipBuild {
            logStderr("→ Building scenarios (\(testProject.name))...")
            try ScenarioHost.build(project: testProject) { logStderr($0) }
        }

        let all = try ScenarioHost.list(project: testProject)
        guard !all.isEmpty else {
            throw ValidationError(
                "no scenarios (add a @TestClass under TestProjects/\(testProject.name)/scenarios/)")
        }
        let selected = try RunScenarios.resolve(scenarios, from: all)
        guard !selected.isEmpty else {
            throw ValidationError("nothing to run (every scenario is marked @Deleted)")
        }

        // dry-run/debug は実測にならない(dry-run はデバイス未接続、debug は人間介入前提)ため記録しない
        let recorder: RunRecorder? = (!dryRun && debugOptions == nil)
            ? RunRecorder.begin(project: testProject, profile: profile, trigger: "api")
            : nil

        emitLine(ApiRunStartedEvent(total: selected.count))

        var outcome: RunOutcome
        if let resolvedProfile {
            // --dry-run/--debug は単純な逐次実行のまま(worker フィールド無し)。それ以外は
            // RunOrchestrator による並列実行
            if dryRun || debugOptions != nil {
                outcome = try await runWithProfile(
                    resolved: resolvedProfile, project: testProject, selected: selected,
                    debugOptions: debugOptions, recorder: recorder)
            } else {
                let androidWorkers = try await androidWorkersTask!.value
                // performanceMode では iOS の late join をやめて開始前に建てる。**理由は計測の
                // 歪みではなくゲートの可視性**(ProfileRunner の同じ箇所のコメント参照)。
                // iosWorkersTask は既に走っているので新しい実装は要らず、待つタイミングを
                // 早めるだけ(2つ目の実装を書かない)
                var eagerIOSWorkers: [RunWorker] = []
                var effectiveIosWorkersTask = iosWorkersTask
                if performanceMode, let task = iosWorkersTask {
                    eagerIOSWorkers = await task.value
                    effectiveIosWorkersTask = nil
                }
                // performanceMode: 復活できなかったレーンがあれば run を開始せずに失敗する
                // (既定 false ではここへ来ない=切り離して完走を優先する従来どおりの挙動)
                if performanceMode {
                    let missingAndroid = LaneGate.missing(
                        expected: resolvedProfile.androidDevices.map(\.name),
                        actual: androidWorkers.compactMap(\.logicalName))
                    let missingIOS = resolvedProfile.iosDevices.isEmpty ? [] : LaneGate.missing(
                        expected: resolvedProfile.iosDevices.map(\.name),
                        actual: eagerIOSWorkers.compactMap(\.logicalName))
                    let missing = missingAndroid + missingIOS
                    if !missing.isEmpty {
                        throw ProfileWorkerFactory.InstallError(
                            message: "performance mode: \(missing.count) device(s) could not be "
                                + "started (\(missing.joined(separator: ", "))). Fix the devices, "
                                + "or turn performanceMode off to run on the remaining lanes.")
                    }
                }
                outcome = try await runWithProfileParallel(
                    resolved: resolvedProfile, project: testProject, selected: selected,
                    workers: androidWorkers + eagerIOSWorkers, iosWorkersTask: effectiveIosWorkersTask,
                    recorder: recorder)
            }
        } else {
            outcome = await runDirect(
                project: testProject, selected: selected, debugOptions: debugOptions,
                recorder: recorder)
        }

        // 並列経路の triage は box 経由(sequential 経路は outcome に設定済みのため二重加算しない)
        let boxTriage = triageBox.get()
        if outcome.blankRepairs.isEmpty { outcome.blankRepairs = boxTriage.repaired }
        if outcome.blankExclusions.isEmpty { outcome.blankExclusions = boxTriage.excluded }
        // performanceMode: レーン数が run 中に変わっていたら所要時間は計測に使えない
        // (MeasurementValidity の宣言参照。既定モードは判定しない=印を付けない)
        let validity = MeasurementValidity.verdict(
            performanceMode: performanceMode,
            degradedWorkers: outcome.degradedWorkers, blankExclusions: outcome.blankExclusions)
        recorder?.finish(total: selected.count, passed: outcome.passed, failed: outcome.failed,
                         degradedWorkers: outcome.degradedWorkers,
                         freezeRetries: outcome.freezeRetries,
                         blankRepairs: outcome.blankRepairs,
                         blankExclusions: outcome.blankExclusions,
                         measurementInvalid: validity.invalid,
                         measurementInvalidReasons: validity.reasons)
        if !outcome.degradedWorkers.isEmpty {
            logStderr("⚠️ Degraded or dropped workers (\(outcome.degradedWorkers.count)):")
            for entry in outcome.degradedWorkers { logStderr("   - \(entry)") }
        }
        if !outcome.freezeRetries.isEmpty {
            logStderr("🔁 Results discarded and requeued (\(outcome.freezeRetries.count)):")
            for entry in outcome.freezeRetries { logStderr("   - \(entry)") }
        }
        if validity.invalid {
            logStderr("⏱️❌ Measurement invalid: this run's timing cannot be used for performance"
                + " comparisons (\(validity.reasons.joined(separator: "; ")))")
        }
        emitLine(ApiRunFinishedEvent(passed: outcome.passed, failed: outcome.failed,
                                     testSeconds: outcome.testSeconds,
                                     scenarioTotalSeconds: outcome.scenarioTotalSeconds))

        if outcome.failed > 0 {
            throw ExitCode(1)
        }
    }

    // MARK: - --host(拡張連携用 NDJSON 中継。docs/remote-runner.md §3・§12)

    /// リモート `ftester api run` の NDJSON を stdout へそのまま中継する。stdin 制御系
    /// (--debug)・ローカル専用系(--dry-run 等)はリモートでは意味を持たない/中継されないため
    /// 併用不可にする。--profile は既存の platform/port/serial 排他チェックで担保済みなので
    /// ここでは個別に確認しない
    private func dispatchToRemoteHost(_ dispatch: EffectiveHostDispatch, project: TestProject) async throws {
        guard let profile else {
            throw ValidationError("--host requires --profile")
        }
        if debug {
            throw ValidationError("--debug is not supported with --host")
        }
        if !breakpoints.isEmpty {
            throw ValidationError("--breakpoint is not supported with --host")
        }
        if pauseOnStart {
            throw ValidationError("--pause-on-start is not supported with --host")
        }
        if dryRun {
            throw ValidationError("--dry-run is not supported with --host")
        }
        // 拒否 or 注記の分岐は FTCore.RemoteDispatchFlagPolicy に委譲(欠陥1)。VSCode 拡張は
        // 設定 ftester.buildBeforeRun: false のとき常に --skip-build を送るため、マシンプロファイル
        // 由来の自動ディスパッチ(origin = .autoDispatch)にそのまま適用すると、利用者が打っていない
        // フラグを理由に必ず落ちる。自動側は注記のみで無視する(リモートは常に自前でビルドする)
        let origin = dispatch.origin
        if reportDir != nil {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--report-dir", origin: origin))
        }
        if skipBuild {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.skipBuild(origin: origin))
        }

        let resolved = try resolveRemoteTarget(dispatch, remoteDirOverride: remoteDir)
        // stdout は NDJSON 専用の契約(RemoteRunDispatcher.log の apiRun 分岐と同じ規律)なので、
        // アナウンスは stderr へ出す
        resolved.announce(toStderr: true)
        let artifactsMode = try RemoteArtifactsMode.parse(remoteArtifacts)
        let localRoot = try RepoRoot.find()
        let dispatcher = RemoteRunDispatcher(
            host: resolved.hostSpec, remoteDirRaw: resolved.remoteDirRaw, localRepoRoot: localRoot,
            mode: .apiRun, artifacts: artifactsMode, hostLabel: dispatch.rawHost)
        var scopedDevices = devices
        var scopedDeviceHost = deviceHost
        if devices.isEmpty, deviceHost == nil {
            (scopedDevices, scopedDeviceHost) = try hostScopedDeviceFilter(
                project: project, profile: profile, targetHost: dispatch.rawHost)
        }
        let exitCode = try await dispatcher.dispatchApi(
            project: project, profile: profile, scenarios: scenarios,
            deviceNames: scopedDevices, deviceHost: scopedDeviceHost,
            heal: heal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            performanceMode: performanceMode,
            defaultTimeout: defaultTimeout, scenarioTimeout: scenarioTimeout.map(Double.init),
            remoteTimeoutSeconds: remoteTimeout)
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    // MARK: - --platform/--port/--serial 直接指定(--profile 未指定)

    private func runDirect(project: TestProject, selected: [ScenarioInfo],
                           debugOptions: ScenarioDebugOptions?,
                           recorder: RunRecorder?) async -> RunOutcome {
        let effectivePlatform = platform ?? "ios"
        let effectivePort = port ?? BridgeAPI.defaultPort
        let reportDirPath = reportDir ?? project.reportsDir.path

        var passedCount = 0
        var failedCount = 0
        var timing = ScenarioTimingTracker()
        for info in selected {
            let scenarioPlatform = info.platform ?? effectivePlatform
            let connection = scenarioPlatform == "android"
                ? DriverConnection(platform: "android", serial: serial)
                : DriverConnection(platform: "ios", port: effectivePort)
            // --platform/--port/--serial 直指定経路にはデバイス論理名が無いため worker は nil
            let recording = recorder.map { ScenarioRecording(recorder: $0, title: info.title) }

            let scenarioStart = Date()
            let passed = await ScenarioHost.run(
                project: project, scenarioID: info.id, connection: connection,
                fm: FMConfig(heal: heal), reportDir: reportDirPath, defaultTimeout: defaultTimeout,
                scenarioTimeout: scenarioTimeout,
                dryRun: dryRun, debug: debugOptions, recording: recording) { event in
                // host 発の log イベント等、scenario 未設定のものは現在のシナリオ ID を補う
                var event = event
                if event.scenario == nil { event.scenario = info.id }
                writeLine(event.encodedLine())
            }
            let scenarioEnd = Date()
            timing.recordSequential(start: scenarioStart, finish: scenarioEnd)
            if passed { passedCount += 1 } else { failedCount += 1 }
        }
        return RunOutcome(passed: passedCount, failed: failedCount,
                          testSeconds: timing.testSeconds,
                          scenarioTotalSeconds: timing.scenarioTotalSeconds)
    }

    // MARK: - --profile 指定

    /// resolved のワーカーを構築し、各シナリオを platform に合う最初のワーカーで逐次実行する
    /// (ProfileRunner と違い並列化しない)。--dry-run はワーカー構築自体を省略し、
    /// defaultTimeout/heal の反映だけ行って NullDriver で流す
    private func runWithProfile(
        resolved: ResolvedProfile, project: TestProject,
        selected: [ScenarioInfo], debugOptions: ScenarioDebugOptions?,
        recorder: RunRecorder?
    ) async throws -> RunOutcome {
        let profileName = resolved.runName
        // --heal は master(fm.enabled)が有効な場合のみ heal を ON にする(false は resolved の値を維持)
        var fm = resolved.fm
        if heal { fm.heal = fm.enabled }
        // dry-run は FM を使わないため警告(と実呼び出し ~1s)を抑止する
        await ProfileRunner.warnIfHealDegraded(heal: fm.heal && !dryRun) { logStderr($0) }
        let reportDirPath = (reportDir.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir).path

        var blankTriage: (repaired: [String], excluded: [String]) = ([], [])
        var workers: [RunWorker] = []
        // 供給フェーズ(install・凍結triage)の間も run-lease を保つ(理由は並列経路の同処理を参照)
        let supplyLease = (try? RepoRoot.find())
            .map { SupplyLeaseHolder(stateDir: $0.appendingPathComponent(".ftester")) }
        defer { supplyLease?.release() }
        if !dryRun {
            let deviceList = resolved.devices
                .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
            logStderr("🧩 Profile \(profileName): \(resolved.appName) @ \(resolved.machineName)")
            logStderr("   Devices: \(deviceList)")
            var wipedAndroid: [String] = []
            if resolved.wipeDataOnBloat {
                wipedAndroid = await AndroidDataWiper.wipeBloatedAVDs(
                    devices: resolved.androidDevices,
                    thresholdGB: resolved.wipeDataThresholdGB,
                    locale: resolved.locale,
                    status: { self.emitLine(ApiWipeStatusEvent(device: $0, phase: $1)) },
                    log: { logStderr($0) })
            }
            // GPU 復帰は buildWorkers より前(理由は並列経路の同処理を参照)
            if resolved.recoverCpuFallbackToGpu {
                _ = await AndroidGpuRecovery.recoverCpuFallbackDevices(
                    devices: resolved.androidDevices, locale: resolved.locale) { logStderr($0) }
            }
            workers = try await ProfileWorkerFactory.buildWorkers(
                resolved: resolved, repoRoot: try RepoRoot.find()) { logStderr($0) }
            supplyLease?.hold(
                keys: workers.compactMap { $0.connection.serial ?? $0.connection.udid })
            // android は修復→guest reboot 待ちで本 run に復帰・それでも駄目な個体のみ除外
            let triage = await ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers(
                workers, stateDir: (try? RepoRoot.find())?.appendingPathComponent(".ftester")) { logStderr($0) }
            workers = triage.workers
            // iOS も **shutdown → boot → ブリッジ張り直し**で回復を試み、駄目な個体だけ除外する
            // (BlankWorkerTriage 参照)。**この経路にも通すこと** ——
            // iOS ワーカーの供給口は「遅延合流(lateWorkers)」とここの2つで、片方だけだと穴が空く
            let iosRepoRoot = try RepoRoot.find()
            let iosWorkers = workers
            let iosTriage = await BlankWorkerTriage.excludeBlankScreenWorkers(
                workers,
                recover: { @Sendable frozen, currentWorkers in
                    await ProfileWorkerFactory.recoverFrozenIOSWorkers(
                        labels: frozen, workers: currentWorkers, resolved: resolved,
                        repoRoot: iosRepoRoot, apps: resolved.apps) { logStderr($0) }
                },
                stateDir: iosRepoRoot.appendingPathComponent(".ftester"),
                            nudge: { @Sendable [bundleID = ProfileWorkerFactory.iosBundleID(apps: resolved.apps)] in
                                await ProfileWorkerFactory.nudgeIOSScreen(worker: $0, restoring: bundleID) },
                log: { logStderr($0) })
            workers = iosTriage.workers
            await ProfileWorkerFactory.pressHomeOnStart(
                workers, enabled: resolved.homeOnStart) { logStderr($0) }
            blankTriage = (triage.repaired, triage.excluded + iosTriage.excluded)
            workers = try await ProfileWorkerFactory.installIfNeeded(
                apps: resolved.apps, workers: workers,
                forceAndroidInstall: !wipedAndroid.isEmpty) { logStderr($0) }
        }

        // シナリオが platform 未指定のときの既定 platform(iOS ワーカーがあれば ios 優先。
        // dry-run はワーカーを構築しないため resolved のデバイス構成から同じ方針で決める)
        let defaultPlatform: String = dryRun
            ? (resolved.iosDevices.isEmpty ? "android" : "ios")
            : (workers.contains { $0.platform == "ios" } ? "ios" : "android")

        var passedCount = 0
        var failedCount = 0
        var timing = ScenarioTimingTracker()
        for info in selected {
            let scenarioPlatform = info.platform ?? defaultPlatform

            let connection: DriverConnection
            let recordingWorker: String?
            if dryRun {
                connection = DriverConnection(platform: scenarioPlatform)
                recordingWorker = nil
            } else if let worker = workers.first(where: { $0.platform == scenarioPlatform }) {
                connection = worker.connection
                // id 形式は workersReadyInfo/workerID(runWithProfileParallel)と同一規則
                recordingWorker = "\(worker.platform):\(worker.logicalName ?? worker.label)"
            } else {
                let workerList = workers.isEmpty
                    ? "none" : workers.map(\.label).joined(separator: ", ")
                let reason = "no worker matches platform \"\(scenarioPlatform)\""
                    + " (workers in profile \(profileName): \(workerList))"
                logStderr("⚠️ \(info.id): \(reason)")
                emitMissingWorkerFailure(info: info, reason: reason)
                recorder?.recordSkipped(scenarioID: info.id, title: info.title,
                                        platform: scenarioPlatform, worker: nil, reason: reason)
                failedCount += 1
                continue
            }
            let recording = recorder.map {
                ScenarioRecording(recorder: $0, worker: recordingWorker, title: info.title)
            }

            let scenarioStart = Date()
            // この経路(--dry-run/--debug)は installHandler(RPC)を配線しない — dry-run はデバイスに
            // 触らず installApp() 自体を通過しない、debug は人間介入前提の単発実行のため。appPath だけ
            // フォールバックとして渡し、installApp() 引数省略時に子が直接インストールできるようにする
            let passed = await ScenarioHost.run(
                project: project, scenarioID: info.id, connection: connection,
                fm: fm, reportDir: reportDirPath,
                defaultTimeout: resolved.defaultTimeout,
                containerInference: resolved.containerInference,
                scenarioTimeout: resolved.scenarioTimeout, dryRun: dryRun,
                debug: debugOptions, recording: recording,
                appPath: dryRun ? nil : resolved.apps[scenarioPlatform]?.appPath,
                appName: resolved.appName) { event in
                var event = event
                if event.scenario == nil { event.scenario = info.id }
                writeLine(event.encodedLine())
            }
            let scenarioEnd = Date()
            timing.recordSequential(start: scenarioStart, finish: scenarioEnd)
            if passed { passedCount += 1 } else { failedCount += 1 }
        }
        return RunOutcome(passed: passedCount, failed: failedCount,
                          testSeconds: timing.testSeconds,
                          scenarioTotalSeconds: timing.scenarioTotalSeconds,
                          blankRepairs: blankTriage.repaired,
                          blankExclusions: blankTriage.excluded)
    }

    // MARK: - --profile 指定(ワーカー並列実行。--dry-run/--debug 以外)

    /// 全ワーカーを RunOrchestrator(FTCore)に渡し ProfileRunner と同じ並列度で実行する。
    /// 進捗は RunEvent(Codable ではない)で届くため ndjsonLines(for:itemByURL:workerID:) で
    /// ScenarioEvent 相当の NDJSON 行に変換する(失われる情報がある点に注意)。
    /// workers はビルドと並行して呼び出し側(run())が先行構築済みのもの
    private func runWithProfileParallel(
        resolved: ResolvedProfile, project: TestProject, selected: [ScenarioInfo],
        workers: [RunWorker], iosWorkersTask: Task<[RunWorker], Never>?, recorder: RunRecorder?
    ) async throws -> RunOutcome {
        let repoRoot = try RepoRoot.find()
        // --heal は master(fm.enabled)が有効な場合のみ heal を ON にする(false は resolved の値を維持)
        var fm = resolved.fm
        if heal { fm.heal = fm.enabled }
        await ProfileRunner.warnIfHealDegraded(heal: fm.heal) { logStderr($0) }
        let reportDirURL = reportDir.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir

        // workersReady はレーン構成の全置換(同一 id のログは維持。複数回出してよい ——
        // ApiRunHostFanout は累積再送する)。単体実行は1回・全ワーカー分を宣言する。iOS はブリッジ
        // 供給前でも id("ios:論理名")が確定するので、供給待ちを表す detail 付きのプレースホルダで
        // 先に載せる(port は表示のみの情報)。
        var readyInfo = workersReadyInfo(workers)
        if iosWorkersTask != nil {
            readyInfo += resolved.iosDevices.map {
                ApiWorkerInfo(id: "ios:\($0.name)", name: $0.name, platform: "ios",
                              detail: "provisioning the bridge...")
            }
        }
        emitLine(ApiWorkersReadyEvent(workers: readyInfo))

        // シナリオが platform 未指定のときの既定 platform(既存の runWithProfile と同じ方針。
        // iOS は遅延参加のため resolved 側で判定する)
        let defaultPlatform = (!resolved.iosDevices.isEmpty
            || workers.contains { $0.platform == "ios" }) ? "ios" : "android"

        // 長いシナリオを先に流すと末尾の遊休が減る(LPTOrdering。--no-lpt で従来の ID 順)
        let items = LPTOrdering.apply(selected.map { ScenarioRunItem(info: $0) },
                                      project: project, defaultPlatform: defaultPlatform,
                                      enabled: !noLPT,
                                      historyRuns: lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns,
                                      log: { logStderr($0) })
        // RunEvent の flowURL(scenario:// URL)→ 元の ScenarioInfo の逆引き。
        // RunEvent は scenario ID・title を毎回運んでくれないため、変換時にここから補う
        let itemByURL = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0) })
        // RunEvent の worker(= RunWorker.label)→ workersReady と同じ id 文字列への変換表。
        // iOS ワーカーは遅延参加(lateWorkers)で後から merge されるためロック付きの箱にする
        let workerID = WorkerIDMap(workers)

        // run-lease(.ftester/run-<key>.lease)。best-effort: リポジトリ外実行等で root が
        // 取れない場合は書かない(monitor 側の inRun 判定が false になるだけで安全)
        let leaseStateDir = (try? RepoRoot.find())?.appendingPathComponent(".ftester")

        // record:true のときだけ VideoRecordingConfig を注入(runDir が無ければ録画自体しない)
        let recordingConfig: VideoRecordingConfig? = {
            guard resolved.record, let recorder else { return nil }
            return VideoRecordingConfig(
                runDir: recorder.runDir, androidADBPath: try? AndroidDriver.findADB(),
                failuresOnly: resolved.recordFailuresOnly, bitrateKbps: resolved.recordBitrateKbps,
                fullResolution: resolved.recordFullResolution)
        }()

        let orchestrator = RunOrchestrator(
            project: project, workers: workers, fm: fm,
            reportDir: reportDirURL, defaultTimeout: resolved.defaultTimeout,
            containerInference: resolved.containerInference,
            scenarioTimeout: resolved.scenarioTimeout, recorder: recorder,
            recordingConfig: recordingConfig,
            isDeviceFrozen: { serial in
                // 事後判定は isBlankObserved(窓内に一度でも blank)。isPersistentlyBlank だと
                // 約25秒周期のフラッピングの回復側を引いて凍結を見逃す(実測 2026-07-18)。
                // 凍結確定時はその場で sleep/wake 修復も試みる(判定・振り直しは従来どおり)
                await AndroidHealthProbe.observeBlankAndRepair(serial: serial) { logStderr($0) }
            },
            isDeviceUnreachable: { serial in
                // adb で state=device の一覧に居なければ消失(offline/未検出)。取得失敗時は誤って
                // 振り直さないよう false(reachable 扱い)に倒す。
                guard let serials = try? AndroidDeviceCatalog.connectedSerials() else { return false }
                return !serials.contains(serial)
            },
            bridgeLogSize: { worker in
                // xcuitest ランナーのログのみ有効(hybrid は xcuiPort 側。in-app はホスト側ログが
                // AX 処理で成長しないため nil を返して /status のみの判定にフォールバックさせる)
                guard let port = worker.connection.xcuiPort
                    ?? ((worker.connection.engine == nil || worker.connection.engine == "xcuitest")
                        ? worker.connection.port : nil) else { return nil }
                let attrs = try? FileManager.default.attributesOfItem(
                    atPath: repoRoot.appendingPathComponent(".ftester/bridge-\(port).log").path)
                return (attrs?[.size] as? NSNumber)?.uint64Value
            },
            probeBridge: { worker in
                // hybrid の主ポート(in-app)は別アプリのシナリオ中サスペンドされ TCP 受理・HTTP
                // 無応答になる(design §8.8)ため、死活確認は suspend されない xcuitest 側で行う
                guard let port = worker.connection.xcuiPort ?? worker.connection.port else {
                    return .silent
                }
                do {
                    // 実機ブリッジは 127.0.0.1 に居ない。宛先は DriverConnection 経由で届く
                    // (取り違えると失敗のたびに健全な実機ワーカーを「接続不能」で離脱させる)
                    _ = try await BridgeClient(
                        port: port,
                        host: worker.connection.host ?? BridgeEndpoint.loopbackHost)
                        .status(timeout: 5)
                    return .ok
                } catch DriverError.bridgeConnectionRefused {
                    return .refused
                } catch {
                    return .silent
                }
            },
            writeRunLease: { key in
                guard let leaseStateDir else { return }
                RunLease.write(stateDir: leaseStateDir, key: key, pid: ProcessInfo.processInfo.processIdentifier)
            },
            removeRunLease: { key in
                guard let leaseStateDir else { return }
                RunLease.remove(stateDir: leaseStateDir, key: key)
            },
            writeRecordingLease: { key in
                guard let leaseStateDir else { return }
                RecordingLease.write(stateDir: leaseStateDir, key: key,
                                     pid: ProcessInfo.processInfo.processIdentifier)
            },
            removeRecordingLease: { key in
                guard let leaseStateDir else { return }
                RecordingLease.remove(stateDir: leaseStateDir, key: key)
            },
            cleanupRetiredWorker: { retired in
                // ウェッジした旧ブリッジ(/status 無応答)は provision の再利用スキャンに映らないまま
                // 生き残り、シミュレータを掴み続ける。離脱検知の時点で UDID 照合で明示停止する
                // (revive 内でなくここに置く理由: 復帰を試みない離脱でも必ず kill するため)
                guard let udid = retired.connection.udid else { return }  // udid は iOS のみ
                let stopped = BridgeLauncher.stopMatching(udid: udid, repoRoot: repoRoot)
                if !stopped.isEmpty {
                    logStderr("🔧 Stopped stale bridges: port \(stopped.joined(separator: ", "))")
                }
            },
            reviveWorker: { retired in
                guard let name = retired.logicalName else { return nil }
                let deadline = Date().addingTimeInterval(Self.REVIVE_TIMEOUT)
                while Date() < deadline {
                    if let w = await ProfileWorkerFactory.buildWorker(forLogicalName: name, resolved: resolved,
                                                                       repoRoot: repoRoot, log: { logStderr($0) }) {
                        let installed = (try? await ProfileWorkerFactory.installIfNeeded(
                            apps: resolved.apps, workers: [w], forceAndroidInstall: false) { logStderr($0) }) ?? [w]
                        let revived = installed.first ?? w
                        // revive でブリッジポートが変わると label も変わる。stable id 変換表へ登録しないと
                        // 以後の step/log 等の NDJSON worker が workersReady の id と不一致になる(lateWorkers と同処理)。
                        workerID.merge([revived])
                        return revived
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                return nil
            },
            lateWorkers: iosWorkersTask.map { task in
                (platforms: Set(["ios"]), provider: { @Sendable in
                    let ws = await task.value
                    workerID.merge(ws)
                    return ws
                })
            },
            installHandler: InstallHandlerFactory.make(apps: resolved.apps),
            appName: resolved.appName)
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        var timing = ScenarioTimingTracker()
        for await event in orchestrator.events {
            timing.record(event)
            for line in Self.ndjsonLines(for: event, itemByURL: itemByURL, workerID: workerID) {
                writeLine(line)
            }
        }

        let result = await summary
        return RunOutcome(passed: result.passed, failed: result.failed,
                          testSeconds: timing.testSeconds,
                          scenarioTotalSeconds: timing.scenarioTotalSeconds,
                          degradedWorkers: result.degradedWorkers,
                          freezeRetries: result.freezeRetries)
    }

    /// workersReady の devices 配列を組み立てる(id 形式は ApiWorkersReadyEvent 参照)
    private func workersReadyInfo(_ workers: [RunWorker]) -> [ApiWorkerInfo] {
        workers.map { worker in
            let name = worker.logicalName ?? worker.label
            let detail: String
            switch worker.platform {
            case "ios":
                detail = worker.connection.port.map { "port \($0)" } ?? ""
            case "android":
                detail = worker.connection.serial.map { "serial \($0)" } ?? ""
            default:
                detail = ""
            }
            return ApiWorkerInfo(id: "\(worker.platform):\(name)", name: name,
                                 platform: worker.platform, detail: detail)
        }
    }

    /// RunEvent 1件 → NDJSON 行(0〜複数行)。逐次実行時の ScenarioEvent と同じ kind・
    /// フィールド名を保ち "worker" を追加する。RunEvent の scene/sceneTitle/section/status
    /// (passedViaFallback・healed含む)は StepResult の構造化フィールドのまま運ばれるため
    /// そのまま復元できる:
    /// - "sceneStarted"/"sceneFinished" は RunEvent の同名ケースから合成
    /// - "step" の scene/sceneTitle/section は StepResult の同名フィールドから写す
    /// - status "passedViaFallback"/"healed" は丸めず同名文字列のまま出し、detail に
    ///   FlowLocator.summary(サブプロセス発の raw テキスト)を入れる
    /// - fixSuggestion に伴う合成 step(StepResult.synthetic == true)は次の .fixSuggestion で
    ///   kind:"fixSuggestion" として別途出すためここでは除外する
    // 拡張との NDJSON 契約そのもの(vscode-ftester/src/model.ts・runReducer.ts が対向)。
    // 純関数なので static。FTesterTests が RunEvent → 行の写像を全 kind ぶん固めている。
    static func ndjsonLines(
        for event: RunEvent, itemByURL: [URL: ScenarioRunItem], workerID: WorkerIDMap
    ) -> [String] {
        switch event {
        case .runStarted, .workerReady, .runFinished, .flowHealed, .flowPaused:
            // runStarted/runFinished は呼び出し側で emit 済み。flowHealed は現行シナリオでは
            // 発生しない旧互換。flowPaused はデバッグ専用でこの並列経路には来ない
            return []

        case .sceneStarted(let worker, let flowURL, let scene, let sceneTitle):
            var started = ScenarioEvent(kind: "sceneStarted")
            started.worker = workerID.id(for: worker)
            started.scenario = itemByURL[flowURL]?.info.id
            started.scene = scene
            started.sceneTitle = sceneTitle
            return [started.encodedLine()]

        case .sceneFinished(let worker, let flowURL, let scene, let sceneTitle, let passed):
            var finished = ScenarioEvent(kind: "sceneFinished")
            finished.worker = workerID.id(for: worker)
            finished.scenario = itemByURL[flowURL]?.info.id
            finished.scene = scene
            finished.sceneTitle = sceneTitle
            finished.passed = passed
            return [finished.encodedLine()]

        case .workerFailed(let worker, let message):
            var log = ScenarioEvent(kind: "log")
            log.worker = workerID.id(for: worker)
            log.message = "❌ Worker \(log.worker ?? worker) dropped out: \(message)"
            return [log.encodedLine()]

        case .workerLog(let worker, let message):
            // ワーカー復帰の進行メッセージ。既存の "log" kind で流す(レーン/Test Explorer 出力に表示)
            var log = ScenarioEvent(kind: "log")
            log.worker = workerID.id(for: worker)
            log.message = message
            return [log.encodedLine()]

        case .flowRequeued(let worker, let flowURL, let reason, let attempt, let limit):
            // 振り直し通知。Test Explorer は該当項目を「待機中」アイコンへ戻す
            // (契約: vscode-ftester/src/model.ts ScenarioRequeuedEvent / runReducer の "requeued")
            guard let scenario = itemByURL[flowURL]?.info.id else { return [] }
            guard let data = try? JSONEncoder().encode(ApiScenarioRequeuedEvent(
                scenario: scenario, worker: workerID.id(for: worker),
                reason: reason, attempt: attempt, limit: limit)),
                let text = String(data: data, encoding: .utf8) else { return [] }
            return [text]


        case .flowStarted(let worker, let flowURL, let flowName, _):
            var started = ScenarioEvent(kind: "scenarioStarted")
            started.worker = workerID.id(for: worker)
            started.scenario = flowName
            started.title = itemByURL[flowURL]?.info.title
            return [started.encodedLine()]

        case .step(let worker, let flowURL, let result):
            // fixSuggestion に付随する合成 step(ScenarioRunner.runOne 参照)は次の
            // .fixSuggestion で kind:"fixSuggestion" として出すため重複emitを避けて捨てる
            if result.synthetic { return [] }

            let workerIDValue = workerID.id(for: worker)
            let scenario = itemByURL[flowURL]?.info.id
            // index 0 は log イベント由来の情報行の目印(ScenarioRunner.runOne の case "log" 参照)
            if result.index == 0 {
                var log = ScenarioEvent(kind: "log")
                log.worker = workerIDValue
                log.scenario = scenario
                log.message = result.description
                return [log.encodedLine()]
            }

            var step = ScenarioEvent(kind: "step")
            step.worker = workerIDValue
            step.scenario = scenario
            step.index = result.index
            step.scene = result.scene
            step.sceneTitle = result.sceneTitle
            step.section = result.section
            // "[section] " 等は section フィールド側にあるため description には埋め込まない
            step.description = result.description
            switch result.status {
            case .passed:
                step.status = "passed"
            case .passedViaFallback(let locator):
                step.status = "passedViaFallback"
                step.detail = locator.summary
            case .healed(let locator):
                step.status = "healed"
                step.detail = locator.summary
            case .failed(let reason):
                step.status = "failed"
                step.detail = reason
            case .skipped(let reason):
                step.status = "skipped"
                step.detail = reason
            case .inconclusive(let reason):
                step.status = "inconclusive"
                step.detail = reason
            }
            // 時間内訳(RunOrchestrator.swift の ScenarioRunner.stepResult(from:) から復元済み)
            step.durationMs = result.timing?.durationMs
            step.snapshotMs = result.timing?.snapshotMs
            step.actionMs = result.timing?.actionMs
            step.waitMs = result.timing?.waitMs
            step.at = result.at
            return [step.encodedLine()]

        case .fixSuggestion(let worker, _, let scenarioID, let command, let file, let line,
                            let oldSelector, let newSelector, let message):
            var suggestion = ScenarioEvent(kind: "fixSuggestion")
            suggestion.worker = workerID.id(for: worker)
            suggestion.scenario = scenarioID
            suggestion.description = command
            suggestion.file = file
            suggestion.line = line
            suggestion.oldSelector = oldSelector
            suggestion.newSelector = newSelector
            suggestion.detail = message
            return [suggestion.encodedLine()]

        case .flowFinished(let worker, let flowURL, let passed, _, let reportURL, let fm):
            var finished = ScenarioEvent(kind: "scenarioFinished")
            finished.worker = workerID.id(for: worker)
            finished.scenario = itemByURL[flowURL]?.info.id
            finished.passed = passed
            finished.reportPath = reportURL?.path
            // 再構築なので明示的に写す(落とすとモニターの FM グラフが 0 のままになる。実害あり)
            finished.fm = fm
            return [finished.encodedLine()]

        case .flowSkipped(let flowURL, let reason):
            // 担当ワーカーが無い/全滅したシナリオ。emitMissingWorkerFailure と同形のイベント列を
            // 合成する(worker フィールドは付けない)
            let info = itemByURL[flowURL]?.info
            var started = ScenarioEvent(kind: "scenarioStarted")
            started.scenario = info?.id
            started.title = info?.title

            var step = ScenarioEvent(kind: "step")
            step.scenario = info?.id
            step.description = "worker not found"
            step.status = "failed"
            step.detail = reason

            var finished = ScenarioEvent(kind: "scenarioFinished")
            finished.scenario = info?.id
            finished.passed = false

            return [started, step, finished].map { $0.encodedLine() }
        }
    }

    /// 担当ワーカーが無いシナリオを scenarioFinished passed=false 相当のイベント列として
    /// stdout に流す(NDJSON 契約を保ったまま runFinished の failed に計上させるため)
    private func emitMissingWorkerFailure(info: ScenarioInfo, reason: String) {
        var started = ScenarioEvent(kind: "scenarioStarted")
        started.scenario = info.id
        started.title = info.title
        writeLine(started.encodedLine())

        var step = ScenarioEvent(kind: "step")
        step.scenario = info.id
        step.description = "worker not found"
        step.status = "failed"
        step.detail = reason
        writeLine(step.encodedLine())

        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.scenario = info.id
        finished.passed = false
        writeLine(finished.encodedLine())
    }

    private func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        writeLine(line)
    }

    /// stdout への 1 行書き込みをロックで直列化する(--profile 並列実行時は複数ワーカーの
    /// イベントが並行して届きうるため。行の途中で他の書き込みが割り込むと NDJSON が壊れる)。
    /// 逐次実行経路も同じ関数を通すが、単一スレッドからの呼び出しのみなので実害はない
    private func writeLine(_ line: String) {
        Self.stdoutLock.lock()
        defer { Self.stdoutLock.unlock() }
        print(line)
    }

    private static let stdoutLock = NSLock()

    /// ワーカー復帰待ちの上限。監視側の再起動やデバイス自己回復を待つ
    private static let REVIVE_TIMEOUT: TimeInterval = 90

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// RemoteDispatchFlagPolicy.Decision の適用。stdout は NDJSON 専用の契約なので注記も stderr へ
    /// (dispatchToRemoteHost の announce と同じ規律)
    private func applyFlagPolicy(_ decision: RemoteDispatchFlagPolicy.Decision) throws {
        switch decision {
        case .allowed:
            return
        case .ignoredWithNote(let note):
            logStderr(note)
        case .rejected(let message):
            throw ValidationError(message)
        }
    }
}

/// stdin 読み取りスレッドと ScenarioHost.run(onControl コールバック)の間で
/// ScenarioRunControl を受け渡す小箱(いずれか片方のスレッドから読み書きされる)
private final class DebugControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _control: ScenarioRunControl?

    var control: ScenarioRunControl? {
        get { lock.lock(); defer { lock.unlock() }; return _control }
        set { lock.lock(); defer { lock.unlock() }; _control = newValue }
    }
}

/// ftester api run の冒頭イベント。internal: ApiRunHostFanout が複数機械分をまとめて1回だけ emit する
struct ApiRunStartedEvent: Encodable {
    let kind = "runStarted"
    let total: Int
}

/// 実行開始時の Wipe Data(AndroidDataWiper)のデバイス単位フェーズ通知。runStarted より
/// 前に emit されうる。同期相手: vscode-ftester/src/model.ts の WipeStatusEvent
private struct ApiWipeStatusEvent: Encodable {
    let kind = "wipeStatus"
    let device: String
    /// "stopping" | "rebooting" | "done" | "failed"
    let phase: String
}

/// 振り直し通知(RunEvent.flowRequeued)。契約の同期相手: vscode-ftester/src/model.ts ScenarioRequeuedEvent
private struct ApiScenarioRequeuedEvent: Encodable {
    let kind = "scenarioRequeued"
    let scenario: String
    let worker: String
    let reason: String
    let attempt: Int
    let limit: Int
}

/// --profile 指定(ワーカー並列実行時)のみ、runStarted 直後に 1 回 emit するイベント。
/// id は "<platform>:<デバイス論理名>"(ApiMonitorCommand.swift の monitorDevices の id と
/// 同一規則。VSCode 拡張がモニタータイルと突合するため)。internal: 複数機械にまたがる
/// プロファイルでは ApiRunHostFanout が各子ぶんを合流させて1回だけ emit する
struct ApiWorkersReadyEvent: Encodable {
    let kind = "workersReady"
    let workers: [ApiWorkerInfo]
}

/// ApiWorkersReadyEvent の 1 ワーカー分。同期相手: vscode-ftester/src/model.ts の WorkerInfo
/// (id/name/platform/detail。machineHost は 2026-08-17 時点で未追随)。machineHost は
/// src/monitorDeviceModel.ts の MonitorDevice.machineHost と同じ名前・同じ意味(手元は省略・
/// リモートはホスト名)で揃える。表示の組み立ては拡張側(src/runLaneModel.ts の workersReady
/// 処理・laneLog.js の .lane-name)の責務なので、name 自体は加工しない
struct ApiWorkerInfo: Encodable {
    let id: String
    let name: String
    let platform: String
    let detail: String
    /// 複数機械にまたがるプロファイルでこのワーカーが居る機械(手元は nil = キー省略)
    let machineHost: String?

    init(id: String, name: String, platform: String, detail: String, machineHost: String? = nil) {
        self.id = id
        self.name = name
        self.platform = platform
        self.detail = detail
        self.machineHost = machineHost
    }
}

/// ftester api run の末尾イベント。vscode-ftester/src/model.ts の RunFinishedEvent と
/// フィールド名を同期(testSeconds/scenarioTotalSeconds のリネーム不可)。internal: 複数機械に
/// またがるプロファイルでは ApiRunHostFanout が全ホストの合計を1回だけ emit する
struct ApiRunFinishedEvent: Encodable {
    let kind = "runFinished"
    let passed: Int
    let failed: Int
    let testSeconds: Double?
    let scenarioTotalSeconds: Double?
}

/// 実行の集計結果。testSeconds/scenarioTotalSeconds は ScenarioTimingTracker 参照
/// RunEvent の worker(= RunWorker.label)→ workersReady と同じ id("platform:論理名")への変換表。
/// iOS ワーカーが遅延参加(RunOrchestrator.lateWorkers)で後から加わるため、NSLock で保護した
/// 可変 map にする(書き手=lateWorkers provider タスク、読み手=NDJSON 変換ループ)。
final class WorkerIDMap: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String]

    init(_ workers: [RunWorker]) {
        map = Dictionary(uniqueKeysWithValues: workers.map {
            ($0.label, "\($0.platform):\($0.logicalName ?? $0.label)")
        })
    }

    func merge(_ workers: [RunWorker]) {
        lock.lock()
        defer { lock.unlock() }
        for w in workers {
            map[w.label] = "\(w.platform):\(w.logicalName ?? w.label)"
        }
    }

    func id(for label: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return map[label] ?? label
    }
}

struct RunOutcome {
    var passed: Int
    var failed: Int
    var testSeconds: Double?
    var scenarioTotalSeconds: Double?
    /// 実行中に劣化・離脱したワーカー(「label: 理由」)。並列経路のみ発生しうる。
    var degradedWorkers: [String] = []
    /// 結果取り消し+振り直しの監査記録(並列経路のみ)。
    var freezeRetries: [String] = []
    /// run 前の blank 判定で修復/除外されたワーカー label(RunMetaRecord へ記録)。
    var blankRepairs: [String] = []
    var blankExclusions: [String] = []
}

/// 並列ワーカー構築 Task から blank triage を run() へ運ぶ入れ物
/// (--debug の DebugControlBox と同じ受け渡しパターン。書き手は android task のみ)
final class BlankTriageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var repaired: [String] = []
    private var excluded: [String] = []
    func set(repaired: [String], excluded: [String]) {
        lock.lock(); defer { lock.unlock() }
        self.repaired = repaired; self.excluded = excluded
    }
    func get() -> (repaired: [String], excluded: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (repaired, excluded)
    }
}

/// flowStarted〜flowFinished から testSeconds(最初の開始〜最後の完了)と
/// scenarioTotalSeconds(シナリオ毎の所要時間の合計)を計測する。並列実行では
/// record(_:) で RunEvent の flowStarted/flowFinished を渡す(flowURL をキーに対応付ける。
/// flowSkipped は無視 = 0秒扱い)。逐次実行では recordSequential(start:finish:) を
/// シナリオ毎に直接呼ぶ(同時に1件しか走らないため URL キー付けは不要)。ProfileRunner.swift
/// からも同一ターゲット内で参照
/// プラットフォーム 1 つ分のレーン稼働。分母は run 全体の壁時計(= そのプラットフォームが
/// 「run が続いている間どれだけ遊休だったか」を表す)。docs/performance-tuning.md §3.6 の
/// 「台数を増やす前に、プラットフォーム別の稼働率と最終終了時刻を見る」を実行後に読める形にしたもの。
struct LaneUtilization {
    let platform: String
    /// 実際にシナリオを1本でも実行したワーカー数
    let lanes: Int
    /// そのプラットフォームの全レーンの実行時間の総和
    let busySeconds: Double
    /// run 全体の開始から、そのプラットフォームの最後のシナリオが終わるまで
    let lastFinishSeconds: Double
    /// busy ÷ (lanes × run 全体の壁時計)。1.0 = 全レーンが最後まで詰まっていた
    let utilization: Double
}

struct ScenarioTimingTracker {
    private var firstStart: Date?
    private var lastFinish: Date?
    private var startedAt: [URL: (at: Date, worker: String)] = [:]
    private var scenarioTotal: TimeInterval = 0
    private var hasScenario = false
    /// platform → (稼働したワーカー label, 実行時間の総和, 最後の終了時刻)
    private var lanesByPlatform: [String: Set<String>] = [:]
    private var busyByPlatform: [String: TimeInterval] = [:]
    private var lastFinishByPlatform: [String: Date] = [:]

    /// ワーカー label から platform を戻す。形式の正は RunWorker.platform(fromLabel:)
    /// (デバイス名が "(" や ":" を含むため素朴な split は壊れる)。
    /// 解釈できない label は "?" に寄せる(集計から落とさない)。
    private static func platform(ofWorker label: String) -> String {
        RunWorker.platform(fromLabel: label) ?? "?"
    }

    /// at はテストから時刻を固定するための注入点(既定は実時刻)。
    mutating func record(_ event: RunEvent, at now: Date = Date()) {
        switch event {
        case .flowStarted(let worker, let flowURL, _, _):
            // min/max で受ける(実運用のイベントは時系列順だが、順序に依存しない方が安全。
            // 依存すると集計が壁時計より短い分母を掴んで稼働率が 100% を超える)
            firstStart = min(firstStart ?? now, now)
            startedAt[flowURL] = (now, worker)
            hasScenario = true
        case .flowFinished(let worker, let flowURL, _, _, _, _):
            lastFinish = max(lastFinish ?? now, now)
            let platform = Self.platform(ofWorker: worker)
            lastFinishByPlatform[platform] = max(lastFinishByPlatform[platform] ?? now, now)
            lanesByPlatform[platform, default: []].insert(worker)
            if let start = startedAt.removeValue(forKey: flowURL) {
                let elapsed = now.timeIntervalSince(start.at)
                scenarioTotal += elapsed
                // 実行したのは開始時のワーカー(振り直しで別デバイスに移ることがある)
                let busyPlatform = Self.platform(ofWorker: start.worker)
                busyByPlatform[busyPlatform, default: 0] += elapsed
                lanesByPlatform[busyPlatform, default: []].insert(start.worker)
            }
        default:
            break
        }
    }

    /// プラットフォーム別のレーン稼働(platform 名の昇順)。run が空なら空配列。
    var laneUtilizations: [LaneUtilization] {
        guard let firstStart, let lastFinish else { return [] }
        let runSpan = lastFinish.timeIntervalSince(firstStart)
        return lanesByPlatform.keys.sorted().compactMap { platform in
            let lanes = lanesByPlatform[platform]?.count ?? 0
            guard lanes > 0 else { return nil }
            let busy = busyByPlatform[platform] ?? 0
            let denominator = Double(lanes) * runSpan
            return LaneUtilization(
                platform: platform, lanes: lanes, busySeconds: busy,
                lastFinishSeconds: (lastFinishByPlatform[platform] ?? firstStart)
                    .timeIntervalSince(firstStart),
                utilization: denominator > 0 ? busy / denominator : 0)
        }
    }

    mutating func recordSequential(start: Date, finish: Date) {
        firstStart = min(firstStart ?? start, start)
        lastFinish = max(lastFinish ?? finish, finish)
        scenarioTotal += finish.timeIntervalSince(start)
        hasScenario = true
    }

    var testSeconds: Double? {
        guard let firstStart, let lastFinish else { return nil }
        return lastFinish.timeIntervalSince(firstStart)
    }

    var scenarioTotalSeconds: Double? { hasScenario ? scenarioTotal : nil }
}

/// `api run` が台数を決めるための本数の読み方(判断はここだけ。ApiRunExactScenarioCountTests)。
/// この経路はシナリオ一覧をビルドと並行に解決するので、台数を決める時点では一覧が無い ——
/// 確定しているのは `--scenario` の指定文字列だけ。**明示 ID(`Class.method`)は1つにつき高々1本**
/// なので合計を上限に使える。クラス名指定や全件は本数が分からないので **0 = 絞らない**
/// (そこは並列度が要る場面で、絞ると遅くなる)
enum ApiRun {
    static func exactScenarioCount(_ selectors: [String]) -> Int {
        guard !selectors.isEmpty, selectors.allSatisfy({ $0.contains(".") }) else { return 0 }
        return selectors.count
    }
}
