// ftester run --profile の実行パス:
//   実行プロファイル解決 → ワーカー構築(iOS ブリッジ供給 / Android 照合)→
//   自動インストール → RunOrchestrator で両OS同時並列実行。
// ワーカー構築の実体は ProfileWorkerFactory。

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore

enum ProfileRunner {

    /// ワーカー復帰待ちの上限。監視側の再起動やデバイス自己回復を待つ
    private static let REVIVE_TIMEOUT: TimeInterval = 90

    /// 戻り値: 実行サマリ(失敗数+劣化ワーカー)
    /// - lpt: LPT 投入順を使うか。並べ替えは defaultPlatform が確定してからでないと
    ///   別 platform の実績で並べてしまうため、この関数の中で行う(呼び出し側では順序を触らない)。
    static func run(project: TestProject, profileName: String, items rawItems: [ScenarioRunItem],
                    healOverride: Bool?, reportDirOverride: String?,
                    quiet: Bool = false, lpt: Bool = true,
                    lptHistoryRuns: Int = LPTOrdering.defaultHistoryRuns,
                    recorder: RunRecorder? = nil) async throws -> RunSummary {
        var items = rawItems
        let runClockStart = Date()
        // 1. マシン決定 → プロファイル合成(実行プロファイル自身の machine 指定があれば最優先)
        PhaseLog.mark("profile-runner-start")
        let machine = try ProfileResolver.determineMachine(
            project: project, registered: LocalConfig.currentMachineName(),
            runProfileName: profileName)
        if machine.auto {
            print("→ Using machine profile \(machine.name) automatically (it is the only one in machines/)")
        }
        let full = try ProfileResolver.resolve(
            project: project, runName: profileName, machineName: machine.name)
        // **回す本数を超える台数を用意しない**(ResolvedProfile.limitingDevices の宣言参照)。
        // 本数はここで確定している(items は呼び出し側で解決済み)ので、ブリッジ供給・アプリ版チェック・
        // blank triage が丸ごと縮む。platform 未指定のシナリオは**両方**に数える(どちらでも走りうる)
        let iosCount = items.filter { $0.info.platform != "android" }.count
        let androidCount = items.filter { $0.info.platform != "ios" }.count
        let resolved = full.limitingDevices(iosScenarios: iosCount, androidScenarios: androidCount)
        if resolved.devices.count < full.devices.count {
            print("→ Using \(resolved.devices.count) of \(full.devices.count) device(s)"
                + " for \(items.count) scenario(s)")
        }
        for warning in resolved.warnings { print("⚠️ \(warning)") }

        // CLI の --heal override は master(fm.enabled)が有効な場合のみ heal を ON にする。
        // healOverride==false は明示 OFF、nil は profile の値をそのまま使う
        var fm = resolved.fm
        if healOverride == true { fm.heal = fm.enabled }
        if healOverride == false { fm.heal = false }
        await Self.warnIfHealDegraded(heal: fm.heal) { print($0) }
        let reportDir = reportDirOverride.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir
        if resolved.iosFastInput { setenv("FT_FAST_INPUT", "1", 1) }  // BridgeClient.fastInput 参照
        // 未指定でも必ず書く(既定の "0" を明示し、前段の値を残さない)。環境変数側で
        // 既に ON なら尊重する(`ftester run --enable-animations` と手動 export の上書き)
        let animations = resolved.enableAnimations || AnimationPolicy.animationsEnabled()
        setenv(AnimationPolicy.environmentKey, animations ? "1" : "0", 1)
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
        // run-lease(.ftester/run-<key>.lease)。best-effort: リポジトリ外実行等で root が
        // 取れない場合は書かない(monitor 側の inRun 判定が false になるだけで安全)
        let leaseStateDir = (try? RepoRoot.find())?.appendingPathComponent(".ftester")
        // 供給フェーズ(install・凍結triage)の間も lease を保つ。RunOrchestrator の lease は
        // シナリオ実行中しか書かれず、その手前に device-up が割り込む穴が空くため
        let supplyLease = leaseStateDir.map { SupplyLeaseHolder(stateDir: $0) }
        defer { supplyLease?.release() }

        await ProfileWorkerFactory.preparePhysicalAndroidDevices(resolved: resolved) { print($0) }
        var workers = try ProfileWorkerFactory.buildAndroidWorkers(resolved: resolved) { print($0) }
        supplyLease?.hold(keys: workers.compactMap { $0.connection.serial ?? $0.connection.udid })
        let beforeBlankCheck = workers.count
        let triage = await ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers(workers) { print($0) }
        workers = triage.workers
        if workers.isEmpty && beforeBlankCheck > 0 {
            throw ProfileWorkerFactory.InstallError(
                message: "no usable devices (every Android device went blank)")
        }
        workers = try await ProfileWorkerFactory.installIfNeeded(
            apps: resolved.apps, workers: workers,
            forceAndroidInstall: !wipedAndroid.isEmpty) { print($0) }
        let hasLateIOS = !resolved.iosDevices.isEmpty

        // 3. 両OS同時並列実行(platform 別キューは RunOrchestrator がそのまま担う)
        let defaultPlatform = (hasLateIOS || workers.contains { $0.platform == "ios" })
            ? "ios" : "android"
        // 長いシナリオを先に流すと末尾の遊休が減る(実績は platform 別。--no-lpt で従来の ID 順)
        items = LPTOrdering.apply(items, project: project, defaultPlatform: defaultPlatform,
                                  enabled: lpt, historyRuns: lptHistoryRuns, log: { print($0) })
        print("🚀 Starting with \(workers.count) Android worker(s)"
            + (hasLateIOS ? " (iOS joins once bridge provisioning finishes)" : "") + "\n")

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
                do {
                    PhaseLog.mark("ios-workers-start")
                    var ws = try await ProfileWorkerFactory.buildIOSWorkers(
                        resolved: resolved, repoRoot: repoRoot) { print($0) }
                    PhaseLog.mark("ios-workers-built")
                    supplyLease?.hold(
                        keys: ws.compactMap { $0.connection.serial ?? $0.connection.udid })
                    ws = (try? await ProfileWorkerFactory.installIfNeeded(
                        apps: resolved.apps, workers: ws, forceAndroidInstall: false) { print($0) }) ?? ws
                    PhaseLog.mark("ios-workers-installed")
                    // 画面だけ死んだシミュレータを**投入前に回復させる**(BlankWorkerTriage 参照)。
                    // 回復は simctl shutdown→boot で、**ブリッジごと死ぬ**ので張り直しまでが1セット。
                    // 張り直しは buildIOSWorkers を呼び直すだけでよい(生きているブリッジは
                    // 再利用されるので、実際に建て直るのは落とした機だけ)。
                    // レーンに凍結機を残さないための処理で、戻らなかった個体だけが除外される
                    let recovered = try? await BlankWorkerTriage.excludeBlankScreenWorkers(
                        ws,
                        recover: { @Sendable frozen in
                            await ProfileWorkerFactory.recoverFrozenIOSWorkers(
                                labels: frozen, workers: ws, resolved: resolved,
                                repoRoot: repoRoot, apps: resolved.apps) { print($0) }
                        },
                        stateDir: repoRoot.appendingPathComponent(".ftester"),
                        log: { print($0) }).workers
                    ws = recovered ?? ws
                    print("🚀 \(ws.count) iOS worker(s) joined")
                    return ws
                } catch {
                    // iOS 供給失敗は run 全体を落とさない(iOS シナリオはワーカー不在ドレインで失敗確定)
                    print("❌ Failed to build iOS workers: \(error.localizedDescription)")
                    return []
                }
            }) : nil,
            installHandler: InstallHandlerFactory.make(apps: resolved.apps),
            appName: resolved.appName)
        PhaseLog.mark("orchestrator-setup")
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

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
        // run 前の blank triage(orchestrator は関与しない)を summary に載せ替えて返す
        // (RunScenarios が recorder.finish で run.json に記録する)
        return RunSummary(total: finalSummary.total, failed: finalSummary.failed,
                          degradedWorkers: finalSummary.degradedWorkers,
                          freezeRetries: finalSummary.freezeRetries,
                          blankRepairs: triage.repaired, blankExclusions: triage.excluded)
    }

    /// heal 有効 run の開始前に FM の実呼び出し可否を確認して警告する。availability は嘘をつく
    /// (available のまま実呼び出しが全滅する実測 2026-07-22)ため checkLive を使う。FM 実呼び出しは
    /// ~1s かかるので heal 有効時のみ(occlusion-guard の劣化はシナリオ実行中の警告が別途出る)。
    /// ApiRunCommand と共用。
    static func warnIfHealDegraded(heal: Bool, log: (String) -> Void) async {
        guard heal else { return }
        let fm = await FMDoctor.checkLive()
        if !fm.available {
            log("⚠️ heal is enabled but live FM calls are failing, so "
                + "self-healing, occlusion-guard and screenIs are disabled for this run")
        } else if !FMVisionSupport.isSupported {
            log("⚠️ \(FMVisionSupport.requirement): occlusion-guard and screenIs are disabled for this run"
                + " (self-healing and triage stay enabled)")
        }
    }

}
