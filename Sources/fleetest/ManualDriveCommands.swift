// ManualDriveCommands.swift
// 手動駆動コマンド(install/launch/snapshot/tap/type/swipe/press/screenshot/terminate)

import ArgumentParser
import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import FTDSL

// MARK: - 手動駆動コマンド

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install an app from a package file (iOS: .app bundle / Android: .apk or .apks)")

    @Argument(help: "Path to the package file (iOS: .app bundle / Android: .apk, or .apks via bundletool)")
    var packagePath: String

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        guard FileManager.default.fileExists(atPath: packagePath) else {
            throw ValidationError("package file not found: \(packagePath)")
        }
        try await driverOptions.makeDriver().install(packagePath: packagePath)
        ConsoleOut.out("✅ Installed: \(packagePath)")
    }
}

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Launch the app under test")

    @Argument(help: "App bundle identifier (e.g. com.example.sampleapp)")
    var bundleID: String

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        let driver = try await driverOptions.makeDriver()
        try await Self.refuseIfNotInstalled(bundleID: bundleID, driver: driver,
                                            isAndroid: driverOptions.resolvedPlatform == "android")
        try await driver.launch(bundleID: bundleID)
        ConsoleOut.out("✅ Launched: \(bundleID)")
    }

    /// 撃つ前の門(判定は `InstalledAppCheck.launchGuard` の1箇所。MCP の ft_launch・ライブ操作と共有)。
    /// 未インストールのまま `XCUIApplication.launch()` を撃つと XCUITest ランナーが約60秒ハングして
    /// 自壊する。照会先の udid はブリッジの `/status` から取る —— `/status` が読めない(ブリッジに
    /// 届かない)ときは門を通さず、到達できないことを `launch` 自身に言わせる(落とすランナーが無い)
    static func refuseIfNotInstalled(bundleID: String, driver: AppDriver, isAndroid: Bool) async throws {
        var engine: String?
        let verdict: InstalledAppCheck.InstallVerdict
        if isAndroid {
            verdict = LaunchInstallVerdict.read(bundleID: bundleID, driver: driver, isAndroid: true, udid: nil)
        } else {
            guard let status = try? await driver.status() else { return }
            engine = status.engine
            // 実機の /status は udid を返さない —— ポートの台帳から作った driver の udid で補う
            verdict = LaunchInstallVerdict.read(bundleID: bundleID, driver: driver, isAndroid: false,
                                                udid: status.udid ?? (driver as? BridgeClient)?.physicalUDID)
        }
        switch InstalledAppCheck.launchGuard(
            verdict: verdict, isAndroid: isAndroid, engine: engine, bundleID: bundleID) {
        case .allow:
            return
        case .refuse(.notInstalled):
            throw LaunchRefused(message: "\(bundleID) is not installed on this device."
                + " Install it first with `fleetest install <.app or .apk>`, or check the bundle ID"
                + " (Android: the package name)")
        case .refuse(.unknown(let reason)):
            throw LaunchRefused(message: "could not verify whether \(bundleID) is installed (\(reason))."
                + " Launching a missing app can hang the XCUITest bridge and force it to self-terminate"
                + " — retry once the device is less busy, install it first, or double-check the bundle ID")
        }
    }

    struct LaunchRefused: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the accessibility tree of the current screen (compressed)")

    @Flag(help: "Print the raw JSON")
    var json = false

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        let snapshot = try await driverOptions.makeDriver().snapshot()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            ConsoleOut.out(String(data: try encoder.encode(snapshot), encoding: .utf8)!)
        } else {
            ConsoleOut.out(SnapshotRenderer.render(snapshot))
        }
    }
}

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tap an element or a coordinate")

    @Option(help: "Reference number from snapshot")
    var ref: Int?

    @Option(help: "X coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var x: Double?

    @Option(help: "Y coordinate — iOS=pt / Android=px (same coordinate system as the snapshot frames)")
    var y: Double?

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        if let ref {
            try await driverOptions.makeDriver().tap(ref: ref)
            ConsoleOut.out("✅ tap [\(ref)]")
        } else if let x, let y {
            try await driverOptions.makeDriver().tap(x: x, y: y)
            ConsoleOut.out("✅ tap (\(x), \(y))")
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

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        try await driverOptions.makeDriver().type(ref: ref, text: text)
        ConsoleOut.out("✅ type \"\(text)\"")
    }
}

struct Swipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Swipe")

    @Argument(help: "Direction: up / down / left / right")
    var direction: String

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        guard let dir = FTSwipeDirection(rawValue: direction) else {
            throw ValidationError("direction must be one of up / down / left / right")
        }
        try await driverOptions.makeDriver().swipe(dir)
        ConsoleOut.out("✅ swipe \(direction)")
    }
}

struct Press: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Long-press an element")

    @Option(help: "Reference number")
    var ref: Int

    @Option(help: "Press duration in seconds")
    var holdSeconds: Double = 1.0

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        try await driverOptions.makeDriver().press(ref: ref, duration: holdSeconds)
        ConsoleOut.out("✅ press [\(ref)] \(holdSeconds)s")
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a screenshot")

    @Option(name: .shortAndLong, help: "Output PNG path")
    var output: String = "screenshot.png"

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        let data = try await driverOptions.makeDriver().screenshot()
        try data.write(to: URL(fileURLWithPath: output))
        ConsoleOut.out("✅ Saved: \(output) (\(data.count) bytes)")
    }
}

struct Terminate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Terminate the app under test")

    @OptionGroup var driverOptions: DriverOptions

    func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }

    func run() async throws {
        try await driverOptions.makeDriver().terminate()
        ConsoleOut.out("✅ Terminated")
    }
}
