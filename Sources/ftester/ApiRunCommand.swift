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
            resolvedProfile = resolved
        }

        // ワーカー並列実行経路のときだけビルドと並行してワーカー(iOSブリッジ起動/Android照合+
        // インストール)を先行構築する。build/list/selected の解決が途中で throw した場合、この
        // Task は待たずプロセスごと終了してよい: detach 起動されたブリッジ(xcodebuild/simctl)は
        // 常駐資産として残り次回再利用されるため無害
        let workersTask: Task<[RunWorker], Error>?
        if let resolvedProfile, !dryRun, debugOptions == nil {
            let resolved = resolvedProfile
            workersTask = Task {
                let deviceList = resolved.devices
                    .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
                logStderr("🧩 プロファイル \(resolved.runName): \(resolved.appName) @ \(resolved.machineName)")
                logStderr("   デバイス: \(deviceList)")
                var workers = try await ProfileWorkerFactory.buildWorkers(
                    resolved: resolved, repoRoot: try RepoRoot.find()) { logStderr($0) }
                workers = try await ProfileWorkerFactory.installIfNeeded(
                    apps: resolved.apps, workers: workers) { logStderr($0) }
                logStderr("🚀 実行: \(workers.count) ワーカー(\(workers.map(\.label).joined(separator: " / ")))")
                return workers
            }
        } else {
            workersTask = nil
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

        emitLine(ApiRunStartedEvent(total: selected.count))

        let passedCount: Int
        let failedCount: Int
        if let resolvedProfile {
            // --dry-run/--debug は単純な逐次実行のまま(worker フィールド無し)。それ以外は
            // RunOrchestrator による並列実行
            if dryRun || debugOptions != nil {
                (passedCount, failedCount) = try await runWithProfile(
                    resolved: resolvedProfile, project: testProject, selected: selected,
                    debugOptions: debugOptions)
            } else {
                let workers = try await workersTask!.value
                (passedCount, failedCount) = try await runWithProfileParallel(
                    resolved: resolvedProfile, project: testProject, selected: selected,
                    workers: workers)
            }
        } else {
            (passedCount, failedCount) = await runDirect(
                project: testProject, selected: selected, debugOptions: debugOptions)
        }

        emitLine(ApiRunFinishedEvent(passed: passedCount, failed: failedCount))

        if failedCount > 0 {
            throw ExitCode(1)
        }
    }

    // MARK: - --platform/--port/--serial 直接指定(--profile 未指定)

    private func runDirect(project: TestProject, selected: [ScenarioInfo],
                           debugOptions: ScenarioDebugOptions?) async -> (passed: Int, failed: Int) {
        let effectivePlatform = platform ?? "ios"
        let effectivePort = port ?? BridgeAPI.defaultPort
        let reportDirPath = reportDir ?? project.reportsDir.path

        var passedCount = 0
        var failedCount = 0
        for info in selected {
            let scenarioPlatform = info.platform ?? effectivePlatform
            let connection = scenarioPlatform == "android"
                ? DriverConnection(platform: "android", serial: serial)
                : DriverConnection(platform: "ios", port: effectivePort)

            let passed = await ScenarioHost.run(
                project: project, scenarioID: info.id, connection: connection,
                heal: heal, reportDir: reportDirPath, defaultTimeout: defaultTimeout,
                dryRun: dryRun, debug: debugOptions) { event in
                // host 発の log イベント等、scenario 未設定のものは現在のシナリオ ID を補う
                var event = event
                if event.scenario == nil { event.scenario = info.id }
                writeLine(event.encodedLine())
            }
            if passed { passedCount += 1 } else { failedCount += 1 }
        }
        return (passedCount, failedCount)
    }

    // MARK: - --profile 指定

    /// resolved のワーカーを構築し、各シナリオを platform に合う最初のワーカーで逐次実行する
    /// (ProfileRunner と違い並列化しない)。--dry-run はワーカー構築自体を省略し、
    /// defaultTimeout/heal の反映だけ行って NullDriver で流す
    private func runWithProfile(
        resolved: ResolvedProfile, project: TestProject,
        selected: [ScenarioInfo], debugOptions: ScenarioDebugOptions?
    ) async throws -> (passed: Int, failed: Int) {
        let profileName = resolved.runName
        let effectiveHeal = heal ? true : resolved.heal
        let reportDirPath = (reportDir.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir).path

        var workers: [RunWorker] = []
        if !dryRun {
            let deviceList = resolved.devices
                .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
            logStderr("🧩 プロファイル \(profileName): \(resolved.appName) @ \(resolved.machineName)")
            logStderr("   デバイス: \(deviceList)")
            workers = try await ProfileWorkerFactory.buildWorkers(
                resolved: resolved, repoRoot: try RepoRoot.find()) { logStderr($0) }
            workers = try await ProfileWorkerFactory.installIfNeeded(
                apps: resolved.apps, workers: workers) { logStderr($0) }
        }

        // シナリオが platform 未指定のときの既定 platform(iOS ワーカーがあれば ios 優先。
        // dry-run はワーカーを構築しないため resolved のデバイス構成から同じ方針で決める)
        let defaultPlatform: String = dryRun
            ? (resolved.iosDevices.isEmpty ? "android" : "ios")
            : (workers.contains { $0.platform == "ios" } ? "ios" : "android")

        var passedCount = 0
        var failedCount = 0
        for info in selected {
            let scenarioPlatform = info.platform ?? defaultPlatform

            let connection: DriverConnection
            if dryRun {
                connection = DriverConnection(platform: scenarioPlatform)
            } else if let worker = workers.first(where: { $0.platform == scenarioPlatform }) {
                connection = worker.connection
            } else {
                let workerList = workers.isEmpty
                    ? "なし" : workers.map(\.label).joined(separator: ", ")
                let reason = "platform \"\(scenarioPlatform)\" に対応するワーカーがありません"
                    + "(プロファイル \(profileName) のワーカー: \(workerList))"
                logStderr("⚠️ \(info.id): \(reason)")
                emitMissingWorkerFailure(info: info, reason: reason)
                failedCount += 1
                continue
            }

            let passed = await ScenarioHost.run(
                project: project, scenarioID: info.id, connection: connection,
                heal: effectiveHeal, reportDir: reportDirPath,
                defaultTimeout: resolved.defaultTimeout, dryRun: dryRun,
                debug: debugOptions) { event in
                var event = event
                if event.scenario == nil { event.scenario = info.id }
                writeLine(event.encodedLine())
            }
            if passed { passedCount += 1 } else { failedCount += 1 }
        }
        return (passedCount, failedCount)
    }

    // MARK: - --profile 指定(ワーカー並列実行。--dry-run/--debug 以外)

    /// 全ワーカーを RunOrchestrator(FTCore)に渡し ProfileRunner と同じ並列度で実行する。
    /// 進捗は RunEvent(Codable ではない)で届くため ndjsonLines(for:itemByURL:workerID:) で
    /// ScenarioEvent 相当の NDJSON 行に変換する(失われる情報がある点に注意)。
    /// workers はビルドと並行して呼び出し側(run())が先行構築済みのもの
    private func runWithProfileParallel(
        resolved: ResolvedProfile, project: TestProject, selected: [ScenarioInfo],
        workers: [RunWorker]
    ) async throws -> (passed: Int, failed: Int) {
        let effectiveHeal = heal ? true : resolved.heal
        let reportDirURL = reportDir.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir

        emitLine(ApiWorkersReadyEvent(workers: workersReadyInfo(workers)))

        // シナリオが platform 未指定のときの既定 platform(既存の runWithProfile と同じ方針)
        let defaultPlatform = workers.contains { $0.platform == "ios" } ? "ios" : "android"

        let items = selected.map { ScenarioRunItem(info: $0) }
        // RunEvent の flowURL(scenario:// URL)→ 元の ScenarioInfo の逆引き。
        // RunEvent は scenario ID・title を毎回運んでくれないため、変換時にここから補う
        let itemByURL = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0) })
        // RunEvent の worker(= RunWorker.label)→ workersReady と同じ id 文字列への変換表
        let workerID = Dictionary(uniqueKeysWithValues: workers.map {
            ($0.label, "\($0.platform):\($0.logicalName ?? $0.label)")
        })

        let orchestrator = RunOrchestrator(
            project: project, workers: workers, healingEnabled: effectiveHeal,
            reportDir: reportDirURL, defaultTimeout: resolved.defaultTimeout)
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        for await event in orchestrator.events {
            for line in ndjsonLines(for: event, itemByURL: itemByURL, workerID: workerID) {
                writeLine(line)
            }
        }

        let result = await summary
        return (result.passed, result.failed)
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
        for event: RunEvent, itemByURL: [URL: ScenarioRunItem], workerID: [String: String]
    ) -> [String] {
        switch event {
        case .runStarted, .workerReady, .runFinished, .flowHealed, .flowPaused:
            // runStarted/runFinished は呼び出し側で emit 済み。flowHealed は現行シナリオでは
            // 発生しない旧互換。flowPaused はデバッグ専用でこの並列経路には来ない
            return []

        case .sceneStarted(let worker, let flowURL, let scene, let sceneTitle):
            var started = ScenarioEvent(kind: "sceneStarted")
            started.worker = workerID[worker] ?? worker
            started.scenario = itemByURL[flowURL]?.info.id
            started.scene = scene
            started.sceneTitle = sceneTitle
            return [started.encodedLine()]

        case .sceneFinished(let worker, let flowURL, let scene, let sceneTitle, let passed):
            var finished = ScenarioEvent(kind: "sceneFinished")
            finished.worker = workerID[worker] ?? worker
            finished.scenario = itemByURL[flowURL]?.info.id
            finished.scene = scene
            finished.sceneTitle = sceneTitle
            finished.passed = passed
            return [finished.encodedLine()]

        case .workerFailed(let worker, let message):
            var log = ScenarioEvent(kind: "log")
            log.worker = workerID[worker] ?? worker
            log.message = "❌ ワーカー \(log.worker ?? worker) が離脱しました: \(message)"
            return [log.encodedLine()]

        case .flowStarted(let worker, let flowURL, let flowName, _):
            var started = ScenarioEvent(kind: "scenarioStarted")
            started.worker = workerID[worker] ?? worker
            started.scenario = flowName
            started.title = itemByURL[flowURL]?.info.title
            return [started.encodedLine()]

        case .step(let worker, let flowURL, let result):
            // fixSuggestion に付随する合成 step(ScenarioRunner.runOne 参照)は次の
            // .fixSuggestion で kind:"fixSuggestion" として出すため重複emitを避けて捨てる
            if result.synthetic { return [] }

            let workerIDValue = workerID[worker] ?? worker
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
            suggestion.worker = workerID[worker] ?? worker
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
            finished.worker = workerID[worker] ?? worker
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

/// ftester api run の末尾イベント
private struct ApiRunFinishedEvent: Encodable {
    let kind = "runFinished"
    let passed: Int
    let failed: Int
}
