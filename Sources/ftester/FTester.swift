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
        abstract: "macOS用 iOS/Android アプリテストツール",
        subcommands: [
            InitCommand.self,
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
            RunScenarios.self,
            RunFileCommand.self,
            DraftScenarioCommand.self,
            ProjectCommand.self,
            MachineCommand.self,
            ProfileCommand.self,
            DevicesCommand.self,
            ApiCommand.self,
            ResultsCommand.self,
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
            // 実機ブリッジは 127.0.0.1 に居ない。provision が残した宛先を使う
            // (記録が無ければループバック = シミュレータの既定)
            let host = (try? RepoRoot.find())
                .map { BridgeEndpoint.load(port: port, repoRoot: $0).host }
                ?? BridgeEndpoint.loopbackHost
            return BridgeClient(port: port, host: host)
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
        abstract: "Preflight checks for Foundation Models, Xcode and simulators")

    // FM/Apple Intelligence の可否だけを判定して exit code に反映する高速ゲート。
    // setup スキルがビルド直後に人間へ聞かずに自動判定するために使う(FM 不可なら非0で終了)。
    @Flag(name: .long, help: "Only check Apple Intelligence / on-device FM availability and report it via exit code")
    var fmOnly = false

    // ルート解決だけを見る高速ゲート。FM(実呼び出しで数秒・環境によっては失敗)に依存させない
    // ため独立させてある。パス取り違えの切り分けはこれ単体で完結する
    @Flag(name: .long, help: "Only check tool-root / scenario-package root resolution and report it via exit code")
    var rootsOnly = false

    func run() async throws {
        if rootsOnly {
            // ツール本体が解決できない = ブリッジが起動不能なので非0。シナリオパッケージ側は
            // パッケージ外から実行しても正当なので警告どまり(exit code に反映しない)
            let toolRootResolved = printRoots()
            if !toolRootResolved { throw ExitCode(1) }
            return
        }

        // availability だけでは実呼び出しの可否が分からない(FMDoctor.checkLive の doc 参照)。
        // doctor は「本当に使えるか」を答える場所なので実呼び出しで確認する
        let fm = await FMDoctor.checkLive()
        print(fm.available ? "✅ \(fm.detail)" : "❌ \(fm.detail)")
        if fmOnly {
            // 可: 0 / 不可(AI 無効・DL中・対象外): 1。呼び出し側が理由文字列を stdout から読める。
            if !fm.available { throw ExitCode(1) }
            return
        }

        // 視覚系だけが落ちる環境(macOS 26)を区別して見せる。exit code には反映しない
        // (テキスト系は動くため、セットアップを止める理由にはならない)
        let vision = FMDoctor.visionReport
        print(vision.available ? "✅ \(vision.detail)" : "⚠️ \(vision.detail)")

        _ = printRoots()

        let xcode = try Shell.run(["xcodebuild", "-version"])
        let xcodeLine = xcode.output.split(separator: "\n").first.map(String.init) ?? "unknown"
        print(xcode.status == 0 ? "✅ \(xcodeLine)" : "❌ xcodebuild not found")

        await reportUnmanagedBridges()

        // ランナーをビルドした Xcode と現在選択中の Xcode の一致確認。Xcode(beta)更新後に
        // 旧ビルドのランナーを使う・逆に新ビルドのランナーを旧ランタイムに載せると、アプリが
        // 実行中に「Application is not running」でクラッシュする(2026-07-21 実害)。
        // CLAUDE.md の「Xcode 更新後はフルリビルド」を機械検知にしたもの。
        // 注: DTSDKBuild とランタイムのビルド ID は別体系のため比較しない(誤検知する)
        if let root = try? RepoRoot.find() {
            let plist = root.appendingPathComponent(".ftester/DerivedData/Build/Products/"
                + "Debug-iphonesimulator/FTesterRunnerUITests-Runner.app/Info.plist")
            // 末尾レター違い(27A5228b vs 27A5228h)は同一ビルド系列の再発行+増分ビルドで
            // Info.plist が残るケースがあり実害なし(実測)。数字部分の差のみを不整合とみなす
            func core(_ build: String) -> String {
                String(build.reversed().drop(while: \.isLetter).reversed())
            }
            if let data = try? Data(contentsOf: plist),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                   as? [String: Any],
               let runnerXcodeBuild = dict["DTXcodeBuild"] as? String,
               !core(runnerXcodeBuild).isEmpty,
               !xcode.output.contains(core(runnerXcodeBuild)) {
                print("⚠️ The XCUITest runner was built with a different Xcode (build \(runnerXcodeBuild)). "
                    + "After updating Xcode, install the runtime (xcodebuild -downloadPlatform iOS) and do a full rebuild "
                    + "to bring them back in sync (a mismatch crashes the app mid-run)")
            }
        }

        let sims = try Shell.run(["xcrun", "simctl", "list", "devices", "booted"])
        let booted = sims.output.split(separator: "\n")
            .filter { $0.contains("(Booted)") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if booted.isEmpty {
            print("⚠️  No booted simulators (bridge up will boot one automatically)")
        } else {
            print("✅ Booted simulators: \(booted.joined(separator: ", "))")
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
                    print("     ⚠️ \(device.name): Reduce Motion is off. "
                          + "Runs are slower because of animation waits (it is enabled automatically on the next bridge start)")
                }
            }
        }

        let xcodegen = try Shell.run(["which", "xcodegen"])
        print(xcodegen.status == 0
              ? "✅ xcodegen: \(xcodegen.output.trimmingCharacters(in: .whitespacesAndNewlines))"
              : "❌ xcodegen is required: brew install xcodegen")

        if let android = try? AndroidDriver() {
            let devices = try Shell.run([android.adbPath, "devices"])
            let connected = devices.output.split(separator: "\n").dropFirst()
                .filter { $0.contains("\tdevice") }
            print("✅ adb: \(android.adbPath)"
                  + (connected.isEmpty ? " (no devices connected)" : " (\(connected.count) connected)"))
            if let apk = try? AndroidDriver.locateBridgeAPK() {
                print("   ✅ Bridge APK: \(apk.path)")
            } else {
                print("   ❌ Bridge APK not found (generate it with AndroidRunner/build.sh)")
            }
            // AVD の新規作成(モニターの「デバイスを追加」/ api create-device)にだけ要る。
            // 既存 AVD で実行するぶんには不要なので警告どまり
            if let avdmanager = AndroidSDKLocator.findAVDManager() {
                print("   ✅ avdmanager: \(avdmanager.path)")
            } else {
                print("   ⚠️ \(AndroidSDKLocator.avdManagerMissingMessage)。"
                      + "New AVDs cannot be created (running on existing AVDs is unaffected). "
                      + AndroidSDKLocator.avdManagerInstallHint)
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
            print("⚠️ adb not found (set ANDROID_HOME if you use Android)")
        }
    }

    /// 2つのルートを表示し、ツール本体を解決できたかを返す。外部パッケージ構成では別ディレクトリに
    /// なり、取り違えると「InAppBridge/build.sh が無い」「Projects/ が見えない」で詰まる(実害あり)
    /// このリポジトリの管理下に無いブリッジ(別クローン起動 / 版が古い)の報告と、
    /// **証拠が決定的なものだけ**の自動停止(処遇は UnmanagedBridgeTriage が唯一の判定者):
    /// 自リポジトリの旧版・起動元リポジトリが消滅したゾンビ → 停止 /
    /// 別の実在ワークスペースの所有・起動元不明 → 報告のみ(他人の資産を勝手に殺さない)。
    ///
    /// 放置すると**ポートとシミュレータを握ったまま永久に残る**: provision の stale 掃除は
    /// 供給対象デバイスの分しか見ない(BridgeProvisioner の sameDevice 条件)ので、
    /// プロファイル外のデバイスに残った旧版ブリッジは誰も片付けない。
    /// 実害: protocolVersion 4 のランナーが 7 時間 22 分ポート 8127 とシミュレータを占有した
    /// (無通信 TTL 導入後は最長でも TTL で消えるが、旧版ブリッジには TTL が無い)。
    private func reportUnmanagedBridges() async {
        guard let root = try? RepoRoot.find() else { return }
        let stateDir = root.appendingPathComponent(".ftester")
        var findings: [String] = []
        var reaped: [String] = []
        for port in BridgeAPI.defaultPort...(BridgeAPI.defaultPort + 31) {
            guard let status = BridgeLauncher.probeForeignBridge(port: port, timeout: 0.4)
            else { continue }
            let pidPath = stateDir.appendingPathComponent("bridge-\(port).pid")
            let inAppPath = InAppBridgeState.url(stateDir: stateDir, port: port)
            let hasPid = FileManager.default.fileExists(atPath: pidPath.path)
            let hasInApp = FileManager.default.fileExists(atPath: inAppPath.path)
            let stale = status.protocolVersion != BridgeAPI.bridgeProtocolVersion
            let version = status.protocolVersion.map(String.init) ?? "?"
            let label = "port \(port): \(status.device)(v\(version))"
            // 「いつから放置か」の診断(自己申告の idleSeconds。この probe 自体は数えない)
            let idle = status.idleSeconds.map { $0 >= 60 ? ", idle \(Int($0 / 60))m" : "" } ?? ""

            switch UnmanagedBridgeTriage.decide(
                ownerRepo: status.ownerRepo,
                ownerExists: status.ownerRepo.map {
                    FileManager.default.fileExists(atPath: $0) } ?? false,
                isOwnRepo: status.ownerRepo == root.path,
                hasStateFile: hasPid || hasInApp,
                stale: stale) {
            case .skipHealthy:
                continue
            case .reapOwnStale:
                // 自分の資産の旧版。in-app はアプリごと終了、xcuitest は pid ファイル経由で停止
                if hasInApp {
                    InAppBridgeState.terminateAndRemove(at: inAppPath)
                    reaped.append("\(label) — stale version (expected v\(BridgeAPI.bridgeProtocolVersion)) owned by this repo")
                } else if let pid = Self.pidFromFile(pidPath), BridgeLauncher.reapRunnerProcess(pid: pid) {
                    try? FileManager.default.removeItem(at: pidPath)
                    reaped.append("\(label) — stale version (expected v\(BridgeAPI.bridgeProtocolVersion)) owned by this repo")
                } else if let pid = status.ownerPid.map(Int32.init), BridgeLauncher.reapRunnerProcess(pid: pid) {
                    try? FileManager.default.removeItem(at: pidPath)
                    reaped.append("\(label) — stale version (expected v\(BridgeAPI.bridgeProtocolVersion)) owned by this repo")
                } else {
                    findings.append("   - \(label) — stale version but could not be stopped (check `lsof -ti :\(port)`)")
                }
            case .reapOrphan(let owner):
                if let pid = status.ownerPid.map(Int32.init), BridgeLauncher.reapRunnerProcess(pid: pid) {
                    reaped.append("\(label) — its owner is gone (\(owner))")
                } else {
                    findings.append("   - \(label) — its owner is gone (\(owner)) and it could not be stopped via ownerPid. "
                        + "Kill the process shown by `lsof -ti :\(port)`")
                }
            case .reportForeign(let owner):
                findings.append("   - \(label)\(idle) — 別ワークスペースの所有: \(owner)。"
                    + "そちらのクローンで `ftester bridge down --port \(port)`")
            case .reportUnknown:
                findings.append("   - \(label)\(idle) — 起動元不明(自己申告の無い旧ブリッジ)。"
                    + "`lsof -ti :\(port)` のプロセスを止めたうえで、iOS は "
                    + "`xcrun simctl terminate <udid> com.example.ftrunner.uitests.xctrunner` まで行う")
            }
        }
        if !reaped.isEmpty {
            print("✂️ Stopped bridges that will not be reused:")
            reaped.forEach { print("   - \($0)") }
        }
        if findings.isEmpty {
            if reaped.isEmpty { print("✅ No unmanaged or stale bridges") }
        } else {
            print("⚠️ Bridges that will not be reused are still running (they hold ports and devices):")
            findings.forEach { print($0) }
        }
    }

    private static func pidFromFile(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func printRoots() -> Bool {
        var resolved = false
        switch Result(catching: { try RepoRoot.find() }) {
        case .success(let root):
            print("✅ Tool root (bridge assets): \(root.path)")
            resolved = true
        case .failure(let error):
            print("❌ Cannot determine the tool root: \(error.localizedDescription)")
        }
        if let packageRoot = ScenarioHost.packageRoot() {
            print("✅ Scenario package (Projects/): \(packageRoot.path)")
        } else {
            print("⚠️ No scenario package (Package.swift) found above the current directory"
                + " (set FT_PACKAGE_ROOT to point at it explicitly)")
        }
        return resolved
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

        @Flag(help: "--device を iOS 実機の UDID として扱う(xcrun devicectl list devices の Identifier)")
        var physical = false

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
            let launcher = BridgeLauncher(repoRoot: root, device: device, port: driverOptions.port,
                                          physical: physical)

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
            // 起動は provision() 経由(直接 startDetached しない)。同一シミュレータに XCUITest
            // ランナーは1本しか同居できず(全ポート共通 bundle id のため2本目が先代を蹴り出し双方
            // signal kill で死ぬ)、直接起動は同一デバイスへの二重起動を防げない。provision() は
            // 稼働中ブリッジのスキャン→版一致なら再利用/旧版なら停止して起動し直すをまとめて行う
            // (モニター保持中でも拒否せず再利用・起動する=テスト/操作優先)。
            // 実機は必ず UDID 指定(形状推測はしない。実機 UDID はシミュレータ UUID と形が違う)
            let isUDID = physical || (device.count == 36 && device.split(separator: "-").count == 5)
            let spec = DeviceSpec(
                name: device,
                kind: physical ? .physical : nil,
                simulator: isUDID ? nil : device,
                udid: isUDID ? device : nil,
                port: driverOptions.port,
                engine: "xcuitest")
            let provisioned = try await BridgeProvisioner(repoRoot: root)
                .provision(devices: [(spec.name, spec)], log: { print($0) })
            // provision() は失敗時に throw する(空配列で正常復帰はしない)ため、first は常に存在する
            let port = provisioned.first?.port ?? driverOptions.port
            // provision は同一デバイスの稼働中ブリッジを preferred(--port)を無視して再利用する。
            // 固定ポート前提のスクリプトが :driverOptions.port を叩いて外さないよう、差異を明示する
            if port != driverOptions.port {
                print("⚠️ 指定/既定ポート \(driverOptions.port) ではなく、このデバイスの稼働中ブリッジ"
                    + "(port \(port))を再利用しました。port \(driverOptions.port) で立て直したい場合は"
                    + "先に `ftester bridge down --port \(port)` で停止してから再実行してください。")
            }
            let host = provisioned.first?.host ?? BridgeEndpoint.loopbackHost
            print("✅ ブリッジ準備完了: http://\(host):\(port)")
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

// MARK: - 実行コマンド

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

    @Flag(name: .customLong("no-lpt"),
          help: "LPT 投入順(過去実績の長い順)を無効にし、シナリオ ID 順で投入する")
    var noLPT = false

    @Option(name: .customLong("lpt-history-runs"),
            help: "LPT の実績として読む run 数(新しい方から。既定 5)")
    var lptHistoryRuns: Int?

    @Flag(help: "前回失敗したシナリオだけを実行する(結果は実行のたびに .ftester/last-results/ に記録される)")
    var failed = false

    @Option(name: .customLong("report-dir"),
            help: "レポート出力先ディレクトリ(省略時: Projects/<name>/reports)")
    var reportDir: String?

    @Option(help: "iOS シナリオを並列実行するブリッジのポート一覧(カンマ区切り。例: 8123,8124。各ポートは別デバイスで bridge up 済みであること)")
    var ports: String?

    @Flag(name: .customLong("skip-build"), help: "実行前の swift build をスキップする")
    var skipBuild = false

    @Flag(help: "ステップ行を抑制しサマリのみ出力する(CI/エージェント向け)")
    var quiet = false

    @Flag(name: .customLong("fast-input"),
          help: "iOS xcuitest ブリッジの高速入力(quiescence 待ちスキップ)を有効化する(実行プロファイルの iosFastInput でも指定可)")
    var fastInput = false

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        // BridgeClient(ホスト・サブプロセス両方)が FT_FAST_INPUT を読む。プロファイル指定分は
        // ProfileRunner が同様に注入する
        if fastInput { setenv("FT_FAST_INPUT", "1", 1) }
        PhaseLog.mark("start")
        let testProject = try ScenarioHost.project(named: project)
        PhaseLog.mark("project-resolved")

        // ビルドはホスト側で 1 回だけ(サブプロセスは自らビルドしない)
        if !skipBuild {
            print("→ シナリオをビルド(\(testProject.name))...")
            try ScenarioHost.build(project: testProject)
        }
        PhaseLog.mark("build")
        let all = try ScenarioHost.list(project: testProject)
        PhaseLog.mark("scenario-list")
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
        // LPT 投入順の適用は実行経路ごとに行う(実効 platform が確定してからでないと
        // 別 platform の実績で並べてしまう): --profile は ProfileRunner.run、--ports は runParallel。
        // 逐次実行は並列度が無いので並べ替えない
        let items = selected.map { ScenarioRunItem(info: $0) }

        if FMDoctor.check().available == false {
            print("⚠️ Foundation Models 利用不可: 自己修復・screenIs・トリアージは無効です")
        } else if !FMVisionSupport.isSupported {
            print("⚠️ \(FMVisionSupport.requirement): screenIs・occlusion-guard は無効です"
                  + "(自己修復・トリアージは有効)")
        }

        PhaseLog.mark("fm-doctor")
        let recorder = RunRecorder.begin(project: testProject, profile: profile, trigger: "cli")
        PhaseLog.mark("recorder-begin")

        if let profile {
            let runSummary = try await ProfileRunner.run(
                project: testProject, profileName: profile, items: items,
                healOverride: heal ? true : nil, reportDirOverride: reportDir,
                quiet: quiet, lpt: !noLPT,
                lptHistoryRuns: lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns,
                recorder: recorder)
            let failedCount = runSummary.failed
            PhaseLog.mark("profile-run-done")
            recorder.finish(total: items.count, passed: items.count - failedCount, failed: failedCount,
                            degradedWorkers: runSummary.degradedWorkers,
                            freezeRetries: runSummary.freezeRetries,
                            blankRepairs: runSummary.blankRepairs,
                            blankExclusions: runSummary.blankExclusions)
            PhaseLog.mark("recorder-finish")
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
                                                  port: iosPorts[0], reportDir: reportDirPath,
                                                  recorder: recorder)
        } else {
            failedCount = await runParallel(items, project: testProject,
                                            iosPorts: iosPorts, reportDir: reportDirPath,
                                            recorder: recorder)
        }
        recorder.finish(total: items.count, passed: items.count - failedCount, failed: failedCount)

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
                               port: UInt16, reportDir: String,
                               recorder: RunRecorder?) async throws -> Int {
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
            // quiet: 全行をバッファし、成功なら結果1行のみ・失敗ならバッファ全体(失敗詳細)を出す
            var buffer: [String] = []
            let outcome = await ScenarioRunner.runOne(
                project: project, item: item, worker: worker, fm: FMConfig(heal: heal),
                reportDir: URL(fileURLWithPath: reportDir), recorder: recorder) { event in
                let lines = RunLogFormatter.lines(for: event)
                if quiet {
                    buffer.append(contentsOf: lines)
                } else {
                    for line in lines { print(line) }
                }
            }
            if quiet {
                if outcome == .passed {
                    print("✅ \(item.info.id)")
                } else {
                    print("❌ \(item.info.id)")
                    print(buffer.joined(separator: "\n"))
                }
            }
            if outcome != .passed { failedCount += 1 }
        }
        return failedCount
    }

    // MARK: - 並列実行(iOS はポート毎のワーカー、Android は専用ワーカー)

    private func runParallel(_ rawItems: [ScenarioRunItem], project: TestProject,
                             iosPorts: [UInt16], reportDir: String,
                             recorder: RunRecorder?) async -> Int {
        let defaultPlatform = driverOptions.platform
        let items = LPTOrdering.apply(rawItems, project: project, defaultPlatform: defaultPlatform,
                                      enabled: !noLPT,
                                      historyRuns: lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns,
                                      log: { print($0) })
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
                                           fm: FMConfig(heal: heal),
                                           reportDir: URL(fileURLWithPath: reportDir),
                                           recorder: recorder)
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        // シナリオ毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)。
        // quiet: 成功シナリオは結果1行のみ・失敗シナリオはバッファ全体(失敗詳細)を出す
        var buffers: [URL: [String]] = [:]
        var names: [URL: String] = [:]
        for await event in orchestrator.events {
            let lines = RunLogFormatter.lines(for: event)
            switch event {
            case .flowStarted(_, let url, let flowName, _):
                names[url] = flowName
                buffers[url, default: []].append(contentsOf: lines)
            case .step(_, let url, _), .flowHealed(_, let url):
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
        return await summary.failed
    }
}

