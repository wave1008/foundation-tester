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
        abstract: "シナリオを実行し、NDJSON イベント(runStarted → 各種 ScenarioEvent → "
            + "runFinished)を stdout に流す(--profile 指定時は --dry-run/--debug 以外"
            + "ワーカー並列実行。診断は stderr のみ。--debug 時は stdin の制御"
            + "コマンドをそのままランナーへ渡す)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "実行プロファイル名(profiles/runs/<名前>.json。デバイス供給・自動インストール込みで実行する。--platform/--port/--serial とは同時指定不可)")
    var profile: String?

    @Option(name: .customLong("scenario"), parsing: .upToNextOption,
            help: "実行するシナリオ ID(クラス名.メソッド名。クラス名のみで全シナリオ。複数可。1 つ以上必須。削除済み @Deleted は完全一致指定のときだけ実行)")
    var scenarios: [String] = []

    @Flag(help: "FM によるロケータ自己修復を許可する(--profile 指定時は profile の heal より優先されるのは true のときだけ)")
    var heal = false

    @Option(name: .customLong("report-dir"),
            help: "レポート出力先ディレクトリ(省略時: Projects/<name>/reports。--profile 指定時は profile の reportDir を上書き)")
    var reportDir: String?

    @Option(name: .customLong("default-timeout"),
            help: "検証コマンド(exist/textIs 等)の既定タイムアウト秒(省略時 5。--profile 指定時は profile の defaultTimeout が優先される)")
    var defaultTimeout: Int?

    @Option(name: .customLong("scenario-timeout"),
            help: "シナリオ単位の壁時計タイムアウト秒(ホスト側 watchdog。超過で子を強制終了し失敗扱い。省略時 90。--profile 指定時は profile の scenarioTimeout が優先される)")
    var scenarioTimeout: Int?

    @Flag(name: .customLong("dry-run"),
          help: "デバイスに触れず全コマンドを記録のみで通過させる(ステップ列挙・レビュー用。--profile 指定時はワーカー構築も省略する)")
    var dryRun = false

    @Flag(help: "stdin から一時停止・再開の制御コマンド(NDJSON)を受け付ける(--scenario を 1 件指定したときだけ使える)")
    var debug = false

    @Option(name: .customLong("breakpoint"),
            help: "ブレークポイント(<file>:<line>。--debug 時のみ有効。複数指定可)")
    var breakpoints: [String] = []

    @Flag(name: .customLong("pause-on-start"),
          help: "最初のステップの手前で一時停止して開始する(--debug 時のみ有効)")
    var pauseOnStart = false

    @Flag(name: .customLong("skip-build"), help: "実行前の swift build をスキップする")
    var skipBuild = false

    @Option(help: "対象プラットフォーム: ios / android(既定 ios。--profile とは同時指定不可)")
    var platform: String?

    @Option(name: .long, help: "ブリッジのポート番号(iOS のみ。--profile とは同時指定不可)")
    var port: UInt16?

    @Option(help: "Android デバイスのシリアル(adb -s。省略時は唯一の接続デバイス。--profile とは同時指定不可)")
    var serial: String?

    func run() async throws {
        // pause等のイベントが既定の全バッファに滞留すると読み手(VSCode拡張)と相互待ちになる
        // (ScenarioRunnerMain.swift の --debug 実装と同じ理由)。--debug 以外も常に行バッファにする
        setvbuf(stdout, nil, _IOLBF, 0)

        guard !scenarios.isEmpty else {
            throw ValidationError("--scenario を1つ以上指定してください")
        }
        if debug && scenarios.count != 1 {
            throw ValidationError("--debug は --scenario を1件だけ指定したときに使えます")
        }
        if profile != nil && (platform != nil || port != nil || serial != nil) {
            throw ValidationError("--profile と --platform/--port/--serial は同時に指定できません")
        }

        let testProject = try ScenarioHost.project(named: project)

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
                project: testProject, registered: LocalConfig.currentMachineName(),
                runProfileName: profile)
            if machine.auto {
                logStderr("→ マシンプロファイル自動採用: \(machine.name)(machines/ が 1 つのため)")
            }
            let resolved = try ProfileResolver.resolve(
                project: testProject, runName: profile, machineName: machine.name)
            for warning in resolved.warnings { logStderr("⚠️ \(warning)") }
            if resolved.iosFastInput { setenv("FT_FAST_INPUT", "1", 1) }  // BridgeClient.fastInput 参照
            resolvedProfile = resolved
        }

        // ワーカー並列実行経路のときだけビルドと並行してワーカー(iOSブリッジ起動/Android照合+
        // インストール)を先行構築する。build/list/selected の解決が途中で throw した場合、この
        // Task は待たずプロセスごと終了してよい: detach 起動されたブリッジ(xcodebuild/simctl)は
        // 常駐資産として残り次回再利用されるため無害
        // Android(serial 照合+インストール確認=数秒)と iOS(ブリッジ供給=壊れたブリッジの
        // 置き換えで数十秒かかりうる)を分離する。Android は先行ワーカーとして即時実行を開始し、
        // iOS は RunOrchestrator の lateWorkers として供給完了後に合流する(実測: 供給待ちで
        // 全ワーカーの開始が 10s→81s に悪化した対策。2026-07-18)。
        let androidWorkersTask: Task<[RunWorker], Error>?
        var iosWorkersTask: Task<[RunWorker], Never>?
        if let resolvedProfile, !dryRun, debugOptions == nil {
            let resolved = resolvedProfile
            androidWorkersTask = Task {
                let deviceList = resolved.devices
                    .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
                logStderr("🧩 プロファイル \(resolved.runName): \(resolved.appName) @ \(resolved.machineName)")
                logStderr("   デバイス: \(deviceList)")
                var wipedAndroid: [String] = []
                if resolved.wipeDataOnBloat {
                    wipedAndroid = await AndroidDataWiper.wipeBloatedAVDs(
                        devices: resolved.androidDevices,
                        thresholdGB: resolved.wipeDataThresholdGB,
                        locale: resolved.locale,
                        status: { self.emitLine(ApiWipeStatusEvent(device: $0, phase: $1)) },
                        log: { logStderr($0) })
                }
                var workers = try await ProfileWorkerFactory.buildAndroidWorkers(
                    resolved: resolved) { logStderr($0) }
                workers = try await ProfileWorkerFactory.installIfNeeded(
                    apps: resolved.apps, workers: workers,
                    forceAndroidInstall: !wipedAndroid.isEmpty) { logStderr($0) }
                if !workers.isEmpty {
                    logStderr("🚀 Android \(workers.count) ワーカーで開始(iOS はブリッジ供給完了後に合流)")
                }
                return workers
            }
            if !resolved.iosDevices.isEmpty {
                iosWorkersTask = Task {
                    do {
                        var workers = try await ProfileWorkerFactory.buildIOSWorkers(
                            resolved: resolved, repoRoot: try RepoRoot.find()) { logStderr($0) }
                        workers = (try? await ProfileWorkerFactory.installIfNeeded(
                            apps: resolved.apps, workers: workers,
                            forceAndroidInstall: false) { logStderr($0) }) ?? workers
                        logStderr("🚀 iOS \(workers.count) ワーカーが合流")
                        return workers
                    } catch {
                        // iOS 供給失敗は run 全体を落とさない(iOS シナリオはワーカー不在として
                        // ドレインで失敗確定し、Android の結果は生きる)
                        logStderr("❌ iOS ワーカー構築に失敗しました: \(error.localizedDescription)")
                        return []
                    }
                }
            }
        } else {
            androidWorkersTask = nil
        }

        // ビルドはホスト側で 1 回だけ(サブプロセスは自らビルドしない)
        if !skipBuild {
            logStderr("→ シナリオをビルド(\(testProject.name))...")
            try ScenarioHost.build(project: testProject) { logStderr($0) }
        }

        let all = try ScenarioHost.list(project: testProject)
        guard !all.isEmpty else {
            throw ValidationError(
                "シナリオがありません(Projects/\(testProject.name)/Scenarios/ に @TestClass を追加してください)")
        }
        let selected = try RunScenarios.resolve(scenarios, from: all)
        guard !selected.isEmpty else {
            throw ValidationError("実行対象がありません(全シナリオが削除済み @Deleted)")
        }

        // dry-run/debug は実測にならない(dry-run はデバイス未接続、debug は人間介入前提)ため記録しない
        let recorder: RunRecorder? = (!dryRun && debugOptions == nil)
            ? RunRecorder.begin(project: testProject, profile: profile, trigger: "api")
            : nil

        emitLine(ApiRunStartedEvent(total: selected.count))

        let outcome: RunOutcome
        if let resolvedProfile {
            // --dry-run/--debug は単純な逐次実行のまま(worker フィールド無し)。それ以外は
            // RunOrchestrator による並列実行
            if dryRun || debugOptions != nil {
                outcome = try await runWithProfile(
                    resolved: resolvedProfile, project: testProject, selected: selected,
                    debugOptions: debugOptions, recorder: recorder)
            } else {
                let workers = try await androidWorkersTask!.value
                outcome = try await runWithProfileParallel(
                    resolved: resolvedProfile, project: testProject, selected: selected,
                    workers: workers, iosWorkersTask: iosWorkersTask, recorder: recorder)
            }
        } else {
            outcome = await runDirect(
                project: testProject, selected: selected, debugOptions: debugOptions,
                recorder: recorder)
        }

        recorder?.finish(total: selected.count, passed: outcome.passed, failed: outcome.failed,
                         degradedWorkers: outcome.degradedWorkers,
                         freezeRetries: outcome.freezeRetries)
        if !outcome.degradedWorkers.isEmpty {
            logStderr("⚠️ 劣化・離脱したワーカー(\(outcome.degradedWorkers.count)):")
            for entry in outcome.degradedWorkers { logStderr("   - \(entry)") }
        }
        if !outcome.freezeRetries.isEmpty {
            logStderr("🔁 結果取り消し+振り直し(\(outcome.freezeRetries.count)):")
            for entry in outcome.freezeRetries { logStderr("   - \(entry)") }
        }
        emitLine(ApiRunFinishedEvent(passed: outcome.passed, failed: outcome.failed,
                                     testSeconds: outcome.testSeconds,
                                     scenarioTotalSeconds: outcome.scenarioTotalSeconds))

        if outcome.failed > 0 {
            throw ExitCode(1)
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
                heal: heal, reportDir: reportDirPath, defaultTimeout: defaultTimeout,
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
        let effectiveHeal = heal ? true : resolved.heal
        let reportDirPath = (reportDir.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir).path

        var workers: [RunWorker] = []
        if !dryRun {
            let deviceList = resolved.devices
                .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
            logStderr("🧩 プロファイル \(profileName): \(resolved.appName) @ \(resolved.machineName)")
            logStderr("   デバイス: \(deviceList)")
            var wipedAndroid: [String] = []
            if resolved.wipeDataOnBloat {
                wipedAndroid = await AndroidDataWiper.wipeBloatedAVDs(
                    devices: resolved.androidDevices,
                    thresholdGB: resolved.wipeDataThresholdGB,
                    locale: resolved.locale,
                    status: { self.emitLine(ApiWipeStatusEvent(device: $0, phase: $1)) },
                    log: { logStderr($0) })
            }
            workers = try await ProfileWorkerFactory.buildWorkers(
                resolved: resolved, repoRoot: try RepoRoot.find()) { logStderr($0) }
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
                    ? "なし" : workers.map(\.label).joined(separator: ", ")
                let reason = "platform \"\(scenarioPlatform)\" に対応するワーカーがありません"
                    + "(プロファイル \(profileName) のワーカー: \(workerList))"
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
            let passed = await ScenarioHost.run(
                project: project, scenarioID: info.id, connection: connection,
                heal: effectiveHeal, reportDir: reportDirPath,
                defaultTimeout: resolved.defaultTimeout,
                scenarioTimeout: resolved.scenarioTimeout, dryRun: dryRun,
                debug: debugOptions, recording: recording) { event in
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
        let effectiveHeal = heal ? true : resolved.heal
        let reportDirURL = reportDir.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir

        // workersReady はレーン構成の全置換(runLaneModel.applyWorkers が lanes.clear する)ため
        // 1回だけ・全ワーカー分を宣言する。iOS はブリッジ供給前でも id("ios:論理名")が確定する
        // ので、供給待ちを表す detail 付きのプレースホルダで先に載せる(port は表示のみの情報)。
        var readyInfo = workersReadyInfo(workers)
        if iosWorkersTask != nil {
            readyInfo += resolved.iosDevices.map {
                ApiWorkerInfo(id: "ios:\($0.name)", name: $0.name, platform: "ios",
                              detail: "ブリッジ供給中...")
            }
        }
        emitLine(ApiWorkersReadyEvent(workers: readyInfo))

        // シナリオが platform 未指定のときの既定 platform(既存の runWithProfile と同じ方針。
        // iOS は遅延参加のため resolved 側で判定する)
        let defaultPlatform = (!resolved.iosDevices.isEmpty
            || workers.contains { $0.platform == "ios" }) ? "ios" : "android"

        let items = selected.map { ScenarioRunItem(info: $0) }
        // RunEvent の flowURL(scenario:// URL)→ 元の ScenarioInfo の逆引き。
        // RunEvent は scenario ID・title を毎回運んでくれないため、変換時にここから補う
        let itemByURL = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0) })
        // RunEvent の worker(= RunWorker.label)→ workersReady と同じ id 文字列への変換表。
        // iOS ワーカーは遅延参加(lateWorkers)で後から merge されるためロック付きの箱にする
        let workerID = WorkerIDMap(workers)

        // run-lease(.ftester/run-<key>.lease)。best-effort: リポジトリ外実行等で root が
        // 取れない場合は書かない(monitor 側の inRun 判定が false になるだけで安全)
        let leaseStateDir = (try? RepoRoot.find())?.appendingPathComponent(".ftester")

        let orchestrator = RunOrchestrator(
            project: project, workers: workers, healingEnabled: effectiveHeal,
            reportDir: reportDirURL, defaultTimeout: resolved.defaultTimeout,
            scenarioTimeout: resolved.scenarioTimeout, recorder: recorder,
            isDeviceFrozen: { serial in
                // 事後判定は isBlankObserved(窓内に一度でも blank)。isPersistentlyBlank だと
                // 約25秒周期のフラッピングの回復側を引いて凍結を見逃す(実測 2026-07-18)
                await AndroidHealthProbe.isBlankObserved(serial: serial)
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
                    _ = try await BridgeClient(port: port).status(timeout: 5)
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
            cleanupRetiredWorker: { retired in
                // ウェッジした旧ブリッジ(/status 無応答)は provision の再利用スキャンに映らないまま
                // 生き残り、シミュレータを掴み続ける。離脱検知の時点で UDID 照合で明示停止する
                // (revive 内でなくここに置く理由: 復帰を試みない離脱でも必ず kill するため)
                guard let udid = retired.connection.udid else { return }  // udid は iOS のみ
                let stopped = BridgeLauncher.stopMatching(udid: udid, repoRoot: repoRoot)
                if !stopped.isEmpty {
                    logStderr("🔧 旧ブリッジを停止しました: port \(stopped.joined(separator: ", "))")
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
                        return installed.first ?? w
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
            })
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        var timing = ScenarioTimingTracker()
        for await event in orchestrator.events {
            timing.record(event)
            for line in ndjsonLines(for: event, itemByURL: itemByURL, workerID: workerID) {
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
    private func ndjsonLines(
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
            log.message = "❌ ワーカー \(log.worker ?? worker) が離脱しました: \(message)"
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
            }
            // 時間内訳(RunOrchestrator.swift の ScenarioRunner.stepResult(from:) から復元済み)
            step.durationMs = result.timing?.durationMs
            step.snapshotMs = result.timing?.snapshotMs
            step.actionMs = result.timing?.actionMs
            step.waitMs = result.timing?.waitMs
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

        case .flowFinished(let worker, let flowURL, let passed, _, let reportURL):
            var finished = ScenarioEvent(kind: "scenarioFinished")
            finished.worker = workerID.id(for: worker)
            finished.scenario = itemByURL[flowURL]?.info.id
            finished.passed = passed
            finished.reportPath = reportURL?.path
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
            step.description = "ワーカー未検出"
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
        step.description = "ワーカー未検出"
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

/// ftester api run の冒頭イベント
private struct ApiRunStartedEvent: Encodable {
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
/// 同一規則。VSCode 拡張がモニタータイルと突合するため)
private struct ApiWorkersReadyEvent: Encodable {
    let kind = "workersReady"
    let workers: [ApiWorkerInfo]
}

/// ApiWorkersReadyEvent の 1 ワーカー分
private struct ApiWorkerInfo: Encodable {
    let id: String
    let name: String
    let platform: String
    let detail: String
}

/// ftester api run の末尾イベント。vscode-ftester/src/model.ts の RunFinishedEvent と
/// フィールド名を同期(testSeconds/scenarioTotalSeconds のリネーム不可)
private struct ApiRunFinishedEvent: Encodable {
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
}

/// flowStarted〜flowFinished から testSeconds(最初の開始〜最後の完了)と
/// scenarioTotalSeconds(シナリオ毎の所要時間の合計)を計測する。並列実行では
/// record(_:) で RunEvent の flowStarted/flowFinished を渡す(flowURL をキーに対応付ける。
/// flowSkipped は無視 = 0秒扱い)。逐次実行では recordSequential(start:finish:) を
/// シナリオ毎に直接呼ぶ(同時に1件しか走らないため URL キー付けは不要)。ProfileRunner.swift
/// からも同一ターゲット内で参照
struct ScenarioTimingTracker {
    private var firstStart: Date?
    private var lastFinish: Date?
    private var startedAt: [URL: Date] = [:]
    private var scenarioTotal: TimeInterval = 0
    private var hasScenario = false

    mutating func record(_ event: RunEvent) {
        switch event {
        case .flowStarted(_, let flowURL, _, _):
            let now = Date()
            if firstStart == nil { firstStart = now }
            startedAt[flowURL] = now
            hasScenario = true
        case .flowFinished(_, let flowURL, _, _, _):
            let now = Date()
            lastFinish = now
            if let start = startedAt.removeValue(forKey: flowURL) {
                scenarioTotal += now.timeIntervalSince(start)
            }
        default:
            break
        }
    }

    mutating func recordSequential(start: Date, finish: Date) {
        if firstStart == nil { firstStart = start }
        lastFinish = finish
        scenarioTotal += finish.timeIntervalSince(start)
        hasScenario = true
    }

    var testSeconds: Double? {
        guard let firstStart, let lastFinish else { return nil }
        return lastFinish.timeIntervalSince(firstStart)
    }

    var scenarioTotalSeconds: Double? { hasScenario ? scenarioTotal : nil }
}
