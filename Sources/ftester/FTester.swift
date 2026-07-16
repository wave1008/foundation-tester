import ArgumentParser
import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore
import FTDSL

@main
struct FTester: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ftester",
        abstract: "macOS Foundation Models を頭脳にした iOS/Android アプリテストツール",
        subcommands: [
            Doctor.self,
            Bridge.self,
            Install.self,
            Launch.self,
            Snapshot.self,
            Tap.self,
            TypeCommand.self,
            Swipe.self,
            Press.self,
            Screenshot.self,
            Terminate.self,
            Explore.self,
            RunScenarios.self,
            ProjectCommand.self,
            MachineCommand.self,
            ProfileCommand.self,
            DevicesCommand.self,
            ApiCommand.self,
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

    /// FTAgent/FTCore はこの抽象のみに依存(BridgeClient/AndroidDriver を直接見ない)
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

        if let bootedDevices = try? SimulatorCatalog.devices().filter(\.booted) {
            for device in bootedDevices {
                // 未設定キーは defaults read が非0で終了する(未設定 = 無効相当として扱う)
                let read = try? Shell.run([
                    "xcrun", "simctl", "spawn", device.udid,
                    "defaults", "read", "com.apple.Accessibility", "ReduceMotionEnabled",
                ])
                let enabled = read?.status == 0
                    && read?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                if !enabled {
                    print("     ⚠️ \(device.name): Reduce Motion が無効です。"
                          + "アニメーション待ちで遅くなります(次回ブリッジ起動時に自動で有効になります)")
                }
            }
        }

        let xcodegen = try Shell.run(["which", "xcodegen"])
        print(xcodegen.status == 0
              ? "✅ xcodegen: \(xcodegen.output.trimmingCharacters(in: .whitespacesAndNewlines))"
              : "❌ xcodegen が必要です: brew install xcodegen")

        if let android = try? AndroidDriver() {
            let devices = try Shell.run([android.adbPath, "devices"])
            let connected = devices.output.split(separator: "\n").dropFirst()
                .filter { $0.contains("\tdevice") }
            print("✅ adb: \(android.adbPath)"
                  + (connected.isEmpty ? "(接続デバイスなし)" : "(\(connected.count) 台接続)"))
            if let apk = try? AndroidDriver.locateBridgeAPK() {
                print("   ✅ ブリッジAPK: \(apk.path)")
            } else {
                print("   ❌ ブリッジAPK が見つかりません(AndroidRunner/build.sh で生成)")
            }
            for line in connected {
                guard let serial = line.split(separator: "\t").first.map(String.init) else { continue }
                // 高速スナップショット用ブリッジ(未導入でも初回操作時に自動導入・起動される)
                if let driver = try? AndroidDriver(serial: serial) {
                    print("   ・ \(serial): \(driver.bridgeDoctorSummary())")
                    if let warning = driver.animationScaleWarning() {
                        print("     ⚠️ \(warning)")
                    }
                }
            }
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
            abstract: "ブリッジを起動して常駐させる(iOS: シミュレータのランナー / Android: デバイス内サーバ)")

        @Option(help: "シミュレータのデバイス名(iOS のみ)")
        var device: String = "iPhone 17 Pro"

        @Flag(help: "build-for-testing をスキップ(ビルド済みの場合、iOS のみ)")
        var skipBuild = false

        @Flag(help: "SampleApp のビルド・インストールもあわせて行う(iOS のみ)")
        var withSampleApp = false

        @OptionGroup var driverOptions: DriverOptions

        func run() async throws {
            if driverOptions.platform == "android" {
                // serial 省略時は接続中の全デバイス(8台並列前のプリウォーム用)
                for serial in try AndroidBridgeCLI.serials(only: driverOptions.serial) {
                    let driver = try AndroidDriver(serial: serial)
                    print("→ Android ブリッジ起動: \(serial)")
                    try await driver.resetAndEnsureBridge()
                    print("✅ \(serial): \(driver.bridgeDoctorSummary())")
                }
                return
            }
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
        static let configuration = CommandConfiguration(abstract: "ブリッジを停止する")

        @Option(name: .long, help: "停止するブリッジのポート(iOS のみ)")
        var port: UInt16 = BridgeAPI.defaultPort

        @Flag(help: "全ポートのブリッジを停止する(iOS のみ)")
        var all = false

        @Option(help: "対象プラットフォーム: ios / android")
        var platform: String = "ios"

        @Option(help: "Android デバイスのシリアル(省略時は接続中の全デバイス)")
        var serial: String?

        func run() async throws {
            if platform == "android" {
                for serial in try AndroidBridgeCLI.serials(only: serial) {
                    try AndroidDriver(serial: serial).stopBridge()
                    print("✅ Android ブリッジを停止しました: \(serial)")
                }
                return
            }
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
            if driverOptions.platform == "android" {
                for serial in try AndroidBridgeCLI.serials(only: driverOptions.serial) {
                    let driver = try AndroidDriver(serial: serial)
                    print("\(serial): \(driver.bridgeDoctorSummary())")
                }
                return
            }
            let status = try await driverOptions.makeDriver().status()
            print("ready: \(status.ready)")
            print("device: \(status.device) (\(status.osVersion))")
            print("session: \(status.sessionBundleID ?? "なし")")
        }
    }
}

enum AndroidBridgeCLI {
    static func serials(only serial: String?) throws -> [String] {
        if let serial { return [serial] }
        let adbPath = try AndroidDriver.findADB()
        let devices = try Shell.run([adbPath, "devices"])
        let serials = devices.output.split(separator: "\n").dropFirst()
            .filter { $0.contains("\tdevice") }
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
        guard !serials.isEmpty else {
            throw ValidationError("接続中の Android デバイスがありません(adb devices を確認)")
        }
        return serials
    }
}

// MARK: - 手動駆動コマンド

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "パッケージファイルからアプリをインストールする(iOS: .app バンドル / Android: .apk)")

    @Argument(help: "パッケージファイルのパス(iOS: .app バンドル / Android: .apk)")
    var packagePath: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        guard FileManager.default.fileExists(atPath: packagePath) else {
            throw ValidationError("パッケージファイルが見つかりません: \(packagePath)")
        }
        try await driverOptions.makeDriver().install(packagePath: packagePath)
        print("✅ インストール完了: \(packagePath)")
    }
}

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

// MARK: - 探索・実行コマンド

struct Explore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "FM エージェントがアプリを探索して Swift シナリオを生成する")

    @Argument(help: "対象アプリの bundle identifier")
    var bundleID: String

    @Option(help: "テストの目標(自然言語)")
    var goal: String

    @Option(name: .customLong("max-steps"), help: "探索ステップ数の上限")
    var maxSteps: Int = 25

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "シナリオの生成先ディレクトリ(省略時: Projects/<name>/Scenarios/Generated)")
    var out: String?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let fm = FMDoctor.check()
        guard fm.available else { throw ValidationError(fm.detail) }
        let testProject = try ScenarioHost.project(named: project)
        let driver = try driverOptions.makeDriver()
        _ = try await driver.status()  // 接続不能なら早期に分かりやすく失敗させる

        print("🧭 探索開始: \(bundleID) [\(driverOptions.platform)]")
        print("   目標: \(goal)")
        let agent = ExplorerAgent(driver: driver, goal: goal, maxSteps: maxSteps)
        agent.onStep = { step, desc in print("  [\(step)/\(maxSteps)] \(desc)") }
        let result = try await agent.explore(bundleID: bundleID)

        var flow = result.flow
        flow.platform = driverOptions.platform  // 実行時のドライバ自動選択に使う

        switch result.outcome {
        case .completed(let desc):
            print("✅ 目標達成(\(result.stepsTaken)ステップ)")
            if let desc, !desc.isEmpty { print("   最終画面: \(desc)") }
        case .gaveUp(let reason):
            print("⚠️ 中断: \(reason)(TODO コメント付きで生成します)")
        case .stepLimitReached:
            print("⚠️ ステップ上限に達しました(TODO コメント付きで生成します)")
        }

        // ビルド検証に失敗したシナリオは quarantineDir(_disabled/)に隔離される
        let dir = out.map { URL(fileURLWithPath: $0) } ?? testProject.generatedDir
        let quarantineDir = testProject.disabledDir
        let className = ScenarioCodeGen.suggestedClassName(
            for: flow,
            existing: ScenarioCodeGen.existingClassNames(
                in: [testProject.scenariosDir, dir, quarantineDir]))
        let code = ScenarioCodeGen.render(flow: flow, className: className,
                                          generatedBy: "ftester explore v0.1 (apple-fm-on-device)")
        print("→ 生成コードをビルド検証中...")
        let url = try ScenarioCodeGen.writeValidated(code: code, className: className,
                                                     dir: dir, quarantineDir: quarantineDir,
                                                     project: testProject)
        print("📄 シナリオを生成: \(url.path)")
        print("   実行: swift run ftester run --project \(testProject.name)"
              + " --scenario \(className).\(ScenarioCodeGen.methodName(1))")
    }
}

struct RunScenarios: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Swift DSL シナリオ(Projects/<name>/Scenarios/)を実行する(失敗時のみ FM が介入)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "実行プロファイル名(profiles/runs/<名前>.json。デバイス供給・自動インストール込みで実行)")
    var profile: String?

    @Option(name: .customLong("scenario"), parsing: .upToNextOption,
            help: "実行するシナリオ ID(クラス名.メソッド名。クラス名のみで全シナリオ。複数可。省略時は全件。削除済み @Deleted は完全一致指定のときだけ実行)")
    var scenarios: [String] = []

    @Option(name: .customLong("folder"), parsing: .upToNextOption,
            help: "実行するシナリオのフォルダ名(Scenarios/ 直下のサブフォルダ。複数可。--scenario・--failed と併用可)")
    var folders: [String] = []

    @Flag(help: "FM によるロケータ自己修復を許可する")
    var heal = false

    @Flag(help: "前回失敗したシナリオだけを実行する(結果は実行のたびに .ftester/last-results/ に記録される)")
    var failed = false

    @Option(name: .customLong("report-dir"),
            help: "レポート出力先ディレクトリ(省略時: Projects/<name>/reports)")
    var reportDir: String?

    @Option(help: "iOS シナリオを並列実行するブリッジのポート一覧(カンマ区切り。例: 8123,8124。各ポートは別デバイスで bridge up 済みであること)")
    var ports: String?

    @Flag(name: .customLong("skip-build"), help: "実行前の swift build をスキップする")
    var skipBuild = false

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)

        // ビルドはホスト側で 1 回だけ(サブプロセスは自らビルドしない)
        if !skipBuild {
            print("→ シナリオをビルド(\(testProject.name))...")
            try ScenarioHost.build(project: testProject)
        }
        let all = try ScenarioHost.list(project: testProject)
        guard !all.isEmpty else {
            throw ValidationError(
                "シナリオがありません(Projects/\(testProject.name)/Scenarios/ に @TestClass を追加してください)")
        }
        var selected = try Self.resolve(scenarios, from: all)
        if scenarios.isEmpty {
            let deletedCount = all.filter(\.deleted).count
            if deletedCount > 0 {
                print("→ 削除済み(@Deleted)のシナリオ \(deletedCount) 件を除外")
            }
        }
        if !folders.isEmpty {
            selected = try Self.filterByFolders(selected, folders: folders,
                                                scenariosDir: testProject.scenariosDir)
        }
        if failed {
            let failedSet = LastResultsStore.failedIDs(project: testProject)
            selected = selected.filter { failedSet.contains($0.id) }
            guard !selected.isEmpty else {
                print("前回失敗したシナリオはありません(全て成功済みか未実行)")
                return
            }
            print("→ 前回失敗した \(selected.count) 件を再実行")
        }
        guard !selected.isEmpty else {
            print("実行対象がありません(全シナリオが削除済み @Deleted)")
            return
        }
        let items = selected.map { ScenarioRunItem(info: $0) }

        if FMDoctor.check().available == false {
            print("⚠️ Foundation Models 利用不可: 自己修復・screenIs・トリアージは無効です")
        }

        if let profile {
            let failedCount = try await ProfileRunner.run(
                project: testProject, profileName: profile, items: items,
                healOverride: heal ? true : nil, reportDirOverride: reportDir)
            print(failedCount == 0
                  ? "✅ 全 \(items.count) シナリオ成功"
                  : "❌ \(items.count) シナリオ中 \(failedCount) 件失敗")
            if failedCount > 0 { throw ExitCode(1) }
            return
        }

        let reportDirPath = reportDir ?? testProject.reportsDir.path
        let iosPorts: [UInt16] = ports?
            .split(separator: ",")
            .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
            ?? [driverOptions.port]

        let failedCount: Int
        if iosPorts.count <= 1 {
            failedCount = try await runSequential(items, project: testProject,
                                                  port: iosPorts[0], reportDir: reportDirPath)
        } else {
            failedCount = await runParallel(items, project: testProject,
                                            iosPorts: iosPorts, reportDir: reportDirPath)
        }

        print(failedCount == 0
              ? "✅ 全 \(items.count) シナリオ成功"
              : "❌ \(items.count) シナリオ中 \(failedCount) 件失敗")
        if failedCount > 0 {
            throw ExitCode(1)
        }
    }

    /// @Deleted(論理削除)は全件実行・クラス名展開から除外(完全一致の明示指定のみ実行可)
    static func resolve(_ ids: [String], from all: [ScenarioInfo]) throws -> [ScenarioInfo] {
        guard !ids.isEmpty else { return all.filter { !$0.deleted } }
        var result: [ScenarioInfo] = []
        for id in ids {
            if let exact = all.first(where: { $0.id == id }) {
                result.append(exact)
                continue
            }
            let classMatches = all.filter { $0.id.hasPrefix(id + ".") && !$0.deleted }
            guard !classMatches.isEmpty else {
                if all.contains(where: { $0.id.hasPrefix(id + ".") }) {
                    throw ValidationError(
                        "\(id) のシナリオは全て削除済み(@Deleted)です"
                        + "(クラス名.メソッド名 の完全指定なら実行できます)")
                }
                throw ValidationError(
                    "シナリオが見つかりません: \(id)(利用可能: \(all.map(\.id).joined(separator: ", ")))")
            }
            result.append(contentsOf: classMatches)
        }
        return result
    }

    /// --folder でシナリオを絞り込む(クラス名→ソースファイル→フォルダ名で照合)。
    /// 絞り込んだ結果が空、かつ未知のフォルダ名が含まれる場合はエラー
    static func filterByFolders(_ infos: [ScenarioInfo], folders: [String],
                                scenariosDir: URL) throws -> [ScenarioInfo] {
        let classFile = ScenarioFolders.classFileMap(scenariosDir: scenariosDir)
        let filtered = ScenarioFolders.filter(infos, byFolders: folders) { className in
            classFile[className].flatMap { ScenarioFolders.folderName(of: $0, scenariosDir: scenariosDir) }
        }
        if filtered.isEmpty {
            let available = ScenarioFolders.list(scenariosDir: scenariosDir)
            let unknown = folders.filter { !available.contains($0) }
            if !unknown.isEmpty {
                throw ValidationError(
                    "フォルダが見つかりません: \(unknown.joined(separator: ", "))"
                    + "(利用可能: \(available.joined(separator: ", ")))")
            }
        }
        return filtered
    }

    /// ブリッジの /status(デバイス名)→ 起動中シミュレータの一意な同名から UDID を解決する。
    /// launch 事前検査(LaunchPreflightDriver)用。同名複数・未起動・応答なしは nil(検査なしで従来動作)
    private static func resolveUdid(port: UInt16) async -> String? {
        guard let status = try? await BridgeClient(port: port, timeoutSeconds: 5).status(),
              let catalog = try? SimulatorCatalog.devices() else { return nil }
        let matches = catalog.filter { $0.booted && $0.name == status.device }
        return matches.count == 1 ? matches[0].udid : nil
    }

    // MARK: - 逐次実行(ライブ出力)

    private func runSequential(_ items: [ScenarioRunItem], project: TestProject,
                               port: UInt16, reportDir: String) async throws -> Int {
        let iosUdid = await Self.resolveUdid(port: port)
        var failedCount = 0
        for item in items {
            let platform = item.info.platform ?? driverOptions.platform
            let driver: AppDriver
            let connection: DriverConnection
            if platform == "android" {
                driver = try AndroidDriver(serial: driverOptions.serial)
                connection = DriverConnection(platform: "android", serial: driverOptions.serial)
            } else {
                driver = BridgeClient(port: port)
                connection = DriverConnection(platform: "ios", port: port, udid: iosUdid)
            }
            _ = try await driver.status()
            let worker = RunWorker(label: platform, platform: platform,
                                   driver: driver, connection: connection)
            let passed = await ScenarioRunner.runOne(
                project: project, item: item, worker: worker, healingEnabled: heal,
                reportDir: URL(fileURLWithPath: reportDir)) { event in
                for line in RunLogFormatter.lines(for: event) { print(line) }
            }
            if !passed { failedCount += 1 }
        }
        return failedCount
    }

    // MARK: - 並列実行(iOS はポート毎のワーカー、Android は専用ワーカー)

    private func runParallel(_ items: [ScenarioRunItem], project: TestProject,
                             iosPorts: [UInt16], reportDir: String) async -> Int {
        let defaultPlatform = driverOptions.platform
        let androidItems = items.filter { ($0.info.platform ?? defaultPlatform) == "android" }
        let portList = iosPorts.map(String.init).joined(separator: ", ")
        print("🚀 並列実行: iOS \(iosPorts.count) ワーカー(port: \(portList))"
              + (androidItems.isEmpty ? "" : " + Android 1 ワーカー") + "\n")

        var workers: [RunWorker] = []
        for port in iosPorts {
            let udid = await Self.resolveUdid(port: port)
            workers.append(RunWorker(label: "ios:\(port)", platform: "ios",
                                     driver: BridgeClient(port: port),
                                     connection: DriverConnection(platform: "ios", port: port,
                                                                  udid: udid)))
        }
        if !androidItems.isEmpty {
            if let driver = try? AndroidDriver(serial: driverOptions.serial) {
                workers.append(RunWorker(label: "android", platform: "android", driver: driver,
                                         connection: DriverConnection(platform: "android",
                                                                      serial: driverOptions.serial)))
            } else {
                print("❌ Android ドライバを初期化できません(adb 未検出)")
                // ワーカー不在の android シナリオは orchestrator が flowSkipped(失敗扱い)にする
            }
        }

        let orchestrator = RunOrchestrator(project: project, workers: workers,
                                           healingEnabled: heal,
                                           reportDir: URL(fileURLWithPath: reportDir))
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        // シナリオ毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)
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

