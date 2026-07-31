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
        abstract: "iOS/Android app testing tool for macOS",
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
            RemoteCommand.self,
        ]
    )
}

struct DriverOptions: ParsableArguments {
    @Option(help: "Target platform: ios / android")
    var platform: String = "ios"

    @Option(name: .long, help: "Bridge port number (iOS only)")
    var port: UInt16 = BridgeAPI.defaultPort

    @Option(help: "Android device serial (adb -s; defaults to the only connected device)")
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
            throw ValidationError("platform must be ios or android: \(platformOverride ?? platform)")
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
                findings.append("   - \(label)\(idle) — owned by another workspace: \(owner). "
                    + "Run `ftester bridge down --port \(port)` from that clone")
            case .reportUnknown:
                findings.append("   - \(label)\(idle) — unknown owner (an old bridge with no self-report). "
                    + "Kill the process from `lsof -ti :\(port)`; on iOS also run "
                    + "`xcrun simctl terminate <udid> com.example.ftrunner.uitests.xctrunner`")
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
        abstract: "Manage the XCUITest bridge (runner)",
        subcommands: [Up.self, Down.self, Status.self])

    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the bridge and keep it resident (iOS: a simulator runner / Android: an on-device server)")

        @Option(help: "Simulator device name (iOS only)")
        var device: String = "iPhone 17 Pro"

        @Flag(help: "Skip build-for-testing when it is already built (iOS only)")
        var skipBuild = false

        @Flag(help: "Also build and install SampleApp (iOS only)")
        var withSampleApp = false

        @Flag(help: "Treat --device as the UDID of a physical iOS device (the Identifier from xcrun devicectl list devices)")
        var physical = false

        @OptionGroup var driverOptions: DriverOptions

        func run() async throws {
            if driverOptions.platform == "android" {
                // serial 省略時は接続中の全デバイス(8台並列前のプリウォーム用)
                for serial in try AndroidBridgeCLI.serials(only: driverOptions.serial) {
                    let driver = try AndroidDriver(serial: serial)
                    print("→ Starting the Android bridge: \(serial)")
                    try await driver.resetAndEnsureBridge()
                    print("✅ \(serial): \(driver.bridgeDoctorSummary())")
                }
                return
            }
            let root = try RepoRoot.find()
            let launcher = BridgeLauncher(repoRoot: root, device: device, port: driverOptions.port,
                                          physical: physical)

            print("→ Generating the project (xcodegen)...")
            try launcher.generateProjectIfNeeded()

            if !skipBuild {
                print("→ build-for-testing (the first run takes several minutes)...")
                try launcher.buildForTesting()
            }
            if withSampleApp {
                print("→ Building and installing SampleApp...")
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
                print("⚠️ Reused the running bridge on this device (port \(port)) instead of the requested/default "
                    + "port \(driverOptions.port). To rebuild on port \(driverOptions.port), stop it first "
                    + "with `ftester bridge down --port \(port)` and run again.")
            }
            let host = provisioned.first?.host ?? BridgeEndpoint.loopbackHost
            print("✅ Bridge ready: http://\(host):\(port)")
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the bridge")

        @Option(name: .long, help: "Port of the bridge to stop (iOS only)")
        var port: UInt16 = BridgeAPI.defaultPort

        @Flag(help: "Stop the bridges on every port (iOS only)")
        var all = false

        @Option(help: "Target platform: ios / android")
        var platform: String = "ios"

        @Option(help: "Android device serial (defaults to every connected device)")
        var serial: String?

        func run() async throws {
            if platform == "android" {
                for serial in try AndroidBridgeCLI.serials(only: serial) {
                    try AndroidDriver(serial: serial).stopBridge()
                    print("✅ Stopped the Android bridge: \(serial)")
                }
                return
            }
            let root = try RepoRoot.find()
            if all {
                let stopped = BridgeLauncher.stopAll(repoRoot: root)
                print(stopped.isEmpty
                      ? "No bridges are running"
                      : "✅ Stopped bridges (port: \(stopped.joined(separator: ", ")))")
            } else {
                let launcher = BridgeLauncher(repoRoot: root, port: port)
                try launcher.stop()
                print("✅ Stopped the bridge (port: \(port))")
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the bridge status")

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
            print("session: \(status.sessionBundleID ?? "none")")
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
            throw ValidationError("no Android device is connected (check adb devices)")
        }
        return serials
    }
}

// MARK: - 手動駆動コマンド

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install an app from a package file (iOS: .app bundle / Android: .apk)")

    @Argument(help: "Path to the package file (iOS: .app bundle / Android: .apk)")
    var packagePath: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        guard FileManager.default.fileExists(atPath: packagePath) else {
            throw ValidationError("package file not found: \(packagePath)")
        }
        try await driverOptions.makeDriver().install(packagePath: packagePath)
        print("✅ Installed: \(packagePath)")
    }
}

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Launch the app under test")

    @Argument(help: "App bundle identifier (e.g. com.example.sampleapp)")
    var bundleID: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().launch(bundleID: bundleID)
        print("✅ Launched: \(bundleID)")
    }
}

struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the accessibility tree of the current screen (compressed)")

    @Flag(help: "Print the raw JSON")
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
    static let configuration = CommandConfiguration(abstract: "Tap an element or a coordinate")

    @Option(help: "Reference number from snapshot")
    var ref: Int?

    @Option(help: "X coordinate (pt)")
    var x: Double?

    @Option(help: "Y coordinate (pt)")
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
            throw ValidationError("specify either --ref or --x/--y")
        }
    }
}

struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text (with --ref, taps the element first)")

    @Option(help: "Reference number of the target field (defaults to the focused element)")
    var ref: Int?

    @Argument(help: "Text to type")
    var text: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().type(ref: ref, text: text)
        print("✅ type \"\(text)\"")
    }
}

struct Swipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Swipe")

    @Argument(help: "Direction: up / down / left / right")
    var direction: String

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        guard let dir = FTSwipeDirection(rawValue: direction) else {
            throw ValidationError("direction must be one of up / down / left / right")
        }
        try await driverOptions.makeDriver().swipe(dir)
        print("✅ swipe \(direction)")
    }
}

struct Press: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Long-press an element")

    @Option(help: "Reference number")
    var ref: Int

    @Option(help: "Press duration in seconds")
    var duration: Double = 1.0

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().press(ref: ref, duration: duration)
        print("✅ press [\(ref)] \(duration)s")
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a screenshot")

    @Option(name: .shortAndLong, help: "Output PNG path")
    var output: String = "screenshot.png"

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let data = try await driverOptions.makeDriver().screenshot()
        try data.write(to: URL(fileURLWithPath: output))
        print("✅ Saved: \(output) (\(data.count) bytes)")
    }
}

struct Terminate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Terminate the app under test")

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        try await driverOptions.makeDriver().terminate()
        print("✅ Terminated")
    }
}

// MARK: - 実行コマンド

struct RunScenarios: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run Swift DSL scenarios (Projects/<name>/Scenarios/). FM only steps in on failure")

    @Option(help: "Test project name (defaults to the only one in Projects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json). Includes device provisioning and auto-install")
    var profile: String?

    @Option(name: .customLong("scenario"), parsing: .upToNextOption,
            help: "Scenario IDs to run (Class.method; a class name alone runs all of its scenarios). Repeatable; defaults to all. @Deleted scenarios run only on an exact match")
    var scenarios: [String] = []

    @Option(name: .customLong("folder"), parsing: .upToNextOption,
            help: "Scenario folders to run (subfolders directly under Scenarios/). Repeatable; can be combined with --scenario and --failed")
    var folders: [String] = []

    @Flag(help: "Allow FM-based locator self-healing")
    var heal = false

    @Flag(name: .customLong("no-lpt"),
          help: "Disable LPT ordering (longest past runtime first) and dispatch in scenario ID order")
    var noLPT = false

    @Option(name: .customLong("lpt-history-runs"),
            help: "Number of past runs to read for LPT ordering (newest first, default 5)")
    var lptHistoryRuns: Int?

    @Flag(help: "Run only the scenarios that failed last time (results are recorded in .ftester/last-results/ on every run)")
    var failed = false

    @Option(name: .customLong("report-dir"),
            help: "Directory to write reports to (defaults to Projects/<name>/reports)")
    var reportDir: String?

    @Option(help: "Comma-separated bridge ports for running iOS scenarios in parallel (e.g. 8123,8124). Each port must already have bridge up on a separate device")
    var ports: String?

    @Flag(name: .customLong("skip-build"), help: "Skip the swift build before running")
    var skipBuild = false

    @Flag(help: "Suppress step lines and print only the summary (for CI and agents)")
    var quiet = false

    @Option(help: "Write a JUnit XML report of this run to the given path (for CI test reporting)")
    var junit: String?

    @Flag(name: .customLong("fast-input"),
          help: "Enable fast input on the iOS xcuitest bridge (skips the quiescence wait). Can also be set via iosFastInput in the run profile")
    var fastInput = false

    @Option(help: "Dispatch this run to a remote Mac over SSH (user@host or host). Requires --profile. Experimental (docs/remote-runner.md)")
    var host: String?

    @Option(name: .customLong("remote-dir"),
            help: "Runner-only base directory on the remote host (holds its own clone and workspace; default: ~/ftester-runner). Must NOT point at an existing local install of foundation-tester")
    var remoteDir: String = "~/ftester-runner"

    @Option(name: .customLong("remote-timeout"),
            help: "Timeout in seconds for the whole remote dispatch (default: auto, sized from the scenario count; see docs/remote-runner.md)")
    var remoteTimeout: Int?

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        // BridgeClient(ホスト・サブプロセス両方)が FT_FAST_INPUT を読む。プロファイル指定分は
        // ProfileRunner が同様に注入する
        if fastInput { setenv("FT_FAST_INPUT", "1", 1) }
        if let host {
            try await dispatchToRemoteHost(host)
            return
        }
        PhaseLog.mark("start")
        let testProject = try ScenarioHost.project(named: project)
        PhaseLog.mark("project-resolved")

        // ビルドはホスト側で 1 回だけ(サブプロセスは自らビルドしない)
        if !skipBuild {
            print("→ Building scenarios (\(testProject.name))...")
            try ScenarioHost.build(project: testProject)
        }
        PhaseLog.mark("build")
        let all = try ScenarioHost.list(project: testProject)
        PhaseLog.mark("scenario-list")
        guard !all.isEmpty else {
            throw ValidationError(
                "no scenarios (add a @TestClass under Projects/\(testProject.name)/Scenarios/)")
        }
        var selected = try Self.resolve(scenarios, from: all)
        if scenarios.isEmpty {
            let deletedCount = all.filter(\.deleted).count
            if deletedCount > 0 {
                print("→ Excluded \(deletedCount) deleted (@Deleted) scenario(s)")
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
                print("No scenarios failed last time (everything passed, or nothing has run)")
                return
            }
            print("→ Re-running the \(selected.count) scenario(s) that failed last time")
        }
        guard !selected.isEmpty else {
            print("Nothing to run (every scenario is marked @Deleted)")
            return
        }
        // LPT 投入順の適用は実行経路ごとに行う(実効 platform が確定してからでないと
        // 別 platform の実績で並べてしまう): --profile は ProfileRunner.run、--ports は runParallel。
        // 逐次実行は並列度が無いので並べ替えない
        let items = selected.map { ScenarioRunItem(info: $0) }

        if FMDoctor.check().available == false {
            print("⚠️ Foundation Models unavailable: self-healing, screenIs and triage are disabled")
        } else if !FMVisionSupport.isSupported {
            print("⚠️ \(FMVisionSupport.requirement): screenIs and occlusion-guard are disabled"
                  + " (self-healing and triage stay enabled)")
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
            try writeJUnitIfRequested(project: testProject, recorder: recorder)
            print(failedCount == 0
                  ? "✅ All \(items.count) scenario(s) passed"
                  : "❌ \(failedCount) of \(items.count) scenario(s) failed")
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
        try writeJUnitIfRequested(project: testProject, recorder: recorder)

        print(failedCount == 0
              ? "✅ All \(items.count) scenario(s) passed"
              : "❌ \(failedCount) of \(items.count) scenario(s) failed")
        if failedCount > 0 {
            throw ExitCode(1)
        }
    }

    /// `--host`: ローカルビルド・実行をせず、対等ピア(SSH 到達可能な foundation-tester clone)
    /// に丸ごとディスパッチする(docs/remote-runner.md §3・§7・Phase 1)。デバイス割当競合を
    /// 避けるためリモート1本での実行のみサポートし、ローカル専用オプションは併用不可にする
    private func dispatchToRemoteHost(_ rawHost: String) async throws {
        guard let profile else {
            throw ValidationError("--host requires --profile")
        }
        if ports != nil {
            throw ValidationError("--ports is not supported with --host")
        }
        if reportDir != nil {
            throw ValidationError("--report-dir is not supported with --host")
        }
        if failed {
            throw ValidationError("--failed is not supported with --host")
        }
        if skipBuild {
            throw ValidationError("--skip-build is not supported with --host")
        }

        try RemoteLayout.validateBase(remoteDir)
        let hostSpec = try RemoteHostSpec.parse(rawHost)
        let testProject = try ScenarioHost.project(named: project)
        let localRoot = try RepoRoot.find()
        let dispatcher = RemoteRunDispatcher(
            host: hostSpec, remoteDirRaw: remoteDir, localRepoRoot: localRoot)
        let exitCode = try await dispatcher.dispatch(
            project: testProject, profile: profile, scenarios: scenarios, folders: folders,
            heal: heal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            fastInput: fastInput, localJUnitPath: junit, remoteTimeoutSeconds: remoteTimeout)
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    /// --junit: run の記録(runDir/scenarios/*.json)から JUnit XML を書き出す。
    /// **ExitCode(1) を投げる前に呼ぶ**(失敗 run こそ CI がレポートを要る)。
    /// 書き込み失敗は run の成否を変えない(warn のみ。CI 側はファイル欠如で気付ける)
    private func writeJUnitIfRequested(project: TestProject, recorder: RunRecorder) throws {
        guard let junit else { return }
        let records = RunResultsStore.records(runDir: recorder.runDir)
        let xml = JUnitReportWriter.xml(project: project.name, records: records)
        let url = URL(fileURLWithPath: junit)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: url, atomically: true, encoding: .utf8)
            print("📄 JUnit report: \(junit) (\(records.count) testcase(s))")
        } catch {
            print("⚠️ Failed to write the JUnit report: \(junit) (\(error.localizedDescription))")
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
                        "every scenario of \(id) is deleted (@Deleted)"
                        + " (an exact Class.method reference still runs it)")
                }
                throw ValidationError(
                    "scenario not found: \(id) (available: \(all.map(\.id).joined(separator: ", ")))")
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
                    "folder not found: \(unknown.joined(separator: ", "))"
                    + " (available: \(available.joined(separator: ", ")))")
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
        print("🚀 Parallel run: \(iosPorts.count) iOS worker(s) (port: \(portList))"
              + (androidItems.isEmpty ? "" : " + 1 Android worker") + "\n")

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
                print("❌ Cannot initialise the Android driver (adb not found)")
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

