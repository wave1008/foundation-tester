// ScenarioRunnerMain.swift
// ftester-scenarios(Scenarios/ ターゲット)の CLI 実装。
//   list [--json]                       … シナリオ一覧
//   run --scenario <クラス名.メソッド名>  … 1 シナリオを実行(1 プロセス = 1 シナリオ)
// --json 指定時は NDJSON イベント(FTCore/ScenarioEvent)を stdout に流す。
// ホスト(CLI/GUI/MCP)は ScenarioHost 経由でサブプロセスとして起動する。

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
            var entries: [[String: String?]] = []
            for testClass in classes {
                for scenario in testClass.scenarios {
                    entries.append([
                        "id": "\(testClass.className).\(scenario.name)",
                        "title": scenario.title,
                        "app": testClass.app,
                        "platform": testClass.platform,
                    ])
                }
            }
            let data = try JSONSerialization.data(
                withJSONObject: ["scenarios": entries.map { $0.mapValues { $0 ?? nil } }],
                options: [.sortedKeys, .withoutEscapingSlashes])
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
                    print("  ・ \(testClass.className).\(scenario.name)\(title)")
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

    func run() async throws {
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

        // ドライバ構築(FTester.swift の DriverOptions と同じパターン)
        let driver: AppDriver
        if dryRun {
            driver = NullDriver()  // dry-run はデバイスに触れない
        } else {
            switch runPlatform {
            case "ios":
                driver = BridgeClient(port: port)
            case "android":
                driver = try AndroidDriver(serial: serial)
            default:
                throw ValidationError("platform は ios / android のいずれかです: \(runPlatform)")
            }
            _ = try await driver.status()  // 接続不能なら早期に分かりやすく失敗させる
        }

        // FM フックはサブプロセス毎の起動コスト回避のため初回必要時に遅延初期化
        let delegate = LazyFMDelegate()

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
        let core = FTDriveCore(driver: driver, platform: runPlatform, app: testClass.app,
                               scenarioID: scenarioID, scenarioTitle: descriptor.title,
                               delegate: delegate, healingEnabled: heal, dryRun: dryRun,
                               healCacheURL: healCacheURL, defaultTimeout: defaultTimeout,
                               emit: emit)

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

        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.scenario = scenarioID
        finished.passed = record.passed
        finished.reportPath = reportURL?.path
        emit(finished)

        if !record.passed {
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
