// ftester-scenarios(Scenarios/ ターゲット)の CLI 実装。
//   list [--json]                       … シナリオ一覧
//   run --scenario <クラス名.メソッド名>  … 1 シナリオを実行(1 プロセス = 1 シナリオ)
// --json 指定時は NDJSON イベント(FTCore/ScenarioEvent)を stdout に流す。
// ホスト(CLI/MCP)は ScenarioHost 経由でサブプロセスとして起動する。

import ArgumentParser
import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore
import FTDSL

public enum ScenarioRunnerMain {
    public static func main() async {
        await Root.main()
    }
}

struct Root: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ftester-scenarios",
        abstract: "Swift DSL シナリオの一覧と実行(ftester run から呼ばれるランナー)",
        subcommands: [ListScenarios.self, RunScenario.self]
    )
}

// MARK: - list

struct ListScenarios: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "シナリオ一覧を表示する")

    @Flag(help: "JSON で出力する")
    var json = false

    func run() async throws {
        let classes = ScenarioDiscovery.allTestClasses()
        if json {
            var entries: [ScenarioInfo] = []
            for testClass in classes {
                for scenario in testClass.scenarios {
                    entries.append(ScenarioInfo(
                        id: "\(testClass.className).\(scenario.name)",
                        title: scenario.title,
                        app: testClass.app,
                        platform: testClass.platform,
                        deleted: scenario.deleted))
                }
            }
            struct ListResponse: Codable { let scenarios: [ScenarioInfo] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(ListResponse(scenarios: entries))
            print(String(data: data, encoding: .utf8)!)
        } else {
            guard !classes.isEmpty else {
                print("シナリオがありません(プロジェクトの Scenarios/ に @TestClass を追加してください)")
                return
            }
            for testClass in classes {
                let platform = testClass.platform ?? "ios/android"
                print("\(testClass.className) [\(platform)] app=\(testClass.app)")
                for scenario in testClass.scenarios {
                    let title = scenario.title.isEmpty ? "" : " — \(scenario.title)"
                    let deleted = scenario.deleted ? "(削除済み)" : ""
                    print("  ・ \(testClass.className).\(scenario.name)\(title)\(deleted)")
                }
            }
        }
    }
}

// MARK: - run

struct RunScenario: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "シナリオを 1 つ実行する")

    @Option(help: "シナリオ ID(クラス名.メソッド名)")
    var scenario: String

    @Option(help: "対象プラットフォーム: ios / android")
    var platform: String = "ios"

    @Option(help: "ブリッジのポート番号(iOS のみ)")
    var port: UInt16 = BridgeAPI.defaultPort

    @Option(help: "Android デバイスのシリアル(adb -s。省略時は唯一の接続デバイス)")
    var serial: String?

    @Option(help: "iOS 駆動エンジン: xcuitest(既定)/ inapp(dylib 注入)/ hybrid(in-app+XCUITest)")
    var engine: String?

    @Option(help: "iOS: シミュレータ UDID(inapp/hybrid の再起動、xcuitest の launch 事前検査に使用)")
    var udid: String?

    @Option(name: .customLong("xcui-port"), help: "iOS: hybrid のフォールバック用 XCUITest ブリッジのポート")
    var xcuiPort: UInt16?

    @Option(name: .customLong("inapp-app"),
            help: "iOS: provision 時に in-app ブリッジを注入したアプリの bundleID(suspend 時の注入先判定用)")
    var inappApp: String?

    @Option(name: .customLong("device-name"),
            help: "実行プロファイル上のデバイス論理名(レポートヘッダ表示用。orchestrator から渡される)")
    var deviceName: String?

    @Flag(help: "FM によるロケータ自己修復を許可する")
    var heal = false

    @Option(name: .customLong("report-dir"), help: "レポート出力先ディレクトリ")
    var reportDir: String = "reports"

    @Option(name: .customLong("project-dir"),
            help: "テストプロジェクトのルート(ヒールキャッシュ等の状態保存先。省略時はカレント)")
    var projectDir: String?

    @Option(name: .customLong("default-timeout"),
            help: "検証コマンド(exist/textIs 等)の既定タイムアウト秒(省略時 5)")
    var defaultTimeout: Int?

    @Flag(help: "NDJSON イベントを出力する(ホスト連携用)")
    var json = false

    @Flag(name: .customLong("dry-run"),
          help: "デバイスに触れず全コマンドを記録のみで通過させる(ステップ列挙・レビュー用)")
    var dryRun = false

    @Flag(help: "stdin から一時停止・再開の制御コマンド(NDJSON)を受け付ける(デバッグ実行用)")
    var debug = false

    @Option(name: .customLong("breakpoint"),
            help: "ブレークポイント(<file>:<line>。--debug 時のみ有効、複数指定可)")
    var breakpoint: [String] = []

    @Flag(name: .customLong("pause-on-start"),
          help: "最初のステップの手前で一時停止して開始する(--debug 時のみ有効)")
    var pauseOnStart = false

    func run() async throws {
        // stdout を常に行バッファにする(パイプ既定は全バッファでプロセス終了まで滞留)。2つの理由:
        //   - step 等イベントを実行中に逐次ホストへ届ける(ライブ操作パネルの操作記録の都度更新など)
        //   - --debug の paused イベントがパイプに滞留するとホストと相互待ちでデッドロックする
        // ホスト側 stdout も同様に常時行バッファ(ApiRunCommand.swift の setvbuf(_IOLBF))。
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let (testClass, descriptor) = ScenarioDiscovery.find(id: scenario) else {
            let available = ScenarioDiscovery.allTestClasses()
                .flatMap { c in c.scenarios.map { "\(c.className).\($0.name)" } }
            FileHandle.standardError.write(Data(
                ("シナリオが見つかりません: \(scenario)\n利用可能: \(available.joined(separator: ", "))\n")
                    .utf8))
            throw ExitCode(64)
        }

        let scenarioID = "\(testClass.className).\(descriptor.name)"
        let runPlatform = testClass.platform ?? platform

        // ドライバ構築(FTester.swift の DriverOptions と同じパターン)。
        // hybrid: primary=in-app、fallback=XCUITest ブリッジ(springboard 参照)を StepExecutor へ。
        let driver: AppDriver
        var fallbackDriver: AppDriver?
        // typeDriver は常に渡す(409 安全網)。preferTypeDriver は probe の uiFramework 検出時のみ
        // (probe 不達なら false のまま=安全網頼み)。
        var typeDriver: AppDriver?
        var preferTypeDriver = false
        if dryRun {
            driver = NullDriver()  // dry-run はデバイスに触れない
        } else {
            switch runPlatform {
            case "ios":
                if engine == "inapp" || engine == "hybrid" {
                    // in-app は注入先アプリのプロセスしか駆動できない。シナリオの対象アプリが
                    // 注入先(/status の sessionBundleID)と異なる場合、別アプリを注入起動すると
                    // ポート衝突で旧ブリッジが偽成功応答し「裏のアプリを操作して失敗」する。
                    // hybrid はそのシナリオを丸ごと XCUITest ブリッジで駆動、inapp は明示エラー。
                    //
                    // suspend 対策: 直前が別アプリ(system-UI)のシナリオだと注入先アプリは
                    // バックグラウンドで iOS に suspend され、in-app ブリッジは TCP を受理するが
                    // 応答しない(既定 45s で「ドライバに接続できません: The request timed out」ハング)。
                    // 短いタイムアウトでプローブし、無応答時は provision 時の注入先(inappApp)を
                    // 注入先とみなす。これで対象アプリ==注入先なら InAppDriver(冒頭 launchApp が
                    // relaunch で bridge を張り直す)、別アプリ(Preferences 等)なら mismatch=XCUITest
                    // へ正しく分岐する。inappApp を使わず nil を「不明」扱いにすると、suspend 中の
                    // 別アプリシナリオを in-app 経路へ誤ルーティングして破綻する(実際に回帰した)。
                    let probe = BridgeClient(port: port, timeoutSeconds: 4)
                    let probeStatus = try? await probe.status(timeout: 4)
                    let injected = probeStatus?.sessionBundleID ?? inappApp
                    if let injected, injected != testClass.app {
                        guard engine == "hybrid", let xcuiPort else {
                            throw ValidationError(
                                "シナリオ \(scenarioID) の対象アプリ \(testClass.app) は in-app ブリッジの"
                                + "注入先 \(injected) と異なるため engine=inapp では実行できません。"
                                + "engine 明示のないデバイス(実行プロファイルの iosInappEngine 既定ON="
                                + "hybrid)で実行すると XCUITest 経由で自動駆動されます"
                                + "(engine=inapp 明示デバイスには iosInappEngine は適用されません)")
                        }
                        let client = BridgeClient(port: xcuiPort)
                        driver = udid.map { LaunchPreflightDriver(base: client, udid: $0) } ?? client
                    } else {
                        // in-app は launch=simctl 再起動+dylib 注入(自己再起動できないため)
                        let repoRoot = try RepoRoot.find()
                        driver = InAppDriver(repoRoot: repoRoot, udid: udid ?? "booted", port: port)
                        if engine == "hybrid", let xcuiPort {
                            fallbackDriver = SystemUIDriver(port: xcuiPort)
                            typeDriver = AppAttachDriver(port: xcuiPort, bundleID: testClass.app)
                            // 2026-07-21 から Compose も inapp で type 可能
                            // (IntermediateTextInputUIView への insertText。InAppInput.m 参照。
                            // 実測 266ms vs attach 1.0〜1.3s)。attach 優先は廃止し、
                            // 失敗時 409 → typeDriver フォールバック(StepExecutor)だけを安全網とする
                            preferTypeDriver = false
                        }
                    }
                } else {
                    let client = BridgeClient(port: port)
                    // launch は既定で simctl 化(FastLaunchDriver。実測 -14〜19%)。
                    // FT_NO_FAST_LAUNCH=1 で従来の XCUIApplication.launch() に戻せる。
                    // preflight(未インストール検査)は fast launch の外側に置く
                    let noFastLaunch = ProcessInfo.processInfo.environment["FT_NO_FAST_LAUNCH"] == "1"
                    let inner: AppDriver = (!noFastLaunch && udid != nil)
                        ? FastLaunchDriver(base: client, udid: udid!) : client
                    driver = udid.map { LaunchPreflightDriver(base: inner, udid: $0) } ?? client
                }
            case "android":
                driver = try AndroidDriver(serial: serial)
            default:
                throw ValidationError("platform は ios / android のいずれかです: \(runPlatform)")
            }
            // InAppDriver は注入先アプリが suspend 中だと status がハングし(上記 suspend 対策参照)、
            // かつ冒頭 launchApp の relaunch で必ず bridge を張り直すため pre-flight の接続確認はしない。
            // XCUITest / Android の常駐ドライバのみ、接続不能を早期に分かりやすく失敗させる。
            if !(driver is InAppDriver) {
                _ = try await driver.status()
            }
        }

        let delegate = LazyFMDelegate()  // 遅延初期化の理由は class doc 参照

        let emit: (ScenarioEvent) -> Void = json
            ? { print($0.encodedLine()) }
            : { event in
                for line in ScenarioLogFormatter.lines(for: event) { print(line) }
            }

        var started = ScenarioEvent(kind: "scenarioStarted")
        started.scenario = scenarioID
        started.title = descriptor.title
        emit(started)

        let healCacheURL = projectDir.map {
            URL(fileURLWithPath: $0).appendingPathComponent(".ftester/heal-cache.json")
        }
        // 技術識別子: Android は adb serial、iOS はシミュレータ UDID(共に既存のドライバ構築引数の再利用)
        let deviceIdentifier = runPlatform == "android" ? serial : udid
        let core = FTDriveCore(driver: driver, platform: runPlatform, app: testClass.app,
                               scenarioID: scenarioID, scenarioTitle: descriptor.title,
                               delegate: delegate, healingEnabled: heal, dryRun: dryRun,
                               healCacheURL: healCacheURL, defaultTimeout: defaultTimeout,
                               fallbackDriver: fallbackDriver,
                               typeDriver: typeDriver, preferTypeDriver: preferTypeDriver,
                               deviceName: deviceName, deviceIdentifier: deviceIdentifier,
                               emit: emit)

        if debug {
            let control = ScenarioDebugControl(breakpoints: breakpoint,
                                               pauseOnStart: pauseOnStart)
            core.debugControl = control
            // stdin の制御コマンドは専用スレッドで読む(DSL スレッドは停止中ブロックする)。
            // EOF(ホスト終了)で読み終わり、プロセス終了とともに消える
            let reader = Thread {
                while let line = readLine(strippingNewline: true) {
                    control.apply(line: line)
                }
            }
            reader.name = "ftester-debug-control"
            reader.start()
        }

        // シナリオ本体は専用スレッドで同期実行(協調スレッドプールを塞がない)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                descriptor.run()
                continuation.resume()
            }
            thread.name = "ftester-dsl"
            thread.stackSize = 4 << 20
            FTRuntime.bootstrap(core: core, dslThread: thread)
            thread.start()
        }
        FTRuntime.tearDown()

        let record = core.finalRecord
        let reportURL = try? ScenarioReportWriter.write(
            record: record, to: URL(fileURLWithPath: reportDir))

        // デバッグの stop で中断した場合は成功扱いにしない(確認まで到達していない)
        let passed = record.passed && !core.stoppedByUser
        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.scenario = scenarioID
        finished.passed = passed
        finished.reportPath = reportURL?.path
        // FM 実測を親へ運ぶ(→ ScenarioRecordBuilder → 結果 JSON の fm)。run 全体で合算すると
        // 「FM 直列化による実行時間の下限」が出る。ANE 負荷率では測れない(FMHealth の doc 参照)
        finished.fm = FMHealth.usage()
        emit(finished)

        // FM 失敗は各呼び出し箇所が nil を返して素通りさせる契約のため、結果からは見えない。
        // stdout は NDJSON 契約なので診断は stderr へ出す(api host-metrics と同じ方針)。
        // **失敗時だけ**にすること: 子の stderr は ScenarioHost が1行ずつ "⚠️ " 付きの log
        // イベントへ変換し、ScenarioRecordBuilder がそれを errorLogs(上限5件)へ入れる。
        // 情報行を出すと、インフラ失敗の原因を残すための errorLogs が押し出されて潰れる(実害あり)。
        // FM のコスト(回数・レイテンシ)は結果 JSON の fm とモニターの FM グラフで見る。
        if let warning = FMHealth.warningText() {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }

        if !passed {
            throw ExitCode(1)
        }
    }
}

// MARK: - FM 遅延初期化デリゲート

/// FoundationModels のロードはシナリオ実行より重いことがあるため、
/// heal / screenIs / triage が実際に必要になった初回にのみ FMReplayDelegate を作る
final class LazyFMDelegate: ReplayDelegate {
    private var underlying: ReplayDelegate?
    private var checked = false

    private func resolve() -> ReplayDelegate? {
        if !checked {
            checked = true
            if FMDoctor.check().available {
                underlying = FMReplayDelegate()
            }
        }
        return underlying
    }

    func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? {
        await resolve()?.healLocator(step: step, snapshot: snapshot)
    }

    func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? {
        await resolve()?.verifyScreen(expected: expected, screenshotPNG: screenshotPNG)
    }

    func triage(goal: String?, stepDescription: String, failureReason: String,
                snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? {
        await resolve()?.triage(goal: goal, stepDescription: stepDescription,
                                failureReason: failureReason,
                                snapshot: snapshot, screenshotPNG: screenshotPNG)
    }

    // occlusion-guard(exist の既定)の FM 照合。転送しないと ReplayDelegate 既定実装(nil)に落ち、
    // 実行時にガードが黙って素通りする(=機能が無効化される)ため必須。
    func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                              screenshotPNG: Data) async -> (visible: Bool, state: String, reason: String)? {
        await resolve()?.verifyElementVisible(expectedText: expectedText, frame: frame,
                                              screen: screen, screenshotPNG: screenshotPNG)
    }
}

// MARK: - dry-run 用のドライバ(呼ばれない前提。万一呼ばれたら明示エラー)

struct NullDriver: AppDriver {
    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? { "dry-run 中はドライバを使えません" }
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "dry-run", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws { throw Unavailable() }
    func launch(bundleID: String) async throws { throw Unavailable() }
    func snapshot() async throws -> SnapshotResponse { throw Unavailable() }
    func tap(ref: Int) async throws { throw Unavailable() }
    func tap(x: Double, y: Double) async throws { throw Unavailable() }
    func type(ref: Int?, text: String) async throws { throw Unavailable() }
    func swipe(_ direction: FTSwipeDirection) async throws { throw Unavailable() }
    func press(ref: Int, duration: Double) async throws { throw Unavailable() }
    func screenshot() async throws -> Data { throw Unavailable() }
    func terminate() async throws { throw Unavailable() }
}

// (人間向けログ整形は FTCore.ScenarioLogFormatter を使用 — MCP 応答と共通)
