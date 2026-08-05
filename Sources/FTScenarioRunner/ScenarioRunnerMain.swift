// ftester-scenarios(scenarios/ ターゲット)の CLI 実装。
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
        abstract: "List and run Swift DSL scenarios (the runner invoked by ftester run)",
        subcommands: [ListScenarios.self, RunScenario.self]
    )
}

// MARK: - list

struct ListScenarios: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List the scenarios")

    @Flag(help: "Print as JSON")
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
                print("No scenarios (add a @TestClass under the project scenarios/)")
                return
            }
            for testClass in classes {
                let platform = testClass.platform ?? "ios/android"
                print("\(testClass.className) [\(platform)] app=\(testClass.app)")
                for scenario in testClass.scenarios {
                    let title = scenario.title.isEmpty ? "" : " — \(scenario.title)"
                    let deleted = scenario.deleted ? " (deleted)" : ""
                    print("  ・ \(testClass.className).\(scenario.name)\(title)\(deleted)")
                }
            }
        }
    }
}

// MARK: - run

struct RunScenario: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run a single scenario")

    @Option(help: "Scenario ID (Class.method)")
    var scenario: String

    @Option(help: "Target platform: ios / android")
    var platform: String = "ios"

    @Option(help: "Bridge port number (iOS only)")
    var port: UInt16 = BridgeAPI.defaultPort

    @Option(help: "Android device serial (adb -s; defaults to the only connected device)")
    var serial: String?

    @Option(help: "iOS engine: xcuitest (default) / inapp (dylib injection) / hybrid (in-app + XCUITest)")
    var engine: String?

    @Option(help: "iOS: simulator UDID (used to relaunch for inapp/hybrid and for the xcuitest launch preflight)")
    var udid: String?

    @Option(name: .customLong("xcui-port"), help: "iOS: port of the XCUITest bridge used as the hybrid fallback")
    var xcuiPort: UInt16?

    @Option(name: .customLong("inapp-app"),
            help: "iOS: bundleID of the app the in-app bridge was injected into during provisioning (used to identify the target while suspended)")
    var inappApp: String?

    @Option(name: .customLong("device-name"),
            help: "Logical device name from the run profile (shown in the report header; passed in by the orchestrator)")
    var deviceName: String?

    @Flag(help: "The target is a physical device (disables the simctl-based fast launch and the not-installed preflight)")
    var physical = false

    @Option(name: .customLong("bridge-host"),
            help: "Host of the iOS bridge (default 127.0.0.1; for physical devices use the LAN IP or the iproxy loopback)")
    var bridgeHost: String?

    @Flag(help: "Allow FM-based locator self-healing")
    var heal = false

    @Flag(name: .customLong("no-fm"), help: "Do not use any FM feature (heal / false-positive check / screenIs / triage)")
    var noFM = false

    @Flag(name: .customLong("no-false-positive-check"), help: "Disable the false-positive check (occlusion guard)")
    var noFalsePositiveCheck = false

    @Flag(name: .customLong("no-screen-is"), help: "Disable screenIs (screenMatches)")
    var noScreenIs = false

    /// **FM とは無関係**の幾何ヒューリスティック。実行プロファイルの containerInference 由来で、
    /// シナリオ側は `tap(..., containerInference:)` で1コマンド単位に上書きできる
    @Flag(name: .customLong("no-container-inference"),
          help: "Disable corrections that infer the scroll container from the tree")
    var noContainerInference = false

    @Option(name: .customLong("report-dir"), help: "Directory to write reports to")
    var reportDir: String = "reports"

    @Option(name: .customLong("project-dir"),
            help: "Root of the test project (where state such as the heal cache is stored; defaults to the current directory)")
    var projectDir: String?

    @Option(name: .customLong("default-timeout"),
            help: "Default timeout in seconds for assertions such as exist/textIs (decimals allowed, default 5)")
    var defaultTimeout: Double?

    @Flag(name: .customLong("host-install"),
          help: "Route installApp() through the orchestrator via a stdin/stdout RPC instead of installing directly (set by ScenarioHost when an install handler is configured)")
    var hostInstall = false

    @Option(name: .customLong("app-path"),
            help: "Resolved appPath from the run profile, used by installApp() when the argument is omitted and --host-install is not set")
    var appPath: String?

    @Option(name: .customLong("app-name"),
            help: "App display name from the run profile (appName), used by tapAppIcon() when the argument is omitted")
    var appName: String?

    @Flag(help: "Emit NDJSON events (for the host)")
    var json = false

    @Flag(name: .customLong("dry-run"),
          help: "Record every command without touching a device (for listing and reviewing steps)")
    var dryRun = false

    @Flag(help: "Accept pause/resume control commands (NDJSON) on stdin (for debug runs)")
    var debug = false

    @Option(name: .customLong("breakpoint"),
            help: "Breakpoint (<file>:<line>). Only effective with --debug; repeatable")
    var breakpoint: [String] = []

    @Flag(name: .customLong("pause-on-start"),
          help: "Start paused before the first step (only effective with --debug)")
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
                ("scenario not found: \(scenario)\navailable: \(available.joined(separator: ", "))\n")
                    .utf8))
            throw ExitCode(64)
        }

        let scenarioID = "\(testClass.className).\(descriptor.name)"
        let runPlatform = testClass.platform ?? platform

        // ドライバ構築(FTester.swift の DriverOptions と同じパターン)。
        // hybrid: primary=in-app、fallback=XCUITest ブリッジ(springboard 参照)を StepExecutor へ。
        let driver: AppDriver
        var fallbackDriver: AppDriver?
        // tapAppIcon 用(FTDriveCore.homeScreenDriver の①)。xcuitest 単独でだけ明示注入する
        // (hybrid は fallbackDriver が同役を担う。Android は主ドライバで足りる)
        var homeScreenDriver: AppDriver?
        // typeDriver は常に渡す(409 安全網)。preferTypeDriver は probe の uiFramework 検出時のみ
        // (probe 不達なら false のまま=安全網頼み)。
        var typeDriver: AppDriver?
        var preferTypeDriver = false
        // Compose は合成タッチで時間・移動を伴うジェスチャ(swipe/press)を駆動できない
        // (tap/type は通る。実験で確定済み)。probe の uiFramework=="compose" 検出時のみ true
        // (probe 不達なら false のまま=StepExecutor の事後 409 安全網に委ねる)
        var typeDriverGestures: Set<String> = []
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
                    let probe = BridgeClient(port: port, timeoutSeconds: 4, host: bridgeHost ?? BridgeEndpoint.loopbackHost)
                    let probeStatus = try? await probe.status(timeout: 4)
                    let injected = probeStatus?.sessionBundleID ?? inappApp
                    if let injected, injected != testClass.app {
                        guard engine == "hybrid", let xcuiPort else {
                            throw ValidationError(
                                "scenario \(scenarioID) targets \(testClass.app), which differs from the app the "
                                + "in-app bridge is injected into (\(injected)), so it cannot run with engine=inapp. "
                                + "On a device without an explicit engine (run-profile iosInappEngine defaults "
                                + "to hybrid) it is driven automatically via XCUITest"
                                + " (iosInappEngine does not apply to devices that explicitly set engine=inapp)")
                        }
                        let client = BridgeClient(port: xcuiPort, host: bridgeHost ?? BridgeEndpoint.loopbackHost)
                        driver = udid.map { LaunchPreflightDriver(base: client, udid: $0) } ?? client
                    } else {
                        // in-app は launch=simctl 再起動+dylib 注入(自己再起動できないため)
                        let repoRoot = try RepoRoot.find()
                        let inapp = InAppDriver(repoRoot: repoRoot, udid: udid ?? "booted", port: port)
                        if engine == "hybrid", let xcuiPort {
                            fallbackDriver = SystemUIDriver(port: xcuiPort)
                            let attach = AppAttachDriver(port: xcuiPort, bundleID: testClass.app)
                            typeDriver = attach
                            // WebView 画面だけドライバごと XCUITest へ委譲する(in-app は WKWebView の
                            // 中身を原理的に採れない)。attach は typeDriver と**同じインスタンス**を
                            // 使う: activate/attached 状態を1本にしないと余計な activate が挟まる
                            driver = WebViewDelegatingDriver(primary: inapp, delegated: attach)
                            // 2026-07-21 から Compose も inapp で type 可能
                            // (IntermediateTextInputUIView への insertText。InAppInput.m 参照。
                            // 実測 266ms vs attach 1.0〜1.3s)。attach 優先は廃止し、
                            // 失敗時 409 → typeDriver フォールバック(StepExecutor)だけを安全網とする
                            preferTypeDriver = false
                            // 「どの操作が不可か」はブリッジの申告に従う(ホストに
                            // 「compose なら swipe 不可」という知識を持たせない)。
                            // 申告が無い(旧ブリッジ・probe 不達)なら false のまま
                            // = StepExecutor の事後 501 キャッチに委ねる
                            // 申告されたアクション**だけ**を typeDriver へ回す(一括 Bool にしない。
                            // uikit の press 申告で swipe まで XCUITest 化させない — StepExecutor の
                            // typeDriverGestures のコメント参照)
                            typeDriverGestures = Set(probeStatus?.unsupportedActions ?? [])
                                .intersection(["swipe", "press"])
                        } else {
                            driver = inapp
                        }
                    }
                } else {
                    let client = BridgeClient(port: port, host: bridgeHost ?? BridgeEndpoint.loopbackHost)
                    // launch は既定で simctl 化(FastLaunchDriver。実測 -14〜19%)。
                    // FT_NO_FAST_LAUNCH=1 で従来の XCUIApplication.launch() に戻せる。
                    // preflight(未インストール検査)は fast launch の外側に置く。
                    // **実機は両方とも simctl 依存なので必ず外す**(engine=xcuitest なら実機で動く、と
                    // 誤認しやすい罠。素の XCUIApplication.launch() 経路に落とす)
                    let noFastLaunch = ProcessInfo.processInfo.environment["FT_NO_FAST_LAUNCH"] == "1"
                    let inner: AppDriver = (!noFastLaunch && !physical && udid != nil)
                        ? FastLaunchDriver(base: client, udid: udid!) : client
                    // SessionRecoveryDriver は最外側(回復時の activate に LaunchPreflightDriver の
                    // 未インストール検査を効かせるため)。in-app/hybrid 経路には入れない
                    // (InAppDriver は別プロトコルで 409 の意味が違う)。
                    let preflighted: AppDriver = physical
                        ? inner
                        : (udid.map { LaunchPreflightDriver(base: inner, udid: $0) as AppDriver } ?? client)
                    driver = SessionRecoveryDriver(base: preflighted)
                    // 通常ドライバのセッションは対象アプリに縛られ、home() 後の snapshot が
                    // 背面アプリ照会でハングする(実機で確認)。springboard 参照専用を渡す
                    homeScreenDriver = SystemUIDriver(port: port)
                }
            case "android":
                driver = try AndroidDriver(serial: serial)
            default:
                throw ValidationError("platform must be ios or android: \(runPlatform)")
            }
            // InAppDriver は注入先アプリが suspend 中だと status がハングし(上記 suspend 対策参照)、
            // かつ冒頭 launchApp の relaunch で必ず bridge を張り直すため pre-flight の接続確認はしない。
            // XCUITest / Android の常駐ドライバのみ、接続不能を早期に分かりやすく失敗させる。
            // WebViewDelegatingDriver は status を in-app へ流すので同じ理由で外す(包んだ途端に
            // suspend ハングが復活する)
            if !(driver is InAppDriver) && !(driver is WebViewDelegatingDriver) {
                _ = try await driver.status()
            }
        }

        // noFM: delegate を nil にすると heal/screenIs/occlusion-guard/triage は
        // ReplayDelegate 既定実装(nil)に落ち、揃って無効化される(LazyFMDelegate class doc 参照)
        let delegate: ReplayDelegate? = noFM ? nil : LazyFMDelegate()

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
        // `#id` の実在照合に使う台帳(dry-run 専用。ft_snapshot が貯める。SelectorInventory)
        let selectorInventoryURL = projectDir.map {
            SelectorInventory.url(projectRoot: URL(fileURLWithPath: $0))
        }
        // 技術識別子: Android は adb serial、iOS はシミュレータ UDID(共に既存のドライバ構築引数の再利用)
        let deviceIdentifier = runPlatform == "android" ? serial : udid
        let core = FTDriveCore(driver: driver, platform: runPlatform, app: testClass.app,
                               scenarioID: scenarioID, scenarioTitle: descriptor.title,
                               delegate: delegate, healingEnabled: heal && !noFM,
                               falsePositiveCheckEnabled: !noFalsePositiveCheck,
                               screenIsEnabled: !noScreenIs,
                               containerInference: !noContainerInference, dryRun: dryRun,
                               healCacheURL: healCacheURL,
                               selectorInventoryURL: selectorInventoryURL,
                               defaultTimeout: defaultTimeout,
                               fallbackDriver: fallbackDriver,
                               typeDriver: typeDriver, preferTypeDriver: preferTypeDriver,
                               typeDriverGestures: typeDriverGestures,
                               homeScreenDriver: homeScreenDriver,
                               deviceName: deviceName, deviceIdentifier: deviceIdentifier,
                               physical: physical,
                               emit: emit)
        core.appPathOverride = appPath
        core.appDisplayName = appName

        // 失敗時に「アプリより手前の別 window」を添える(Android のみ。adb を叩くのでここで注入する)
        if runPlatform == "android", let serial {
            let package = testClass.app
            core.foregroundOverlays = {
                AndroidForegroundWindows.query(package: package, serial: serial)
            }
        }

        var debugControl: ScenarioDebugControl?
        if debug {
            let control = ScenarioDebugControl(breakpoints: breakpoint,
                                               pauseOnStart: pauseOnStart)
            core.debugControl = control
            debugControl = control
        }
        var installControl: ScenarioInstallControl?
        if hostInstall {
            let control = ScenarioInstallControl()
            core.installControl = control
            installControl = control
        }
        if debugControl != nil || installControl != nil {
            // stdin の制御コマンドは専用スレッドで読む(DSL スレッドは停止中・RPC 待ちでブロックする)。
            // EOF(ホスト終了)で読み終わり、プロセス終了とともに消える。debug と host-install の
            // 制御コマンドは同じ stdin を共有し、"cmd" の値で振り分ける
            // (installResult は installControl、それ以外は既存の debugControl.apply)
            let reader = Thread {
                while let line = readLine(strippingNewline: true) {
                    if let installControl, let parsed = ScenarioInstallControl.parse(line: line) {
                        Task { await installControl.resolve(id: parsed.id, ok: parsed.ok, message: parsed.message) }
                    } else {
                        debugControl?.apply(line: line)
                    }
                }
            }
            reader.name = "ftester-control"
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

        // 「否定側でしか使われず一度も解決できなかった #id」「最後まで不成立の ifCanSelect」
        // 「アサーションが1本も無い」を修正提案として残す(いずれも緑のまま腐る経路。docs/design.md §10)
        core.warnAboutNeverResolvedIDs()
        core.warnAboutMissingAssertions()
        core.warnAboutUnknownIDs()

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
                              screenshotPNG: Data) async
        -> (visible: Bool, state: String, reason: String, observedText: String)? {
        await resolve()?.verifyElementVisible(expectedText: expectedText, frame: frame,
                                              screen: screen, screenshotPNG: screenshotPNG)
    }
}

// MARK: - dry-run 用のドライバ(呼ばれない前提。万一呼ばれたら明示エラー)

struct NullDriver: AppDriver {
    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? { "the driver is unavailable during a dry-run" }
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "dry-run", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws { throw Unavailable() }
    func uninstall(bundleID: String) async throws { throw Unavailable() }
    func launch(bundleID: String) async throws { throw Unavailable() }
    func snapshot() async throws -> SnapshotResponse { throw Unavailable() }
    func tap(ref: Int) async throws { throw Unavailable() }
    func tap(x: Double, y: Double) async throws { throw Unavailable() }
    func type(ref: Int?, text: String) async throws { throw Unavailable() }
    func swipe(_ direction: FTSwipeDirection) async throws { throw Unavailable() }
    func press(ref: Int, duration: Double) async throws { throw Unavailable() }
    func screenshot() async throws -> Data { throw Unavailable() }
    func terminate() async throws { throw Unavailable() }
    func isAppForeground(bundleID: String) async throws -> Bool { throw Unavailable() }
    func foregroundAppID() async throws -> String? { throw Unavailable() }
}

// (人間向けログ整形は FTCore.ScenarioLogFormatter を使用 — MCP 応答と共通)
