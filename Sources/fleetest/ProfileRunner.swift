// fleetest run --profile の実行パス:
//   実行プロファイル解決 → ワーカー構築(iOS ブリッジ供給 / Android 照合)→
//   自動インストール → RunOrchestrator で両OS同時並列実行。
// ワーカー構築の実体は ProfileWorkerFactory。

import ArgumentParser  // --device の指定違いを ValidationError で返す
import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

enum ProfileRunner {

    /// ワーカー復帰待ちの上限。監視側の再起動やデバイス自己回復を待つ
    private static let REVIVE_TIMEOUT: TimeInterval = 90

    /// CLI の `--heal` / `--no-heal` → `run(healOverride:)`。**nil = 実行プロファイルの値をそのまま使う**
    /// (プロファイル実行の heal 既定は true)。両立指定は `RunScenarios.validate()` が弾くので、
    /// ここに来る組み合わせは3通りだけ。**デバイスが要る run から切り出した純粋関数**なので
    /// `ProfileRunnerHealOverrideTests` が全組み合わせを固定する
    static func healOverride(heal: Bool, noHeal: Bool) -> Bool? {
        if heal { return true }
        if noHeal { return false }
        return nil
    }

    /// 戻り値: 実行サマリ(失敗数+劣化ワーカー)
    /// - lpt: LPT 投入順を使うか。並べ替えは defaultPlatform が確定してからでないと
    ///   別 platform の実績で並べてしまうため、この関数の中で行う(呼び出し側では順序を触らない)。
    /// - broadcast: `--broadcast`(ブロードキャスト)。items を**各デバイスで1回ずつ**回す
    ///   (`ScenarioDispatch.broadcast`)。変わるのは台数を絞らないことと分配だけで、供給・
    ///   インストール・フック(run で1回)・スタッガ・復帰・レポートは通常 run と同じ経路
    static func run(project: TestProject, profileName: String, items rawItems: [ScenarioRunItem],
                    healOverride: Bool?, reportDirOverride: String?,
                    quiet: Bool = false, lpt: Bool = true,
                    lptHistoryRuns: Int = LPTOrdering.defaultHistoryRuns,
                    performanceMode: Bool = false,
                    deviceFilter: [String] = [],
                    deviceMachine: String? = nil,
                    workspaceOverride: String? = nil,
                    recorder: RunRecorder? = nil,
                    broadcast: Bool = false) async throws -> RunSummary {
        var items = rawItems
        let runClockStart = Date()
        // 1. マシン決定 → プロファイル合成(実行プロファイル自身の machine 指定があれば最優先)
        PhaseLog.mark("profile-runner-start")
        let machine = try ProfileResolver.determineMachine(
            project: project,
            runProfileName: profileName)
        if machine.auto {
            print("→ Using machine profile \(machine.name) automatically (it is the only one in machines/)")
        }
        let resolvedAll = try ProfileResolver.resolve(
            project: project, runName: profileName, machineName: machine.name,
            workspaceOverride: workspaceOverride)
        // ワークスペースは常に有効(既定 `<project.rootURL>/workspace`。docs/remote-runner.md §17・
        // 2026-08-18)なので毎回雛形作成(既に揃っていれば何もしない。WorkspaceScaffold の宣言)。
        // リモートディスパッチはこれとは別に、ミラー前のローカル側で同じ呼び出しを行う
        // (RemoteRunDispatcher.prepareWorkspace)。続けて appPath の原本を apps/ へ
        // ステージング(WorkspaceAppStaging)。**dest も原本も無ければここで throw する**
        // (原本のパスを名指しする。呼び出し側で握り潰さない)
        if let workspaceRoot = resolvedAll.workspaceRoot {
            let created = (try? WorkspaceScaffold.ensure(root: workspaceRoot)) ?? []
            if !created.isEmpty {
                print("→ Created workspace scaffold: " + created.map { "\($0)/" }.joined(separator: ", "))
            }
            let staged = try WorkspaceAppStaging.stageWorkspaceApps(resolvedAll)
            if !staged.isEmpty {
                print("→ Staged app package(s) into the workspace: " + staged.joined(separator: ", "))
            }
        }
        // --device / --device-machine(マシン別サブ実行が自分のぶんだけ回す)。**ホストで絞らないと
        // 別の機械の同名デバイスまで掴む**(filteringDevices の宣言)。0台になったら止める
        let full = resolvedAll.filteringDevices(names: deviceFilter, deviceMachine: deviceMachine)
        if full.devices.isEmpty {
            let scope = deviceFilter.isEmpty ? "--device-machine \(deviceMachine ?? "")"
                : "--device \(deviceFilter.joined(separator: ", "))"
                    + (deviceMachine.map { " --device-machine \($0)" } ?? "")
            throw ValidationError(
                "\(scope) matched no device in run profile \(profileName)"
                + " (available: \(resolvedAll.devices.map(\.name).joined(separator: ", ")))")
        }
        // OS 対象外(`@TestClass(platform:)` / `@Test(platform:)` がこの run に無い OS を指す)は
        // **キューへ入れる前に外す** —— 入れると RunOrchestrator の「担当ワーカーなし」に落ち、
        // 意図された対象外が失敗として数えられる(PlatformApplicability の宣言)。
        // 台数の見積り(この下)より前に行う: 外した分の台は用意しなくてよい
        let runPlatforms = Set(full.devices.map(\.platform))
        let applicability = PlatformApplicability.partition(items, runPlatforms: runPlatforms) {
            $0.info.platform
        }
        if !applicability.notApplicable.isEmpty {
            for item in applicability.notApplicable {
                let declared = item.info.platform ?? ""
                recorder?.recordSkipped(
                    scenarioID: item.info.id, title: item.info.title, platform: declared,
                    worker: nil,
                    reason: PlatformApplicability.reason(declared: declared,
                                                         runPlatforms: runPlatforms),
                    kind: .notApplicable)
            }
            print("→ Skipped \(applicability.notApplicable.count) scenario(s) declared for another"
                  + " platform (this run covers \(runPlatforms.sorted().joined(separator: ", ")))")
            items = applicability.runnable
        }
        // 全部が対象外ならデバイスを起こす意味がない(0 失敗で終える = 正しく緑)
        if items.isEmpty {
            return RunSummary(total: 0, failed: 0, performanceMode: performanceMode)
        }

        // **回す本数を超える台数を用意しない**(ResolvedProfile.limitingDevices の宣言参照)。
        // 本数はここで確定している(items は呼び出し側で解決済み)ので、ブリッジ供給・アプリ版チェック・
        // blank triage が丸ごと縮む。platform 未指定のシナリオは**両方**に数える(どちらでも走りうる)。
        // **--broadcast は絞らない** —— 各台で1回ずつ走らせるのが目的なので、絞ると回るべき台が落ちる
        let resolved: ResolvedProfile
        if broadcast {
            resolved = full
            print("→ Broadcasting \(items.count) scenario(s) to each of \(full.devices.count) device(s)"
                + " (--broadcast)")
        } else {
            let iosCount = items.filter { $0.info.platform != "android" }.count
            let androidCount = items.filter { $0.info.platform != "ios" }.count
            resolved = full.limitingDevices(iosScenarios: iosCount, androidScenarios: androidCount)
            if resolved.devices.count < full.devices.count {
                print("→ Using \(resolved.devices.count) of \(full.devices.count) device(s)"
                    + " for \(items.count) scenario(s)")
            }
        }
        for warning in resolved.warnings { print("⚠️ \(warning)") }

        // 開始スクリプト(docs/remote-runner.md §17)。**デバイスに触る前**に撃つ ——
        // 依存サービスが上がっていない状態でシミュレータを起こしてアプリを入れても、
        // 全シナリオが「アプリの不具合」の顔で落ちるだけ。渡すのは絞り込み後の resolved
        // (スクリプトが受け取るデバイス一覧を、この run が実際に使う台と一致させる)。
        // 終了スクリプトは defer で必ず撃つ(途中の throw・シナリオの失敗のいずれでも)。
        // プロセスごと殺された場合は lease が残り、次の run と `fleetest hooks reap` が代わりに撃つ
        let hookStateDir = (try? RepoRoot.find())?.appendingPathComponent(".fleetest")
        let hookSession = try RunHookRunner.begin(
            resolved: resolved, stateDir: hookStateDir) { print($0) }
        defer { RunHookRunner.end(hookSession) { print($0) } }


        // CLI の --heal override は master(fm.enabled)が有効な場合のみ heal を ON にする。
        // healOverride==false は明示 OFF、nil は profile の値をそのまま使う
        var fm = resolved.fm
        if healOverride == true { fm.heal = fm.enabled }
        if healOverride == false { fm.heal = false }
        await Self.warnIfFMDegraded(fm: fm) { print($0) }
        let reportDir = reportDirOverride.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir
        if resolved.iosFastInput { setenv("FT_FAST_INPUT", "1", 1) }  // BridgeClient.fastInput 参照
        // 既定 ON なので OFF のときだけ注入する(WebViewDelegatingDriver.preActionWarmup 参照)
        if !resolved.iosPreActionWarmup { setenv("FT_PRE_ACTION_WARMUP", "0", 1) }
        // 未指定でも必ず書く(既定の "0" を明示し、前段の値を残さない)。環境変数側で
        // 既に ON なら尊重する(`fleetest run --enable-animations` と手動 export の上書き)
        let animations = resolved.enableAnimations || AnimationPolicy.animationsEnabled()
        setenv(AnimationPolicy.environmentKey, animations ? "1" : "0", 1)
        // キルスイッチは既定 ON なので OFF のときだけ注入する(AdbInstallVerifier.bypassEnabled 参照)
        if !resolved.playProtectBypass { setenv(AdbInstallVerifier.environmentKey, "0", 1) }
        let deviceList = resolved.devices
            .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
        print("🧩 Profile \(profileName): \(resolved.appName) @ \(resolved.machineName)")
        print("   Devices: \(deviceList)")

        // 1.5. Android AVD 肥大化チェック(超過分は Wipe Data。buildWorkers 前に実行)
        var wipedAndroid: [String] = []
        if resolved.wipeDataOnBloat {
            wipedAndroid = await AndroidDataWiper.wipeBloatedAVDs(
                devices: resolved.androidDevices, thresholdGB: resolved.wipeDataThresholdGB,
                locale: resolved.locale) { print($0) }
        }

        // 2. Android ワーカー構築(serial 照合=数秒)→ 白化の修復/除外 → 自動インストール。
        // iOS(ブリッジ供給=壊れたブリッジの置き換えで数十秒かかりうる)は lateWorkers として
        // 分離し、Android を供給完了待ちにしない(ApiRunCommand の並列経路と同じ方針)。
        let repoRoot = try RepoRoot.find()
        await BackendHealthCheck.warnIfUnreachable(resolved: resolved) { print($0) }
        // GPU 復帰は buildAndroidWorkers より前(emulator プロセスを入れ替えるため serial が
        // 変わりうる。Wipe Data と同じ理由・同じ位置)
        if resolved.recoverCpuFallbackToGpu {
            _ = await AndroidGpuRecovery.recoverCpuFallbackDevices(
                devices: resolved.androidDevices, locale: resolved.locale) { print($0) }
        }
        // 死んだレーンの復活(両モード共通)。buildAndroidWorkers の直前(GPU 復帰の後)で
        // 起動していない仮想デバイスを先に起こす。復活できなかった場合の扱いは
        // performanceMode の有無で分岐する(このあとの LaneGate 判定)
        if let running = try? AndroidDeviceCatalog.runningAVDs() {
            let laneTargets = AndroidLaneRecovery.plan(
                devices: resolved.androidDevices, runningAVDIDs: Set(running.values))
            if !laneTargets.isEmpty {
                let outcome = await AndroidLaneRecovery.bootMissingDevices(
                    devices: laneTargets.map(\.device), locale: resolved.locale) { print($0) }
                // 起こせた分は、ブリッジが定着するまで待ってから先へ進む(理由は
                // awaitDurableAndroidBridges の宣言)
                await ProfileWorkerFactory.awaitDurableAndroidBridges(
                    devices: laneTargets.map(\.device)
                        .filter { outcome.booted.contains($0.name) }) { print($0) }
            }
        }
        // run-lease(.fleetest/run-<key>.lease)。best-effort: リポジトリ外実行等で root が
        // 取れない場合は書かない(monitor 側の inRun 判定が false になるだけで安全)
        let leaseStateDir = (try? RepoRoot.find())?.appendingPathComponent(".fleetest")
        // 供給フェーズ(install・凍結triage)の間も lease を保つ。RunOrchestrator の lease は
        // シナリオ実行中しか書かれず、その手前に device-up が割り込む穴が空くため
        let supplyLease = leaseStateDir.map { SupplyLeaseHolder(stateDir: $0) }
        defer { supplyLease?.release() }

        await ProfileWorkerFactory.preparePhysicalAndroidDevices(resolved: resolved) { print($0) }
        var workers = try ProfileWorkerFactory.buildAndroidWorkers(resolved: resolved) { print($0) }
        supplyLease?.hold(keys: workers.compactMap { $0.connection.serial ?? $0.connection.udid })
        let androidSerials = workers.compactMap { $0.connection.serial }
        // **テスト開始時に WebView を揃える**(既定 ON。AndroidWebViewUpdate の宣言参照)
        if resolved.updateWebView, let adbPath = try? AndroidDriver.findADB() {
            AndroidWebViewUpdate.run(
                targets: androidSerials,
                allSerials: (try? AndroidDeviceCatalog.connectedSerials()) ?? androidSerials,
                adb: { args in try? Shell.run([adbPath] + args, timeout: 600).output },
                log: { print($0) })
        }
        // **揃わなかった場合は混在を言う**(落とさない。AndroidWebViewVersions の宣言参照)
        warnIfWebViewVersionsDiffer(serials: androidSerials) { print($0) }
        let beforeBlankCheck = workers.count
        let triage = await ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers(
                workers, stateDir: (try? RepoRoot.find())?.appendingPathComponent(".fleetest")) { print($0) }
        workers = triage.workers
        if workers.isEmpty && beforeBlankCheck > 0 {
            throw ProfileWorkerFactory.InstallError(
                message: "no usable devices (every Android device went blank)")
        }
        workers = try await ProfileWorkerFactory.installIfNeeded(
            apps: resolved.apps, workers: workers,
            forceAndroidInstall: !wipedAndroid.isEmpty) { print($0) }
        // 一斉 launch 直後の黒画面を作らないための予防(ProfileWorkerFactory.pressHomeOnStart)
        await ProfileWorkerFactory.prepareDevicesOnStart(
            workers, homeOnStart: resolved.homeOnStart) { print($0) }
        let iosDevicesExist = !resolved.iosDevices.isEmpty

        // performanceMode では iOS の late join をやめて開始前に建てる。**理由は計測の歪みではなく
        // ゲートの可視性** —— late join だと iOS ワーカーは run 開始後に建つので、「iOS のレーンが
        // 足りない」を開始前に検出できず、モードの約束(足りなければ開始しない)が iOS だけ守れない。
        // 計測そのものは late join でも歪まない(provider は全機をまとめて返すのでレーンは 0→N と
        // 一段で増え、シナリオはそれまで走らない)。Android が先行する混在プロファイルだけは
        // 歪むが、そこは計測対象外(両OSを1プロファイルにまとめない方針)。
        // buildIOSLane は lateWorkers provider と同じ関数(2つ目の実装を書かない)
        var eagerIOSWorkers: [RunWorker] = []
        if performanceMode, iosDevicesExist {
            eagerIOSWorkers = await buildIOSLane(
                resolved: resolved, repoRoot: repoRoot, supplyLease: supplyLease)
            print("🚀 \(eagerIOSWorkers.count) iOS worker(s) joined")
        }
        let hasLateIOS = iosDevicesExist && !performanceMode

        // performanceMode: 復活できなかったレーンがあれば run を開始せずに失敗する
        // (既定 false ではここへ来ない=切り離して完走を優先する従来どおりの挙動)
        if performanceMode {
            let missingAndroid = LaneGate.missing(
                expected: resolved.androidDevices.map(\.name),
                actual: workers.compactMap(\.logicalName))
            let missingIOS = iosDevicesExist
                ? LaneGate.missing(expected: resolved.iosDevices.map(\.name),
                                   actual: eagerIOSWorkers.compactMap(\.logicalName))
                : []
            let missing = missingAndroid + missingIOS
            if !missing.isEmpty {
                throw ProfileWorkerFactory.InstallError(
                    message: "performance mode: \(missing.count) device(s) could not be started "
                        + "(\(missing.joined(separator: ", "))). Fix the devices, or turn "
                        + "performanceMode off to run on the remaining lanes.")
            }
        }

        // 3. 両OS同時並列実行(platform 別キューは RunOrchestrator がそのまま担う)
        let defaultPlatform = (hasLateIOS || (workers + eagerIOSWorkers).contains { $0.platform == "ios" })
            ? "ios" : "android"
        // 長いシナリオを先に流すと末尾の遊休が減る(実績は platform 別。--no-lpt で従来の ID 順)
        items = LPTOrdering.apply(items, project: project, defaultPlatform: defaultPlatform,
                                  enabled: lpt, historyRuns: lptHistoryRuns, log: { print($0) })
        print("🚀 Starting with \(workers.count) Android worker(s)"
            + (hasLateIOS ? " (iOS joins once bridge provisioning finishes)"
                          : (eagerIOSWorkers.isEmpty ? "" : " + \(eagerIOSWorkers.count) iOS worker(s)"))
            + "\n")

        // record:true のときだけ VideoRecordingConfig を注入(runDir が無ければ録画自体しない)
        let recordingConfig: VideoRecordingConfig? = {
            guard resolved.record, let recorder else { return nil }
            return VideoRecordingConfig(
                runDir: recorder.runDir, androidADBPath: try? AndroidDriver.findADB(),
                failuresOnly: resolved.recordFailuresOnly, bitrateKbps: resolved.recordBitrateKbps,
                fullResolution: resolved.recordFullResolution)
        }()

        let orchestrator = RunOrchestrator(
            project: project, workers: workers + eagerIOSWorkers, fm: fm,
            reportDir: reportDir, defaultTimeout: resolved.defaultTimeout,
            containerInference: resolved.containerInference,
            scenarioTimeout: resolved.scenarioTimeout, recorder: recorder,
            recordingConfig: recordingConfig,
            isDeviceFrozen: { serial in
                // 事後判定は isBlankObserved(窓内に一度でも blank)。isPersistentlyBlank だと
                // 約25秒周期のフラッピングの回復側を引いて凍結を見逃す(実測 2026-07-18)。
                // 凍結確定時はその場で sleep/wake 修復も試みる(判定・振り直しは従来どおり)
                await AndroidHealthProbe.observeBlankAndRepair(serial: serial) { print($0) }
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
                    atPath: repoRoot.appendingPathComponent(".fleetest/bridge-\(port).log").path)
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
                    print("🔧 Stopped stale bridges: port \(stopped.joined(separator: ", "))")
                }
            },
            reviveWorker: { retired in
                guard let name = retired.logicalName else { return nil }
                let deadline = Date().addingTimeInterval(REVIVE_TIMEOUT)
                while Date() < deadline {
                    if let w = await ProfileWorkerFactory.buildWorker(forLogicalName: name, resolved: resolved,
                                                                       repoRoot: repoRoot, log: { print($0) }) {
                        let installed = (try? await ProfileWorkerFactory.installIfNeeded(
                            apps: resolved.apps, workers: [w], forceAndroidInstall: false) { print($0) }) ?? [w]
                        return installed.first ?? w
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                return nil
            },
            lateWorkers: hasLateIOS ? (platforms: Set(["ios"]), provider: { @Sendable in
                let ws = await buildIOSLane(resolved: resolved, repoRoot: repoRoot, supplyLease: supplyLease)
                print("🚀 \(ws.count) iOS worker(s) joined")
                return ws
            }) : nil,
            installHandler: InstallHandlerFactory.make(apps: resolved.apps),
            appName: resolved.appName,
            appBundleIDs: resolved.apps.mapValues(\.bundleID),
            appTargets: resolved.apps)
        PhaseLog.mark("orchestrator-setup")
        // レーン = 絞り込み後の全デバイス(供給に失敗して参加しなかった台のぶんは、orchestrator が
        // 「never joined」でそのレーンの本数を失敗として残す = 準備できなかった台が緑に紛れない)
        let dispatch: ScenarioDispatch = broadcast
            ? .broadcast(lanes: resolved.devices.map { BroadcastLane(key: $0.name, platform: $0.platform) })
            : .shared
        let itemsToRun = items  // async let は var を直接捕捉できない(Sendable 境界)
        async let summary = orchestrator.run(items: itemsToRun, defaultPlatform: defaultPlatform,
                                             dispatch: dispatch)

        // シナリオ毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)。
        // quiet: 成功シナリオは結果1行のみ・失敗シナリオはバッファ全体(失敗詳細)を出す
        var buffers: [URL: [String]] = [:]
        var names: [URL: String] = [:]
        var timing = ScenarioTimingTracker()
        for await event in orchestrator.events {
            timing.record(event)
            let lines = RunLogFormatter.lines(for: event)
            switch event {
            case .flowStarted(_, let url, let flowName, _):
                names[url] = flowName
                buffers[url, default: []].append(contentsOf: lines)
            case .step(_, let url, _), .flowHealed(_, let url), .flowRequeued(_, let url, _, _, _):
                buffers[url, default: []].append(contentsOf: lines)
            case .flowFinished(_, let url, let passed, _, _, _):
                let all = (buffers.removeValue(forKey: url) ?? []) + lines
                if quiet {
                    print(passed ? "✅ \(names[url] ?? url.lastPathComponent)"
                                 : "❌ \(names[url] ?? url.lastPathComponent)\n" + all.joined(separator: "\n"))
                } else {
                    print(all.joined(separator: "\n"))
                }
            default:
                if !lines.isEmpty { print(lines.joined(separator: "\n")) }
            }
        }

        let totalSeconds = Date().timeIntervalSince(runClockStart)
        let testStr = timing.testSeconds.map { String(format: "%.1f", $0) } ?? "-"
        let scenarioTotalStr = timing.scenarioTotalSeconds.map { String(format: "%.1f", $0) } ?? "-"
        print("⏱ Total: \(String(format: "%.1f", totalSeconds))s / "
            + "test time: \(testStr)s / scenario sum: \(scenarioTotalStr)s")

        // プラットフォーム別のレーン稼働。台数を増やす前にここを見る(遊休レーンがあるなら
        // 増やすのではなく配分を変える。docs/performance-tuning.md §3.6)
        // 単一プラットフォームでも「レーンが遊休している」ことは読めるので出す(台数過多の検知)。
        // 逐次実行(1レーン)だけは自明なので黙る。
        let utilizations = timing.laneUtilizations
        if utilizations.count > 1 || utilizations.contains(where: { $0.lanes > 1 }) {
            let cells = utilizations.map {
                "\($0.platform) \($0.lanes) lane(s), \(Int(($0.utilization * 100).rounded()))% busy"
                + ", last finished at \(String(format: "%.1f", $0.lastFinishSeconds))s"
            }
            print("📊 Lane utilisation: " + cells.joined(separator: " / "))
            if let advice = LaneBalanceAdvice.message(for: utilizations) { print(advice) }
        }

        let finalSummary = await summary
        if !finalSummary.degradedWorkers.isEmpty {
            print("⚠️ Degraded or dropped workers (\(finalSummary.degradedWorkers.count)):")
            for entry in finalSummary.degradedWorkers { print("   - \(entry)") }
        }
        if !finalSummary.freezeRetries.isEmpty {
            print("🔁 Results discarded and requeued (\(finalSummary.freezeRetries.count)):")
            for entry in finalSummary.freezeRetries { print("   - \(entry)") }
        }
        // performanceMode: レーン数が run 中に変わっていたら所要時間は計測に使えない
        // (MeasurementValidity の宣言参照。既定モードは判定しない=印を付けない)
        let validity = MeasurementValidity.verdict(
            performanceMode: performanceMode,
            degradedWorkers: finalSummary.degradedWorkers, blankExclusions: triage.excluded)
        if validity.invalid {
            print("⏱️❌ Measurement invalid: this run's timing cannot be used for performance"
                + " comparisons (\(validity.reasons.joined(separator: "; ")))")
        }
        // run 前の blank triage(orchestrator は関与しない)を summary に載せ替えて返す
        // (RunScenarios が recorder.finish で run.json に記録する)
        return RunSummary(total: finalSummary.total, failed: finalSummary.failed,
                          degradedWorkers: finalSummary.degradedWorkers,
                          freezeRetries: finalSummary.freezeRetries,
                          blankRepairs: triage.repaired, blankExclusions: triage.excluded,
                          measurementInvalid: validity.invalid,
                          measurementInvalidReasons: validity.reasons,
                          fmUnavailableScenarios: finalSummary.fmUnavailableScenarios,
                          workerAnomalies: finalSummary.workerAnomalies,
                          performanceMode: performanceMode)
    }

    /// FM を使う run の開始前に、FM が**本当に呼べるか**を確かめて警告する。
    ///
    /// **heal の有無で出し分けない** —— occlusion-guard(exist の既定 requireVisible)・
    /// screenLooksLike・triage は heal を切っていても FM を引くので、heal 限定にすると
    /// 「FM が死んだまま緑になった run」の大半で開始前に何も言わないことになる(2026-09-03 まで
    /// そうなっていた)。availability は嘘をつく(available のまま実呼び出しが全滅する実測
    /// 2026-07-22)ので、台帳(FMLiveness)の実観測を使う。
    ///
    /// **台帳が新しければ1回も呼ばない** —— モニターが動いていれば既に埋まっている
    /// (FMLivenessProbe.refresh の門①)。埋まっていないときだけ 1〜2 秒払う。
    /// **text と vision を別に見る**: 片方だけ死ぬのが常態で、無効になる機能が違う。
    /// ApiRunCommand と共用。
    static func warnIfFMDegraded(fm: FMConfig, log: (String) -> Void) async {
        guard fm.enabled else { return }
        let reading = await FMLivenessProbe.refresh()
        // 視覚系(occlusion-guard / screenLooksLike)を使う run だけが vision の死に影響を受ける。
        // triage は失敗時にしか走らないが FM が生きていれば画像経路を試すので、ここでは数えない
        let usesVision = fm.falsePositiveCheck || fm.screenLooksLike
        if let text = reading.text, text.state == .dead {
            log("⚠️ FM is dead on this machine (text path): self-healing and failure triage are"
                + " disabled for this run — a green result is not a guarded green."
                + reasonSuffix(text))
        }
        if usesVision, !FMVisionSupport.isSupported {
            log("⚠️ \(FMVisionSupport.requirement): occlusion-guard and screenLooksLike are disabled for this run"
                + " (self-healing and triage stay enabled)")
        } else if usesVision, let vision = reading.vision, vision.state == .dead {
            log("⚠️ FM is dead on this machine (vision path): the occlusion-guard"
                + " (the default requireVisible of exist) and screenLooksLike are disabled for this run"
                + " — a green result is not a guarded green." + reasonSuffix(vision))
        }
    }

    /// 死の理由を1行に畳む。**「いつ・何を根拠に」まで出す** —— 台帳は最大
    /// FMLiveness.freshSeconds ぶん古くなりうるので、断定の強さを読み手が測れるようにする
    private static func reasonSuffix(_ verdict: FMLiveness.Verdict) -> String {
        let age = Int(Date().timeIntervalSince1970 - verdict.checkedAt)
        return "\n   Observed \(age)s ago via \(verdict.source.rawValue)"
            + (verdict.error.map { ": \($0)" } ?? "")
    }

    /// iOS レーンの構築(供給→インストール→凍結 triage→home)。**通常は `lateWorkers` provider
    /// として run 開始後に呼ばれる**(iOS のブリッジ供給は数十秒かかりうるため、Android の
    /// 開始をそれで待たせない)。`performanceMode` のときだけ run 開始前に同じ関数を呼ぶ
    /// (ゲートが iOS レーンの不足を開始前に見られるようにするため。呼び出し箇所のコメント参照。
    /// 2つ目の実装を書かない —— 通常経路と performanceMode 経路で処理が食い違うと、
    /// どちらか一方だけにバグが残る)。
    /// 供給失敗は run 全体を落とさない(iOS シナリオはワーカー不在ドレインで失敗確定させる。
    /// performanceMode では空配列が返ることで後段の LaneGate が run 開始前エラーへ格上げする)
    private static func buildIOSLane(
        resolved: ResolvedProfile, repoRoot: URL, supplyLease: SupplyLeaseHolder?
    ) async -> [RunWorker] {
        do {
            PhaseLog.mark("ios-workers-start")
            var ws = try await ProfileWorkerFactory.buildIOSWorkers(
                resolved: resolved, repoRoot: repoRoot) { print($0) }
            PhaseLog.mark("ios-workers-built")
            supplyLease?.hold(keys: ws.compactMap { $0.connection.serial ?? $0.connection.udid })
            ws = (try? await ProfileWorkerFactory.installIfNeeded(
                apps: resolved.apps, workers: ws, forceAndroidInstall: false) { print($0) }) ?? ws
            PhaseLog.mark("ios-workers-installed")
            // 画面だけ死んだシミュレータを**投入前に回復させる**(BlankWorkerTriage 参照)。
            // 回復は simctl shutdown→boot で、**ブリッジごと死ぬ**ので張り直しまでが1セット。
            // 張り直しは buildIOSWorkers を呼び直すだけでよい(生きているブリッジは
            // 再利用されるので、実際に建て直るのは落とした機だけ)。
            // レーンに凍結機を残さないための処理で、戻らなかった個体だけが除外される
            let recovered = await BlankWorkerTriage.excludeBlankScreenWorkers(
                ws,
                recover: { @Sendable frozen, currentWorkers in
                    await ProfileWorkerFactory.recoverFrozenIOSWorkers(
                        labels: frozen, workers: currentWorkers, resolved: resolved,
                        repoRoot: repoRoot, apps: resolved.apps) { print($0) }
                },
                stateDir: repoRoot.appendingPathComponent(".fleetest"),
                    nudge: { @Sendable [bundleID = ProfileWorkerFactory.iosBundleID(apps: resolved.apps)] in
                        await ProfileWorkerFactory.nudgeIOSScreen(worker: $0, restoring: bundleID) },
                log: { print($0) }).workers
            ws = recovered
            await ProfileWorkerFactory.prepareDevicesOnStart(
                ws, homeOnStart: resolved.homeOnStart) { print($0) }
            return ws
        } catch {
            // iOS 供給失敗は run 全体を落とさない(iOS シナリオはワーカー不在ドレインで失敗確定)
            print("❌ Failed to build iOS workers: \(error.localizedDescription)")
            return []
        }
    }

}

/// フリートの WebView 版を集めて混在を警告する。**adb を端末数だけ叩く**が
/// 1台あたり1回・数十msなので run 前の固定費として許容範囲
/// (取れない端末は黙って飛ばす = 判定材料が無いだけで異常ではない)
private func warnIfWebViewVersionsDiffer(serials: [String], log: (String) -> Void) {
    guard serials.count > 1 else { return }
    let versions = AndroidWebViewVersions.collect(serials: serials) { serial, args in
        guard let adb = try? AndroidDriver.findADB() else { return nil }
        return try? Shell.run([adb, "-s", serial] + args, timeout: 10).output
    }
    if let warning = AndroidWebViewVersions.mixedVersionWarning(versions) { log(warning) }
}
