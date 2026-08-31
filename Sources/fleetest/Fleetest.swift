import ArgumentParser
import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import FTDSL

@main
struct Fleetest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fleetest",
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
            ProfileCommand.self,
            DevicesCommand.self,
            ApiCommand.self,
            ResultsCommand.self,
            RemoteCommand.self,
            HooksCommand.self,
            MonitorCommand.self,
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

    /// FTFoundationModels/FTCore はこの抽象のみに依存(BridgeClient/AndroidDriver を直接見ない)
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

        // ランナーをビルドした Xcode/SDK と現在のものの一致確認。Xcode(beta)更新後に
        // 旧ビルドのランナーを使う・逆に新ビルドのランナーを旧ランタイムに載せると、アプリが
        // 実行中に「Application is not running」でクラッシュする(2026-07-21 実害)。
        // 判定は再ビルドの砦と同じ指紋(BridgeLauncher.staleRunnerToolchain)。
        // **成果物の Info.plist は見ない** —— 理由は同関数の doc(テンプレートのコピー)
        if let root = try? RepoRoot.find(),
           let stored = BridgeLauncher.staleRunnerToolchain(repoRoot: root) {
            print("⚠️ The XCUITest runner was built with a different toolchain (\(stored)). "
                + "The next bridge start rebuilds it; if the iOS runtime for the new Xcode is missing, "
                + "install it first (xcodebuild -downloadPlatform iOS)")
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
                print("   ⚠️ \(AndroidSDKLocator.avdManagerMissingMessage). "
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
    /// なり、取り違えると「InAppBridge/build.sh が無い」「TestProjects/ が見えない」で詰まる(実害あり)
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
        let stateDir = root.appendingPathComponent(".fleetest")
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
                    + "Run `fleetest bridge down --port \(port)` from that clone")
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
            print("✅ Scenario package (TestProjects/): \(packageRoot.path)")
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
                    + "with `fleetest bridge down --port \(port)` and run again.")
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
                let stopped = BridgeLauncher.stopAll(repoRoot: root, skipPhysical: false)
                print(stopped.isEmpty
                      ? "No bridges are running"
                      : "✅ Stopped bridges (port: \(stopped.joined(separator: ", ")))")
            } else {
                // physical は stop() が見ない(kind を知らない経路からも止められるよう、
                // stop() 側が条件分岐しない宣言をしている)ので false でよい
                let launcher = BridgeLauncher(repoRoot: root, port: port, physical: false)
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
        abstract: "Install an app from a package file (iOS: .app bundle / Android: .apk or .apks)")

    @Argument(help: "Path to the package file (iOS: .app bundle / Android: .apk, or .apks via bundletool)")
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
        abstract: "Run Swift DSL scenarios (TestProjects/<name>/scenarios/). FM only steps in on failure")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json). Includes device provisioning and auto-install")
    var profile: String?

    @Option(name: .customLong("scenario"), parsing: .upToNextOption,
            help: "Scenario IDs to run (Class.method; a class name alone runs all of its scenarios). Repeatable; defaults to all. @Deleted / @Draft scenarios run only on an exact match")
    var scenarios: [String] = []

    @Option(name: .customLong("folder"), parsing: .upToNextOption,
            help: "Scenario folders to run (subfolders directly under scenarios/). Repeatable; can be combined with --scenario and --failed")
    var folders: [String] = []

    @Flag(help: "Allow FM-based locator self-healing")
    var heal = false

    @Flag(name: .customLong("no-heal"),
          help: "Disable FM-based locator self-healing even when the run profile enables it (--profile runs default to heal: true)")
    var noHeal = false

    @Flag(name: .customLong("dry-run"),
          help: "Enumerate and validate the steps without touching a device (No-Load-Run). Catches selector syntax errors, unreachable scenes and expectation blocks with no assertions")
    var dryRun = false

    @Flag(name: .customLong("no-lpt"),
          help: "Disable LPT ordering (longest past runtime first) and dispatch in scenario ID order")
    var noLPT = false

    @Option(name: .customLong("lpt-history-runs"),
            help: "Number of past runs to read for LPT ordering (newest first, default 5)")
    var lptHistoryRuns: Int?

    @Flag(help: "Run only the scenarios that failed last time (results are recorded in .fleetest/last-results/ on every run)")
    var failed = false

    @Option(name: .customLong("report-dir"),
            help: "Directory to write reports to (defaults to TestProjects/<name>/reports)")
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

    /// 用語と使い分けは ApiRunCommand の同名オプション参照(machine = 登録簿の名前 =
    /// ローカルエイリアス、host = ホスト名 / IP)
    @Option(name: .customLong("machine"),
            help: "Dispatch this run to the registered machine (fleetest remote hosts). Requires --profile")
    var machine: String?

    @Option(help: "Dispatch this run to this host name / IP (user@host or host) over SSH. Prefer --machine for a registered machine. Requires --profile. Experimental (docs/remote-runner.md)")
    var host: String?

    /// 両方あれば --machine を優先(ApiRunCommand.dispatchTarget と同じ規律)
    var dispatchTarget: String? { machine ?? host }

    @Option(name: .customLong("remote-dir"),
            help: "Runner-only base directory on the remote host (holds its own clone and workspace; default: the host registry's entry, or ~/fleetest-runner). Must NOT point at an existing local install of foundation-tester")
    var remoteDir: String?

    @Option(name: .customLong("remote-timeout"),
            help: "Timeout in seconds for the whole remote dispatch (default: auto, sized from the scenario count; see docs/remote-runner.md)")
    var remoteTimeout: Int?

    @Option(name: .customLong("remote-artifacts"),
            help: "Collect recordings and run logs (results/) from the remote after the run: collect (default) or on-demand (leave them on the remote; docs/remote-runner.md)")
    var remoteArtifacts: String = "collect"

    @Flag(name: .customLong("enable-animations"),
          help: "Keep the app's animations instead of turning them off on the device. Can also be set via enableAnimations in the run profile")
    var enableAnimations = false

    @Flag(name: .customLong("performance"),
          help: "Performance-testing mode (--profile only): if a dead lane cannot be revived before the run starts, fail instead of dropping it and continuing on the remaining lanes. iOS lanes are built before the run starts (no late join) so a missing one is reported before the run, not in the middle of it")
    var performanceMode = false

    @Option(help: ArgumentHelp("Dispatch this run across a fleet of hosts in parallel: "
        + "profiles/fleets/<name>.json (docs/remote-runner.md §13). Each entry runs as its own "
        + "child process, with output lines prefixed by the entry's host name. Mutually exclusive "
        + "with --host/--profile/--ports/--failed/--report-dir/--skip-build. --junit is supported: "
        + "each entry's report is merged into one file (docs/remote-runner.md §8). Experimental"))
    var fleet: String?

    @Flag(help: ArgumentHelp("With --fleet: distribute the scenario set across the fleet's entries "
        + "(LPT bin packing by past duration; docs/remote-runner.md §8) instead of running the same "
        + "set on every entry. Requires a local build+scenario list to resolve the assignment "
        + "(skipped by plain --fleet), and resolves each entry's platform from its run profile's "
        + "devices. Entries assigned 0 scenarios are not dispatched. Experimental"))
    var split = false

    @Flag(name: .customLong("force-lock"),
          help: ArgumentHelp("Steal a remote host's dispatch.lock instead of failing fast when another dispatch "
            + "already holds it (docs/remote-runner.md §5). Needs a run profile, --host or --fleet"))
    var forceLock = false

    @Option(name: .customLong("wait-lock"),
            help: ArgumentHelp("Instead of failing fast, poll until a remote host's dispatch.lock is released, "
              + "up to this many seconds (docs/remote-runner.md §5). Needs a run profile, --host or --fleet. "
              + "Cannot be combined with --force-lock"))
    var waitLock: Int?

    /// ブロードキャスト実行。warmup のように「全デバイスがそれぞれ準備される」
    /// ことが目的の run 向け。分配だけを `ScenarioDispatch.broadcast` に差し替え、他は通常 run
    /// (ProfileRunner.run)と同じ経路。**--profile が要る**(レーン = プロファイルのデバイス)
    @Flag(name: .customLong("broadcast"),
          help: ArgumentHelp("Run the selected scenarios once on EVERY device of the run profile "
            + "(broadcast) instead of sharing them out across the devices — e.g. a warm-up that must "
            + "touch each device. Needs --profile; --device narrows the set of devices. Provisioning, "
            + "auto-install, setup/teardown hooks (once per run), staggered start, lane revival and "
            + "reports are the same as a normal run. Results: one scenarios/*.json per (scenario, device), "
            + "told apart by their worker field"))
    var broadcast = false

    @Option(name: .customLong("device"), parsing: .upToNextOption,
            help: ArgumentHelp("Run on only these devices of the run profile (device names as written in "
                + "the machine profile). Repeatable; defaults to every device the run profile lists. "
                + "Used by the per-host sub-runs when one run profile spans devices on several machines "
                + "(docs/remote-runner.md §13)"))
    var devices: [String] = []

    /// **どの機械のデバイスを使うか**。`--device` は名前でしか絞れないが、一意なのは (host, name)
    /// なので、名前だけだと別の機械の同名デバイスまで掴む(docs/remote-runner.md §13)。
    /// マシン別サブ実行が自分で付ける値で、手で打つものではない
    @Option(name: [.customLong("device-machine"), .customLong("device-host")],
            help: ArgumentHelp(
                "Only use the devices assigned to this machine (\"local\" or a registered host name). "
                + "Set by the per-host sub-runs; not for hand use",
                visibility: .hidden))
    var deviceMachine: String?

    /// 同じ実行から分かれた run を束ねる鍵(FTCore.RunMetaRecord.runGroup)。**発行は
    /// マシン別サブ実行の親だけ**で、子は受け取った値をそのまま run.json に書く。手で打つものではない
    @Option(name: .customLong("run-group"),
            help: ArgumentHelp(
                "Group key shared by the per-machine sub-runs of one execution. "
                + "Set by the per-host sub-runs; not for hand use",
                visibility: .hidden))
    var runGroup: String?

    /// **手で打つものではない**。RemoteRunDispatcher がミラー後の絶対パスを渡す
    /// (Sources/FTRemote/RemoteDispatch.swift の RemoteRunArgs.build)。プロファイルの
    /// `remoteControl.workspace` を上書きし、appPath のインストール先(ステージ先。原本の解決基準は
    /// 常にリポジトリルートで不変)をそちらへ切り替える(ProfileResolver.resolve の
    /// workspaceOverride / WorkspaceAppStaging 参照)
    @Option(help: ArgumentHelp(
        "Override this run profile's remoteControl.workspace (where the staged appPath package is "
        + "installed from). Set by the remote dispatcher on the far side; not for hand use",
        visibility: .hidden))
    var workspace: String?

    /// `@TestClass(app:)` を書かないシナリオを **実行プロファイル無し**で回すときの逃げ道。
    /// --profile があればそちらのアプリプロファイルから解決されるのでこれは要らない
    @Option(name: .customLong("app"),
            help: "Default app (bundle ID / package name) for scenarios that declare no @TestClass(app:). Only needed without --profile; with --profile the app profile supplies it")
    var app: String?

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws {
        if heal && noHeal {
            throw ValidationError("--heal and --no-heal cannot be used together")
        }
        if fleet != nil {
            if host != nil { throw ValidationError("--fleet cannot be combined with --host") }
            if profile != nil {
                throw ValidationError(
                    "--fleet cannot be combined with --profile (set profile per entry in the fleet file)")
            }
            if ports != nil { throw ValidationError("--fleet cannot be combined with --ports") }
            if failed { throw ValidationError("--fleet cannot be combined with --failed") }
            if reportDir != nil { throw ValidationError("--fleet cannot be combined with --report-dir") }
            if skipBuild { throw ValidationError("--fleet cannot be combined with --skip-build") }
        }
        if split, fleet == nil {
            throw ValidationError("--split requires --fleet")
        }
        if broadcast {
            // 黙って無視しない(fleet の子へは中継していない。ports 経路にはレーンの名が無い)
            if fleet != nil { throw ValidationError("--broadcast cannot be combined with --fleet") }
            if profile == nil { throw ValidationError("--broadcast requires --profile") }
        }
        if forceLock, let message = RemoteDispatchFlagPolicy.forceLockRejection(
            host: dispatchTarget, fleet: fleet, profile: profile) {
            throw ValidationError(message)
        }
        if let message = RemoteDispatchFlagPolicy.waitLockConflictsWithForceLock(
            forceLock: forceLock, waitLock: waitLock) {
            throw ValidationError(message)
        }
        if waitLock != nil, let message = RemoteDispatchFlagPolicy.waitLockRejection(
            host: dispatchTarget, fleet: fleet, profile: profile) {
            throw ValidationError(message)
        }
    }

    func run() async throws {
        // BridgeClient(ホスト・サブプロセス両方)が FT_FAST_INPUT を読む。プロファイル指定分は
        // ProfileRunner が同様に注入する
        if fastInput { setenv("FT_FAST_INPUT", "1", 1) }
        // プロファイル指定分は ProfileRunner が注入する(こちらは ON 側の上書きのみ)
        if enableAnimations { setenv(AnimationPolicy.environmentKey, "1", 1) }
        // リモート実行はここで打ち切る(以降はローカル実行の段取り。フラグはコマンドラインごと
        // リモートへ中継されるので、向こう側の fleetest が同じ env を自分で立てる)。
        // dry-run だけは送らない(--host 明示・マシンプロファイルの host 自動のどちらも。
        // 理由と罠は RemoteDispatchGate の宣言。優先順位・食い違いは resolveEffectiveDispatchTarget
        // → FTCore.MachineDispatch に委譲。ユーザー決定: マシンプロファイルで
        // host を持たせることで、実行プロファイル経由で間接的にリモートを指定できるようにした)
        // デバイスが複数の機械にまたがる実行プロファイルは、ホストごとのサブ実行へ分ける
        // (単一ディスパッチでは「そのホストに無いデバイス」が解決できない)。--host 明示や
        // 全台が同じ機械なら nil が返り、従来の経路をそのまま通る
        if !dryRun, fleet == nil, let profile,
           let groups = try DeviceMachineRunner.plan(
               project: try ScenarioHost.project(named: project), profileName: profile,
               explicitHost: dispatchTarget, deviceFilter: devices) {
            let exitCode = try await DeviceMachineRunner.run(
                project: try ScenarioHost.project(named: project), profileName: profile,
                groups: groups, scenarios: scenarios, folders: folders,
                heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                fastInput: fastInput, enableAnimations: enableAnimations,
                performanceMode: performanceMode, forceLock: forceLock, waitLock: waitLock,
                remoteDir: remoteDir, remoteTimeout: remoteTimeout,
                remoteArtifacts: remoteArtifacts, quiet: quiet, junit: junit,
                broadcast: broadcast)
            if exitCode != 0 { throw ExitCode(exitCode) }
            return
        }
        if !dryRun, let dispatch = try resolveEffectiveDispatchTarget(
        explicitTarget: dispatchTarget, profile: profile, project: project,
            requireProfileMachine: true, warn: { print("⚠️ \($0)") }) {
            try await dispatchToRemoteHost(dispatch)
            return
        }
        // dry-run だけは送らない(--host と同じ規律。RemoteDispatchGate の宣言参照)
        if let fleet, !dryRun {
            try await dispatchToFleet(fleet)
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
                "no scenarios (add a @TestClass under TestProjects/\(testProject.name)/scenarios/)")
        }
        var selected = try Self.resolve(scenarios, from: all)
        if scenarios.isEmpty {
            let deletedCount = all.filter(\.deleted).count
            if deletedCount > 0 {
                print("→ Excluded \(deletedCount) deleted (@Deleted) scenario(s)")
            }
            // deleted 側と二重計上しないよう、deleted も付いているものは deleted のほうで数える
            let draftCount = all.filter { $0.draft && !$0.deleted }.count
            if draftCount > 0 {
                print("→ Excluded \(draftCount) draft (@Draft) scenario(s)")
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
            print("Nothing to run (every scenario is marked @Deleted or @Draft)")
            return
        }
        // LPT 投入順の適用は実行経路ごとに行う(実効 platform が確定してからでないと
        // 別 platform の実績で並べてしまう): --profile は ProfileRunner.run、--ports は runParallel。
        // 逐次実行は並列度が無いので並べ替えない
        let items = selected.map { ScenarioRunItem(info: $0) }

        // dry-run はデバイスにも FM にも触れないので、供給・接続・FM 診断・結果記録を全部飛ばす。
        // **RunRecorder を作らない**(実行していない結果を results DB と --failed の判断材料に
        // 混ぜないため。ScenarioHost も dryRun では LastResultsStore へ書かない)
        if dryRun {
            if profile != nil {
                print("ℹ️ --dry-run touches no device, so --profile is not used"
                      + " (--platform decides which ios { } / android { } blocks run)")
            }
            if host != nil {
                print("ℹ️ --dry-run touches no device, so --host is not used"
                      + " (the scenarios are validated locally, from the same source the remote would run)")
            }
            if fleet != nil {
                print("ℹ️ --dry-run touches no device, so --fleet is not used"
                      + " (the scenarios are validated locally, from the same source every fleet entry would run)")
            }
            let failedCount = await runDryRun(items, project: testProject)
            print(failedCount == 0
                  ? "✅ All \(items.count) scenario(s) passed the dry-run"
                  : "❌ \(failedCount) of \(items.count) scenario(s) failed the dry-run")
            if failedCount > 0 { throw ExitCode(1) }
            return
        }

        if FMDoctor.check().available == false {
            print("⚠️ Foundation Models unavailable: self-healing, screenLooksLike and triage are disabled")
        } else if !FMVisionSupport.isSupported {
            print("⚠️ \(FMVisionSupport.requirement): screenLooksLike and occlusion-guard are disabled"
                  + " (self-healing and triage stay enabled)")
        }

        PhaseLog.mark("fm-doctor")
        let recorder = RunRecorder.begin(project: testProject, profile: profile, trigger: "cli",
                                         runGroup: runGroup)
        PhaseLog.mark("recorder-begin")

        if let profile {
            // 明示 --host local はこの機械で走らせる指定なので、ホスト混在プロファイルでは
            // local 枠だけに絞る(他ホスト担当分まで手元で解決すると存在しない台を掴む。
            // マシン別サブ実行は --device/--device-machine を持つのでこの分岐に入らない)。
            // **明示 --device があっても絞る** —— 名前だけでは同名の台が別の機械にもあるとき
            // そちらのエントリに解決し、向こうの UDID を手元で探して
            // "no simulator with that UDID" で止まる(受け手報告 2026-08-24)。判定は
            // --host <リモート> と同じ machineScopedDeviceFilter(RemoteDispatchExplicitDeviceScope)
            var effectiveDeviceFilter = devices
            var effectiveDeviceHost = deviceMachine
            if deviceMachine == nil, MachineDispatch.isExplicitLocal(dispatchTarget) {
                (effectiveDeviceFilter, effectiveDeviceHost) = try machineScopedDeviceFilter(
                    project: testProject, profile: profile,
                    targetMachine: DeviceMachineGrouping.localDisplayName, requestedDevices: devices)
            }
            let runSummary = try await ProfileRunner.run(
                project: testProject, profileName: profile, items: items,
                healOverride: ProfileRunner.healOverride(heal: heal, noHeal: noHeal),
                reportDirOverride: reportDir,
                quiet: quiet, lpt: !noLPT,
                lptHistoryRuns: lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns,
                performanceMode: performanceMode,
                deviceFilter: effectiveDeviceFilter,
                deviceMachine: effectiveDeviceHost,
                workspaceOverride: workspace,
                recorder: recorder,
                broadcast: broadcast)
            let failedCount = runSummary.failed
            // **回した本数は items.count ではない** —— ProfileRunner が OS 対象外
            // (`@TestClass(platform:)` / `@Test(platform:)`)を投入前に外すので、
            // ここで items.count を使うと「12本全部成功」と出しつつ10本しか走っていない、になる
            let ranCount = runSummary.total
            // --broadcast の total は (本数 × 台数) なので items.count との差は対象外の数にならない
            // (対象外の件数は ProfileRunner が「Skipped N scenario(s) …」で出している)
            let notApplicable = broadcast ? 0 : items.count - ranCount
            PhaseLog.mark("profile-run-done")
            recorder.finish(total: ranCount, passed: ranCount - failedCount, failed: failedCount,
                            degradedWorkers: runSummary.degradedWorkers,
                            freezeRetries: runSummary.freezeRetries,
                            blankRepairs: runSummary.blankRepairs,
                            blankExclusions: runSummary.blankExclusions,
                            measurementInvalid: runSummary.measurementInvalid,
                            measurementInvalidReasons: runSummary.measurementInvalidReasons,
                            workerAnomalies: runSummary.workerAnomalies)
            PhaseLog.mark("recorder-finish")
            try writeJUnitIfRequested(project: testProject, recorder: recorder)
            let skippedSuffix = notApplicable > 0
                ? " (\(notApplicable) skipped: declared for another platform)" : ""
            // --broadcast は (シナリオ × デバイス) を数える。単位を言わないと「3本のはずが
            // 24 passed」に見える
            let unit = broadcast ? "scenario run(s) (one per scenario per device)" : "scenario(s)"
            print(failedCount == 0
                  ? "✅ All \(ranCount) \(unit) passed\(skippedSuffix)"
                  : "❌ \(failedCount) of \(ranCount) \(unit) failed\(skippedSuffix)")
            // **合否は変えず、劣化だけ伝える**。FM が死んでいると occlusion-guard・
            // 自己修復・screenLooksLike が黙って素通りするので、緑は「守りが効いた緑」ではない。
            // 赤のときも、切り分けの出発点として先に知りたい情報(自分の変更か FM か)
            if runSummary.fmUnavailableScenarios > 0 {
                print("⚠️ FM unavailable: \(runSummary.fmUnavailableScenarios) scenario(s) ran"
                    + " with occlusion-guard / self-healing / screenLooksLike silently disabled."
                    + " Read this run's result with that in mind"
                    + " (confirm with: fleetest doctor --fm-only)")
            }
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

    /// `--host` または(自動)マシンプロファイルの `host`: ローカルビルド・実行をせず、対等ピア
    /// (SSH 到達可能な foundation-tester clone)に丸ごとディスパッチする
    /// (docs/remote-runner.md §3・§7・Phase 1)。デバイス割当競合を避けるためリモート1本での
    /// 実行のみサポートし、ローカル専用オプションは併用不可にする
    private func dispatchToRemoteHost(_ dispatch: EffectiveDispatchTarget) async throws {
        guard let profile else {
            throw ValidationError("--host requires --profile")
        }
        // 拒否 or 注記の分岐は FTRemote.RemoteDispatchFlagPolicy に委譲(欠陥1)。origin が
        // 自動ディスパッチ(マシンプロファイルの host)なら --skip-build は注記のみで無視する
        // (リモートは常に自前でビルドする)。他の3つは自動でも意味を持たせられないため拒否のまま
        let origin = dispatch.origin
        if ports != nil {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--ports", origin: origin))
        }
        if reportDir != nil {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--report-dir", origin: origin))
        }
        if failed {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.rejected(flag: "--failed", origin: origin))
        }
        if skipBuild {
            try applyFlagPolicy(RemoteDispatchFlagPolicy.skipBuild(origin: origin))
        }

        let resolved = try resolveRemoteTarget(dispatch, remoteDirOverride: remoteDir)
        resolved.announce()
        let artifactsMode = try RemoteArtifactsMode.parse(remoteArtifacts)
        let testProject = try ScenarioHost.project(named: project)
        let localRoot = try RepoRoot.find()
        let dispatcher = RemoteRunDispatcher(
            host: resolved.hostSpec, remoteDirRaw: resolved.remoteDirRaw, localRepoRoot: localRoot,
            artifacts: artifactsMode, forceLock: forceLock, waitLock: waitLock, hostLabel: dispatch.rawTarget)
        var scopedDevices = devices
        var scopedDeviceHost = deviceMachine
        if deviceMachine == nil {
            (scopedDevices, scopedDeviceHost) = try machineScopedDeviceFilter(
                project: testProject, profile: profile, targetMachine: dispatch.rawTarget, requestedDevices: devices)
        }
        let exitCode = try await dispatcher.dispatch(
            project: testProject, profile: profile, scenarios: scenarios, folders: folders,
            deviceNames: scopedDevices, deviceMachine: scopedDeviceHost,
            heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            fastInput: fastInput, enableAnimations: enableAnimations,
            performanceMode: performanceMode, broadcast: broadcast,
            localJUnitPath: junit, remoteTimeoutSeconds: remoteTimeout, runGroup: runGroup)
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    /// RemoteDispatchFlagPolicy.Decision の適用。注記は FileHandle 直書き(print を使わない —
    /// RemoteRunDispatcher.log と同じ規律。stdout が端末でないと libc の行バッファが効かず
    /// 出力が遅延・欠落しうる)
    private func applyFlagPolicy(_ decision: RemoteDispatchFlagPolicy.Decision) throws {
        switch decision {
        case .allowed:
            return
        case .ignoredWithNote(let note):
            FileHandle.standardOutput.write(Data((note + "\n").utf8))
        case .rejected(let message):
            throw ValidationError(message)
        }
    }

    /// `--fleet`: profiles/fleets/<name>.json の全エントリを並行実行する(docs/remote-runner.md
    /// §13)。検証は投入前に全部済ませる(FleetProfile.validate)。実体は FleetRunner
    /// (エントリごとに子プロセスを起動し、出力を host 名で前置する)
    private func dispatchToFleet(_ fleetName: String) async throws {
        let testProject = try ScenarioHost.project(named: project)
        let doc = try FleetProfile.load(project: testProject, name: fleetName)
        let registeredNames = Set((LocalConfig.load().remoteHosts ?? []).map(\.machine))
        let issues = FleetProfile.validate(doc, project: testProject, registeredHostNames: registeredNames)
        guard issues.isEmpty else {
            throw ValidationError((["fleet \"\(fleetName)\" is invalid:"] + issues.map { "  - \($0)" })
                .joined(separator: "\n"))
        }
        let exitCode = try await FleetRunner.run(
            project: testProject, fleetName: fleetName, fleet: doc,
            scenarios: scenarios, folders: folders,
            heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            fastInput: fastInput, enableAnimations: enableAnimations, performanceMode: performanceMode,
            forceLock: forceLock, waitLock: waitLock, remoteDir: remoteDir, remoteTimeout: remoteTimeout,
            remoteArtifacts: remoteArtifacts, split: split, quiet: quiet, junit: junit)
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

    /// @Deleted(論理削除)/ @Draft(実装中)は全件実行・クラス名展開から除外
    /// (完全一致の明示指定のみ実行可。実装しながら個別に回す運用のため)
    static func resolve(_ ids: [String], from all: [ScenarioInfo]) throws -> [ScenarioInfo] {
        guard !ids.isEmpty else { return all.filter { !$0.deleted && !$0.draft } }
        var result: [ScenarioInfo] = []
        for id in ids {
            if let exact = all.first(where: { $0.id == id }) {
                result.append(exact)
                continue
            }
            let classMatches = all.filter { $0.id.hasPrefix(id + ".") && !$0.deleted && !$0.draft }
            guard !classMatches.isEmpty else {
                if all.contains(where: { $0.id.hasPrefix(id + ".") }) {
                    let allDeleted = all.filter { $0.id.hasPrefix(id + ".") }.allSatisfy(\.deleted)
                    let reason = allDeleted
                        ? "is deleted (@Deleted)"
                        : "is deleted (@Deleted) or a draft (@Draft)"
                    throw ValidationError(
                        "every scenario of \(id) \(reason)"
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
    /// launch 事前検査(LaunchPreflightDriver)と FastLaunch 用。
    /// **プロファイル経路は provision の udid を渡すのでここを通らない** —— これは
    /// `--port` 直指定の経路だけの相関。
    ///
    /// 同名複数・未起動・応答なしは nil(検査なしで従来動作)だが、**黙って落とさない**:
    /// 事前検査が外れると、未インストールのまま launch して XCUITest ランナーが死ぬ経路
    /// (LaunchPreflightDriver のコメント)がそのまま開く。Xcode はランタイムごとに同名の
    /// シミュレータを作るので、同名2台は受け手環境で普通に起きる(2026-08-06 に実例)
    private static func resolveUdid(port: UInt16) async -> String? {
        guard let status = try? await BridgeClient(port: port, timeoutSeconds: 5).status(),
              let catalog = try? SimulatorCatalog.devices() else { return nil }
        let matches = catalog.filter { $0.booted && $0.name == status.device }
        if matches.count == 1 { return matches[0].udid }
        FileHandle.standardError.write(Data(
            ("install preflight and fast launch are disabled:"
             + " \(matches.count) booted simulators are named \"\(status.device)\"."
             + " Launching an app that is not installed will kill the XCUITest runner."
             + " Use a run profile (--profile) to target a simulator by UDID.\n").utf8))
        return nil
    }

    // MARK: - 逐次実行(ライブ出力)

    /// dry-run(No-Load-Run): デバイスにも FM にも触れずステップを列挙・検証する。
    /// **レポートは一時ディレクトリへ書かせて捨てる** —— ランナーは dry-run でもレポートを書くので、
    /// 実行していない結果を reports/ に残すと results の集計と紛れる(`ScenarioHost.dryRunSteps`・
    /// MCP の `ft_dry_run` と同じ扱い。案内すると開けないパスを渡すことになるので report 行も落とす)。
    /// 接続情報は NullDriver 固定のため使われず、**platform だけが `ios { }` / `android { }` の
    /// 分岐と `#id` 台帳の照合に効く**。整形は MCP・サブプロセスと同じ `ScenarioLogFormatter`
    /// `--app` は platform 別に書き分けられないので両 platform に同じ値を配る
    /// (書き分けが要るなら実行プロファイルを使う)。nil なら空 = 子が明示エラーを出す
    static func appBundleIDs(_ app: String?) -> [String: String] {
        guard let app else { return [:] }
        return ["ios": app, "android": app]
    }

    private func runDryRun(_ items: [ScenarioRunItem], project: TestProject) async -> Int {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var failedCount = 0
        for item in items {
            let platform = item.info.platform ?? driverOptions.platform
            // quiet: runSequential と同じ扱い(成功なら結果1行・失敗ならバッファ全体)
            var buffer: [String] = []
            let passed = await ScenarioHost.run(
                project: project, scenarioID: item.info.id,
                connection: DriverConnection(platform: platform),
                // **`enabled: false`(= 子へ --no-fm)**。heal だけ切ると失敗のたびに triage が
                // 走り、デバイスも画面も無いのに FM の直列化待ちを払う(数秒。実測で確認)
                fm: FMConfig(enabled: false, heal: false), reportDir: tempDir.path,
                dryRun: true, appBundleID: app) { event in
                let lines = ScenarioLogFormatter.lines(for: event)
                    .filter { !$0.contains("→ report:") }
                if quiet {
                    buffer.append(contentsOf: lines)
                } else {
                    for line in lines { print(line) }
                }
            }
            if quiet {
                print(passed ? "✅ \(item.info.id)" : "❌ \(item.info.id)")
                if !passed { print(buffer.joined(separator: "\n")) }
            }
            if !passed { failedCount += 1 }
        }
        return failedCount
    }

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
                project: project, item: item, worker: worker, fm: FMConfig(heal: heal && !noHeal),
                reportDir: URL(fileURLWithPath: reportDir), recorder: recorder,
                appBundleID: app) { event in
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
                                           fm: FMConfig(heal: heal && !noHeal),
                                           reportDir: URL(fileURLWithPath: reportDir),
                                           recorder: recorder,
                                           appBundleIDs: Self.appBundleIDs(app))
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

