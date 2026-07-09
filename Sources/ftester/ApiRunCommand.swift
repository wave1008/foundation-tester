// ApiRunCommand.swift
// VSCode拡張等の外部ツール向け機械可読 CLI(ftester api run)。
// シナリオを逐次実行し、NDJSON(1 行 1 イベント)を stdout に流す。
// stdout には runStarted / ScenarioEvent(そのまま再emit)/ runFinished 以外は出さない
// (診断は stderr のみ。ApiCommands.swift と同じ流儀)。
//
// --profile 指定時は実行プロファイル(profiles/runs/<name>.json)を解決してワーカー
// (iOS ブリッジ供給+Android 照合。実体は ProfileWorkerFactory)を構築し、各シナリオを
// その platform に合う最初のワーカーで逐次実行する(並列化はしない。ftester run --profile の
// ProfileRunner とはワーカー選択方針が異なるだけで、構築の実体は共用する)。
// --dry-run 時はデバイス不要なため、ワーカー構築(実機・シミュレータ照合)を丸ごと省略する。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "シナリオを逐次実行し、NDJSON イベント(runStarted → 各種 ScenarioEvent → "
            + "runFinished)を stdout に流す(診断は stderr のみ。--debug 時は stdin の制御"
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
        // paused 等のイベントがパイプ既定の全バッファに滞留すると、読み手(VSCode 拡張)と
        // 相互待ちになる(ScenarioRunnerMain.swift の --debug 実装と同じ理由)。
        // --debug でなくてもストリーミング読み取りが前提なので常に行バッファにする
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

        // ビルドはホスト側で 1 回だけ(サブプロセスは自らビルドしない)
        if !skipBuild {
            logStderr("→ シナリオをビルド(\(testProject.name))...")
            try ScenarioHost.build(project: testProject)
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

        // --debug: 自プロセスの stdin を専用スレッドで読み、行をそのままランナーへ渡す。
        // ScenarioHost.run が起動直後に onControl で渡す ScenarioRunControl を待つ必要が
        // あるため、書き込み先は小箱(ロック付き)経由で受け渡す
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

        // --profile の解決(マシン決定+プロファイル合成)は runStarted を出す前に済ませる。
        // 単なるタイポ等の検証エラーは、他の事前検証(プロジェクト解決・ビルド失敗等)と同様に
        // NDJSON を1行も出さないまま失敗させたい(runStarted だけ出て runFinished が来ない
        // 尻切れの NDJSON を避ける)。デバイス接続等、実行途中でしか分からない失敗は
        // runWithProfile 側で扱う(VSCode 拡張は runFinished 無しの異常終了を exit code で検知する
        // 設計になっているため、そちらは許容する)
        var resolvedProfile: ResolvedProfile?
        if let profile {
            let machine = try ProfileResolver.determineMachine(
                project: testProject, registered: LocalConfig.currentMachineName())
            if machine.auto {
                logStderr("→ マシンプロファイル自動採用: \(machine.name)(machines/ が 1 つのため)")
            }
            let resolved = try ProfileResolver.resolve(
                project: testProject, runName: profile, machineName: machine.name)
            for warning in resolved.warnings { logStderr("⚠️ \(warning)") }
            resolvedProfile = resolved
        }

        emitLine(ApiRunStartedEvent(total: selected.count))

        let passedCount: Int
        let failedCount: Int
        if let resolvedProfile {
            (passedCount, failedCount) = try await runWithProfile(
                resolved: resolvedProfile, project: testProject, selected: selected,
                debugOptions: debugOptions)
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
                print(event.encodedLine())
            }
            if passed { passedCount += 1 } else { failedCount += 1 }
        }
        return (passedCount, failedCount)
    }

    // MARK: - --profile 指定

    /// resolved(呼び出し側で解決済み)のワーカーを構築し、各シナリオをその platform に合う
    /// 最初のワーカーで逐次実行する(ftester run --profile の ProfileRunner と違い並列化しない。
    /// ワーカー構築の実体は ProfileWorkerFactory を共用する)。
    /// --dry-run 時はワーカー構築(実機・シミュレータ照合)自体を省略し、profile の解決検証と
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
                print(event.encodedLine())
            }
            if passed { passedCount += 1 } else { failedCount += 1 }
        }
        return (passedCount, failedCount)
    }

    /// 担当ワーカーが無いシナリオを scenarioFinished passed=false 相当のイベント列として
    /// stdout に流す(NDJSON 契約を保ったまま runFinished の failed に計上させるため)
    private func emitMissingWorkerFailure(info: ScenarioInfo, reason: String) {
        var started = ScenarioEvent(kind: "scenarioStarted")
        started.scenario = info.id
        started.title = info.title
        print(started.encodedLine())

        var step = ScenarioEvent(kind: "step")
        step.scenario = info.id
        step.description = "ワーカー未検出"
        step.status = "failed"
        step.detail = reason
        print(step.encodedLine())

        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.scenario = info.id
        finished.passed = false
        print(finished.encodedLine())
    }

    private func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

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

/// ftester api run の末尾イベント
private struct ApiRunFinishedEvent: Encodable {
    let kind = "runFinished"
    let passed: Int
    let failed: Int
}
