// FTester.swift
// CLI エントリポイント。
// M1: doctor / bridge / launch / snapshot / tap / type / swipe / screenshot / terminate
// M2 以降: explore(FM探索→フロー生成)、run(決定的再生)

import ArgumentParser
import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore

@main
struct FTester: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ftester",
        abstract: "macOS Foundation Models を頭脳にした iOS/Android アプリテストツール",
        subcommands: [
            Doctor.self,
            Bridge.self,
            Launch.self,
            Snapshot.self,
            Tap.self,
            TypeCommand.self,
            Swipe.self,
            Press.self,
            Screenshot.self,
            Terminate.self,
            Explore.self,
            RunFlows.self,
        ]
    )
}

struct DriverOptions: ParsableArguments {
    @Option(help: "対象プラットフォーム: ios / android")
    var platform: String = "ios"

    @Option(name: .long, help: "ブリッジのポート番号(iOS のみ)")
    var port: UInt16 = BridgeAPI.defaultPort

    @Option(help: "Android デバイスのシリアル(adb -s。省略時は唯一の接続デバイス)")
    var serial: String?

    /// プラットフォームに応じた AppDriver を返す。FTAgent/FTCore はこの抽象しか見ない。
    /// フローファイル側の platform 指定があればそちらを優先する
    func makeDriver(overriding platformOverride: String? = nil) throws -> AppDriver {
        switch platformOverride ?? platform {
        case "ios":
            return BridgeClient(port: port)
        case "android":
            return try AndroidDriver(serial: serial)
        default:
            throw ValidationError("platform は ios / android のいずれかです: \(platformOverride ?? platform)")
        }
    }
}

// MARK: - doctor

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Foundation Models・Xcode・シミュレータの事前チェック")

    func run() async throws {
        let fm = FMDoctor.check()
        print(fm.available ? "✅ \(fm.detail)" : "❌ \(fm.detail)")

        let xcode = try Shell.run(["xcodebuild", "-version"])
        let xcodeLine = xcode.output.split(separator: "\n").first.map(String.init) ?? "不明"
        print(xcode.status == 0 ? "✅ \(xcodeLine)" : "❌ xcodebuild が見つかりません")

        let sims = try Shell.run(["xcrun", "simctl", "list", "devices", "booted"])
        let booted = sims.output.split(separator: "\n")
            .filter { $0.contains("(Booted)") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if booted.isEmpty {
            print("⚠️  起動中のシミュレータがありません(bridge up が自動起動します)")
        } else {
            print("✅ 起動中のシミュレータ: \(booted.joined(separator: ", "))")
        }

        let xcodegen = try Shell.run(["which", "xcodegen"])
        print(xcodegen.status == 0
              ? "✅ xcodegen: \(xcodegen.output.trimmingCharacters(in: .whitespacesAndNewlines))"
              : "❌ xcodegen が必要です: brew install xcodegen")

        // Android(任意): adb と接続デバイス
        if let android = try? AndroidDriver() {
            let devices = try Shell.run([android.adbPath, "devices"])
            let connected = devices.output.split(separator: "\n").dropFirst()
                .filter { $0.contains("\tdevice") }
            print("✅ adb: \(android.adbPath)"
                  + (connected.isEmpty ? "(接続デバイスなし)" : "(\(connected.count) 台接続)"))
        } else {
            print("⚠️ adb が見つかりません(Android を使う場合は ANDROID_HOME を設定)")
        }
    }
}

// MARK: - bridge

struct Bridge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "XCUITest ブリッジ(ランナー)の管理",
        subcommands: [Up.self, Down.self, Status.self])

    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "ランナーをビルドしてシミュレータに常駐させる")

        @Option(help: "シミュレータのデバイス名")
        var device: String = "iPhone 17 Pro"

        @Flag(help: "build-for-testing をスキップ(ビルド済みの場合)")
        var skipBuild = false

        @Flag(help: "SampleApp のビルド・インストールもあわせて行う")
        var withSampleApp = false

        @OptionGroup var driverOptions: DriverOptions

        func run() async throws {
            let root = try RepoRoot.find()
            let launcher = BridgeLauncher(repoRoot: root, device: device, port: driverOptions.port)

            print("→ プロジェクト生成(xcodegen)...")
            try launcher.generateProjectIfNeeded()

            if !skipBuild {
                print("→ build-for-testing(初回は数分かかります)...")
                try launcher.buildForTesting()
            }
            if withSampleApp {
                print("→ SampleApp をビルドしてインストール...")
                try launcher.installSampleApp()
            }
            print("→ ランナーを起動...")
            try launcher.startDetached()
            print("→ 起動待ち(/status ポーリング)...")
            try await launcher.waitUntilReady()
            print("✅ ブリッジ準備完了: http://127.0.0.1:\(driverOptions.port)")
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "ランナーを停止する")

        @Option(name: .long, help: "停止するブリッジのポート")
        var port: UInt16 = BridgeAPI.defaultPort

        @Flag(help: "全ポートのブリッジを停止する")
        var all = false

        func run() async throws {
            let root = try RepoRoot.find()
            if all {
                let stopped = BridgeLauncher.stopAll(repoRoot: root)
                print(stopped.isEmpty
                      ? "起動中のブリッジはありません"
                      : "✅ ブリッジを停止しました(port: \(stopped.joined(separator: ", ")))")
            } else {
                let launcher = BridgeLauncher(repoRoot: root, port: port)
                try launcher.stop()
                print("✅ ブリッジを停止しました(port: \(port))")
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "ブリッジの状態を確認する")

        @OptionGroup var driverOptions: DriverOptions

        func run() async throws {
            let status = try await driverOptions.makeDriver().status()
            print("ready: \(status.ready)")
            print("device: \(status.device) (\(status.osVersion))")
            print("session: \(status.sessionBundleID ?? "なし")")
        }
    }
}

// MARK: - 手動駆動コマンド(M1 検証用)

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "対象アプリを起動する")

    @Argument(help: "アプリの bundle identifier(例: com.example.sampleapp)")
    var bundleID: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().launch(bundleID: bundleID)
        print("✅ 起動: \(bundleID)")
    }
}

struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "現在画面のアクセシビリティツリー(圧縮済み)を表示する")

    @Flag(help: "生の JSON を出力する")
    var json = false

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let snapshot = try await driverOptions.makeDriver().snapshot()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try encoder.encode(snapshot), encoding: .utf8)!)
        } else {
            print(SnapshotRenderer.render(snapshot))
        }
    }
}

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "要素または座標をタップする")

    @Option(help: "snapshot の参照番号")
    var ref: Int?

    @Option(help: "X座標(pt)")
    var x: Double?

    @Option(help: "Y座標(pt)")
    var y: Double?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        if let ref {
            try await driverOptions.makeDriver().tap(ref: ref)
            print("✅ tap [\(ref)]")
        } else if let x, let y {
            try await driverOptions.makeDriver().tap(x: x, y: y)
            print("✅ tap (\(x), \(y))")
        } else {
            throw ValidationError("--ref か --x/--y のどちらかを指定してください")
        }
    }
}

struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "テキストを入力する(--ref 指定時はタップしてから入力)")

    @Option(help: "入力先要素の参照番号(省略時はフォーカス中の要素)")
    var ref: Int?

    @Argument(help: "入力する文字列")
    var text: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().type(ref: ref, text: text)
        print("✅ type \"\(text)\"")
    }
}

struct Swipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "スワイプする")

    @Argument(help: "方向: up / down / left / right")
    var direction: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        guard let dir = FTSwipeDirection(rawValue: direction) else {
            throw ValidationError("方向は up / down / left / right のいずれかです")
        }
        try await driverOptions.makeDriver().swipe(dir)
        print("✅ swipe \(direction)")
    }
}

struct Press: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "要素を長押しする")

    @Option(help: "参照番号")
    var ref: Int

    @Option(help: "長押し秒数")
    var duration: Double = 1.0

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().press(ref: ref, duration: duration)
        print("✅ press [\(ref)] \(duration)s")
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "スクリーンショットを保存する")

    @Option(name: .shortAndLong, help: "出力先 PNG パス")
    var output: String = "screenshot.png"

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let data = try await driverOptions.makeDriver().screenshot()
        try data.write(to: URL(fileURLWithPath: output))
        print("✅ 保存: \(output) (\(data.count) bytes)")
    }
}

struct Terminate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "対象アプリを終了する")

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().terminate()
        print("✅ 終了しました")
    }
}

// MARK: - M2/M3 スタブ

struct Explore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "FM エージェントがアプリを探索してテストフローを生成する")

    @Argument(help: "対象アプリの bundle identifier")
    var bundleID: String

    @Option(help: "テストの目標(自然言語)")
    var goal: String

    @Option(name: .customLong("max-steps"), help: "探索ステップ数の上限")
    var maxSteps: Int = 25

    @Option(help: "フローの出力先ディレクトリ")
    var out: String = "flows"

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let fm = FMDoctor.check()
        guard fm.available else { throw ValidationError(fm.detail) }
        let driver = try driverOptions.makeDriver()
        _ = try await driver.status()  // 接続不能なら早期に分かりやすく失敗させる

        print("🧭 探索開始: \(bundleID) [\(driverOptions.platform)]")
        print("   目標: \(goal)")
        let agent = ExplorerAgent(driver: driver, goal: goal, maxSteps: maxSteps)
        agent.onStep = { step, desc in print("  [\(step)/\(maxSteps)] \(desc)") }
        let result = try await agent.explore(bundleID: bundleID)

        var flow = result.flow
        flow.platform = driverOptions.platform  // 再生時のドライバ自動選択に使う
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(FlowIO.suggestedFileName(for: flow))
        try FlowIO.save(flow, to: url)

        switch result.outcome {
        case .completed(let desc):
            print("✅ 目標達成(\(result.stepsTaken)ステップ)")
            if let desc, !desc.isEmpty { print("   最終画面: \(desc)") }
        case .gaveUp(let reason):
            print("⚠️ 中断: \(reason)(フローに dirty: true を付けました)")
        case .stepLimitReached:
            print("⚠️ ステップ上限に達しました(フローに dirty: true を付けました)")
        }
        print("📄 フローを保存: \(url.path)")
    }
}

struct RunFlows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "保存済みフローを決定的に再生する(失敗時のみ FM が介入)")

    @Argument(help: "フローファイル(.yaml)またはディレクトリ")
    var path: String = "flows"

    @Flag(help: "ロケータ自己修復を許可する(修復されたフローは dirty 付きで上書き保存)")
    var heal = false

    @Option(name: .customLong("report-dir"), help: "レポート出力先ディレクトリ")
    var reportDir: String = "reports"

    @Option(help: "iOS フローを並列実行するブリッジのポート一覧(カンマ区切り。例: 8123,8124。各ポートは別デバイスで bridge up 済みであること)")
    var ports: String?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        // フローファイル収集
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw ValidationError("パスが存在しません: \(path)")
        }
        let files: [URL]
        if isDir.boolValue {
            files = (try fm.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                includingPropertiesForKeys: nil))
                .filter { $0.pathExtension == "yaml" || $0.pathExtension == "yml" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            files = [URL(fileURLWithPath: path)]
        }
        guard !files.isEmpty else {
            throw ValidationError("フローファイル(.yaml)が見つかりません: \(path)")
        }
        let flowItems: [FlowRunItem] = try files.map { FlowRunItem(url: $0, flow: try FlowIO.load(from: $0)) }

        // FM フック(利用不可でも再生自体は可能)
        var delegate: FMReplayDelegate?
        if FMDoctor.check().available {
            delegate = FMReplayDelegate()
        } else {
            print("⚠️ Foundation Models 利用不可: 自己修復・screenMatches・トリアージは無効です")
        }

        let iosPorts: [UInt16] = ports?
            .split(separator: ",")
            .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
            ?? [driverOptions.port]

        let failedCount: Int
        if iosPorts.count <= 1 {
            failedCount = try await runSequential(flowItems, port: iosPorts[0], delegate: delegate)
        } else {
            failedCount = await runParallel(flowItems, iosPorts: iosPorts, delegate: delegate)
        }

        print(failedCount == 0
              ? "✅ 全 \(flowItems.count) フロー成功"
              : "❌ \(flowItems.count) フロー中 \(failedCount) 件失敗")
        if failedCount > 0 {
            throw ExitCode(1)
        }
    }

    // MARK: - 逐次実行(ライブ出力)

    private func runSequential(_ items: [FlowRunItem], port: UInt16,
                               delegate: FMReplayDelegate?) async throws -> Int {
        var failedCount = 0
        for item in items {
            let platform = item.flow.platform ?? driverOptions.platform
            let driver: AppDriver = platform == "android"
                ? try AndroidDriver(serial: driverOptions.serial)
                : BridgeClient(port: port)
            _ = try await driver.status()
            let passed = await FlowRunner.runOne(
                item: item, driver: driver, worker: platform,
                delegate: delegate, healingEnabled: heal,
                reportDir: URL(fileURLWithPath: reportDir)) { event in
                for line in RunLogFormatter.lines(for: event) { print(line) }
            }
            if !passed { failedCount += 1 }
        }
        return failedCount
    }

    // MARK: - 並列実行(iOS はポート毎のワーカー、Android は専用ワーカー)

    private func runParallel(_ items: [FlowRunItem], iosPorts: [UInt16],
                             delegate: FMReplayDelegate?) async -> Int {
        let defaultPlatform = driverOptions.platform
        let androidItems = items.filter { ($0.flow.platform ?? defaultPlatform) == "android" }
        let portList = iosPorts.map(String.init).joined(separator: ", ")
        print("🚀 並列実行: iOS \(iosPorts.count) ワーカー(port: \(portList))"
              + (androidItems.isEmpty ? "" : " + Android 1 ワーカー") + "\n")

        var workers: [RunWorker] = iosPorts.map {
            RunWorker(label: "ios:\($0)", platform: "ios", driver: BridgeClient(port: $0))
        }
        if !androidItems.isEmpty {
            if let driver = try? AndroidDriver(serial: driverOptions.serial) {
                workers.append(RunWorker(label: "android", platform: "android", driver: driver))
            } else {
                print("❌ Android ドライバを初期化できません(adb 未検出)")
                // ワーカー不在の android フローは orchestrator が flowSkipped(失敗扱い)にする
            }
        }

        let orchestrator = RunOrchestrator(workers: workers, delegate: delegate,
                                           healingEnabled: heal,
                                           reportDir: URL(fileURLWithPath: reportDir))
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        // フロー毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)
        var buffers: [URL: [String]] = [:]
        for await event in orchestrator.events {
            let lines = RunLogFormatter.lines(for: event)
            switch event {
            case .flowStarted(_, let url, _, _), .step(_, let url, _), .flowHealed(_, let url):
                buffers[url, default: []].append(contentsOf: lines)
            case .flowFinished(_, let url, _, _, _):
                let all = (buffers.removeValue(forKey: url) ?? []) + lines
                print(all.joined(separator: "\n"))
            default:
                if !lines.isEmpty { print(lines.joined(separator: "\n")) }
            }
        }
        return await summary.failed
    }
}
