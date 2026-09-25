// BridgeCommand.swift
// fleetest bridge: XCUITest ブリッジ(ランナー)の起動・停止・状態確認

import ArgumentParser
import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import FTDSL

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

        @Flag(help: "Also build and install SampleApp (iOS only)")
        var withSampleApp = false

        @Flag(help: "Treat --device as the UDID of a physical iOS device (the Identifier from xcrun devicectl list devices)")
        var physical = false

        @OptionGroup var driverOptions: DriverOptions

        func validate() throws {
            try driverOptions.rejectVersionSkewFlag(in: "bridge up")
            if driverOptions.resolvedPlatform != "android" {
                try Self.validatePort(driverOptions.port, in: BridgeDiscovery.portRange)
            }
        }

        /// `--port` はブリッジの走査範囲(BridgeDiscovery.portRange。run/MCP が見にいく範囲)の外だと
        /// 起動自体は成功しても誰からも見つからない孤立ブリッジになる(実測 2026-09-17)。
        /// 省略時の既定 8123 は範囲内なのでここでは明示指定だけを見る
        static func validatePort(_ port: UInt16?, in range: ClosedRange<UInt16>) throws {
            guard let port, !range.contains(port) else { return }
            throw ValidationError("--port \(port) is outside the range the bridge scanner covers "
                + "(\(range.lowerBound)-\(range.upperBound)); fleetest run/MCP would never find it there. "
                + "Pick a port inside that range")
        }

        /// --device は UDID・シミュレータ名のどちらでも受けるが、実体は常に UDID に解決してから使う ——
        /// xcodebuild の `-destination platform=iOS Simulator,name=<名前>` は名前に丸括弧等が入ると
        /// 一致に失敗することがある(実測 2026-09-17: simctl 上に1台しか無い名前でも build-for-testing が
        /// 「Unable to find a device matching the provided destination specifier」で落ちた)。UDID 指定なら
        /// 綴りに関わらず通る。同名複数・0台は推測で1台を選ばず、SimulatorCatalog.resolve の判定に断らせる
        static func resolveDeviceUDID(device: String, physical: Bool,
                                      devices: () throws -> [SimDeviceInfo]) throws -> String {
            let isUDID = physical || (device.count == 36 && device.split(separator: "-").count == 5)
            guard !isUDID else { return device }
            do {
                return try SimulatorCatalog.resolve(
                    spec: DeviceSpec(name: device, engine: "xcuitest"), in: try devices()).udid
            } catch {
                throw ValidationError((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }

        /// M11: 要求ポートと違うポートで起動したときの理由。provision() の戻り値自体は
        /// 再利用/新規起動を教えないため、**provision() を呼ぶ前にこの台が既に使っていたポート**
        /// (`preexistingPorts`)にあるかどうかだけで判定する
        enum PortMismatchReason: Equatable {
            /// この台には呼び出し前から稼働中のブリッジがあり、それを再利用した
            case reusedExistingBridge
            /// この台には呼び出し前は無く、要求ポートが別ブリッジに塞がれていたので別ポートで新規起動した
            case startedOnAnotherPort
            /// この台の旧ビルドのブリッジが居たポートで、それを止めて建て直した(再利用ではない)
            case restartedOlderBuild
        }

        /// stalePorts: 呼び出し前に**旧版**を名乗っていた preexistingPorts(provision は旧版を再利用せず、
        /// 止めて同じポートで建て直す。ポートが呼び出し前から在っただけで「再利用」と言うと事実と違う)
        static func portMismatchReason(actualPort: UInt16, preexistingPorts: Set<UInt16>,
                                       stalePorts: Set<UInt16>) -> PortMismatchReason {
            guard preexistingPorts.contains(actualPort) else { return .startedOnAnotherPort }
            return stalePorts.contains(actualPort) ? .restartedOlderBuild : .reusedExistingBridge
        }

        /// **「stop it and run again」の案内は再利用のときだけ出す** —— 新規起動のケースでは
        /// 案内どおりに今のポートを止めても要求ポートは空かない(塞いでいるのは別のブリッジ)
        /// requestedPortHeldByOther: 要求ポートを**別の台の**ブリッジ(台帳 .pid/.inapp・実機の iproxy)が
        /// 握っているか。握られていれば再利用でも止める案内は出さない —— 今のポートを止めても
        /// 要求ポートは空かない(実測 2026-09-18: 既定 8123 が USB 実機のトンネルだった)
        static func portMismatchMessage(actualPort: UInt16, requestedPort: UInt16,
                                        reason: PortMismatchReason,
                                        requestedPortHeldByOther: Bool) -> String {
            switch reason {
            case .reusedExistingBridge where requestedPortHeldByOther:
                return "⚠️ Reused the running bridge on this device (port \(actualPort)); the "
                    + "requested/default port \(requestedPort) is in use by another bridge."
            case .reusedExistingBridge:
                return "⚠️ Reused the running bridge on this device (port \(actualPort)) instead of the "
                    + "requested/default port \(requestedPort). To rebuild on port \(requestedPort), stop it "
                    + "first with `fleetest bridge down --port \(actualPort)` and run again."
            case .restartedOlderBuild:
                return "⚠️ Stopped this device's bridge from an older build on port \(actualPort) and restarted it there"
                    + " (the requested/default port \(requestedPort) is in use by another bridge)."
            case .startedOnAnotherPort:
                // 塞いでいるのは別の台(実機の LAN ブリッジ等)のことがあるので、止める案内は出さない
                return "⚠️ Started the bridge on port \(actualPort) because port \(requestedPort) is in use "
                    + "by another bridge. Pass --port with a free port to choose it explicitly."
            }
        }

        func run() async throws {
            if driverOptions.resolvedPlatform == "android" {
                // serial 省略時は接続中の全デバイス(8台並列前のプリウォーム用)
                for serial in try AndroidBridgeCLI.serials(only: driverOptions.serial) {
                    let driver = try AndroidDriver(serial: serial)
                    ConsoleOut.out("→ Starting the Android bridge: \(serial)")
                    try await driver.resetAndEnsureBridge()
                    ConsoleOut.out("✅ \(serial): \(driver.bridgeDoctorSummary())")
                }
                return
            }
            let root = try RepoRoot.find()
            let resolvedUDID = try Self.resolveDeviceUDID(device: device, physical: physical,
                                                          devices: SimulatorCatalog.devices)
            let launcher = BridgeLauncher(repoRoot: root, device: resolvedUDID, port: driverOptions.resolvedPort,
                                          physical: physical)

            if withSampleApp {
                // installSampleApp() builds against the generated Xcode project, a path provision()
                // below never touches — generate it here rather than unconditionally up front.
                ConsoleOut.out("→ Generating the project (xcodegen)...")
                try launcher.generateProjectIfNeeded()
                ConsoleOut.out("→ Building and installing SampleApp...")
                try launcher.installSampleApp()
            }
            // M11 の判定材料: provision() を呼ぶ前に、この台が既に使っているポートを控えておく
            // (呼んだ後では「元から有ったのか、今建てたのか」が区別できない)
            let preexistingPorts = Set(BridgeLauncher.portsMatching(udid: resolvedUDID, repoRoot: root))
            // 旧版を名乗るもの(provision が止めて建て直す)。応答しないものは判定材料が無いので含めない
            let stalePorts = Set(preexistingPorts.filter { port in
                BridgeLauncher.probeForeignBridge(port: port, timeout: 0.4)
                    .map { $0.protocolVersion != BridgeAPI.bridgeProtocolVersion } ?? false
            })
            // 起動は provision() 経由(直接 startDetached しない)。同一シミュレータに XCUITest
            // ランナーは1本しか同居できず(全ポート共通 bundle id のため2本目が先代を蹴り出し双方
            // signal kill で死ぬ)、直接起動は同一デバイスへの二重起動を防げない。provision() は
            // 稼働中ブリッジのスキャン→版一致なら再利用/旧版なら停止して起動し直すをまとめて行う
            // (モニター保持中でも拒否せず再利用・起動する=テスト/操作優先)。
            // xcodegen/build-for-testing も provision()(prepareSharedBuilds)に委ねる ——
            // 稼働中ブリッジの再利用ではどちらも撃たない(重複ビルドの排除。旧 CLI は無条件で撃っていた)。
            let spec = DeviceSpec(
                name: device,
                kind: physical ? .physical : nil,
                udid: resolvedUDID,
                port: driverOptions.resolvedPort,
                engine: "xcuitest")
            let provisioned = try await BridgeProvisioner(repoRoot: root)
                .provision(devices: [(spec.name, spec)], log: { ConsoleOut.out($0) })
            // provision() は失敗時に throw する(空配列で正常復帰はしない)ため、first は常に存在する
            let port = provisioned.first?.port ?? driverOptions.resolvedPort
            // provision は同一デバイスの稼働中ブリッジを preferred(--port)を無視して再利用する。
            // 固定ポート前提のスクリプトが :driverOptions.resolvedPort を叩いて外さないよう、差異を明示する
            if port != driverOptions.resolvedPort {
                let reason = Self.portMismatchReason(actualPort: port, preexistingPorts: preexistingPorts,
                                                     stalePorts: stalePorts)
                let requested = driverOptions.resolvedPort
                let stateDir = root.appendingPathComponent(".fleetest")
                let heldByOther = !preexistingPorts.contains(requested) && (
                    FileManager.default.fileExists(
                        atPath: stateDir.appendingPathComponent("bridge-\(requested).pid").path)
                    || FileManager.default.fileExists(
                        atPath: InAppBridgeState.url(stateDir: stateDir, port: requested).path)
                    || IOSDeviceTransport.isPortHeldByIproxy(hostPort: requested, repoRoot: root))
                ConsoleOut.out(Self.portMismatchMessage(
                    actualPort: port, requestedPort: requested, reason: reason,
                    requestedPortHeldByOther: heldByOther))
            }
            let host = provisioned.first?.host ?? BridgeEndpoint.loopbackHost
            ConsoleOut.out("✅ Bridge ready: http://\(host):\(port)")
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

        @Flag(help: "Stop the bridge even if a run or an MCP session is currently using its device")
        var force = false

        func run() async throws {
            if platform == "android" {
                let serials = try AndroidBridgeCLI.serials(only: serial)
                // **止める前に全台ぶん見る** —— 途中で断ると、断られる前の台だけ止まった
                // 半端な状態になる(鍵は serial。run-lease / MCP の印と同じ鍵)
                let androidLeaseDir = (try? RepoRoot.find())?.appendingPathComponent(".fleetest")
                if let refusal = serials.compactMap({ serial in
                    DeviceBooter.deviceInUseRefusal(
                        deviceName: serial, keys: [serial], force: force,
                        leaseStateDir: androidLeaseDir)
                }).first {
                    ConsoleOut.out("❌ \(refusal)")
                    throw ExitCode(1)
                }
                for serial in serials {
                    try AndroidDriver(serial: serial).stopBridge()
                    ConsoleOut.out("✅ Stopped the Android bridge: \(serial)")
                }
                return
            }
            let root = try RepoRoot.find()
            let leaseStateDir = root.appendingPathComponent(".fleetest")
            let selfPID = ProcessInfo.processInfo.processIdentifier
            // 保持者の判定は BridgeLauncher.stop()/stopAll() 側(供給・古いブリッジの掃除からも
            // 呼ばれる)には足さず、利用者が打つこの CLI の口だけに置く
            if all {
                let found = await BridgeDiscovery.scan(excluding: 0, repoRoot: root)
                // **応答しなかったポートは「死んでいる」とは限らない** —— 駆動中の XCUITest は
                // /status を返さないので、走査に載らないまま止めると run / MCP を無言で壊す
                // (実地 2026-09-22)。待受しているものだけ断る(待受も無ければ通す = 回復手段を残す)
                let silentPorts = BridgeDiscovery.portRange.filter { candidate in
                    !found.contains(where: { $0.port == candidate })
                }
                // **busy と「固まった転送」を分ける**ので isBound では足りない(§44.1 の4値)
                let silentProbes = await BridgeDiscovery.probeStatuses(ports: silentPorts, repoRoot: root)
                // 応答しないポートも listener からデバイスが特定できれば掃討の対象に含める。
                // 特定できないポートは従来どおり対象外(= 掃討ごと断る理由にしない。固まったブリッジを
                // 止める手段を奪わない)
                let silentTargets: [(name: String, keys: [String])] = silentPorts.compactMap { candidate in
                    PortHolder.deviceUDID(fromListenerOn: candidate).map {
                        (name: "device on port \(candidate) (udid \($0))", keys: [$0])
                    }
                }
                let targets = found.map { (name: $0.device, keys: $0.udid.map { [$0] } ?? []) } + silentTargets
                if let refusal = BridgeDownRefusal.decide(
                    targets: targets, force: force,
                    runHolderPID: { RunLease.holderPID(stateDir: leaseStateDir, key: $0) },
                    mcpHolderPID: { MCPDeviceLease.holderPID(
                        stateDir: leaseStateDir, key: $0, excluding: [selfPID, getppid()]) },
                    selfPID: selfPID) {
                    ConsoleOut.out("❌ \(refusal)")
                    throw ExitCode(1)
                }
                if let refusal = BridgeDownRefusal.unresponsiveButBoundRefusal(
                    ports: silentPorts, force: force,
                    probe: { silentProbes[$0] ?? .notBound }) {
                    ConsoleOut.out("❌ \(refusal)")
                    throw ExitCode(1)
                }
                let stopped = BridgeLauncher.stopAll(repoRoot: root, skipPhysical: false)
                ConsoleOut.out(stopped.isEmpty
                      ? "No bridges are running"
                      : "✅ Stopped bridges (port: \(stopped.joined(separator: ", ")))")
            } else {
                let found = await BridgeDiscovery.scan(excluding: 0, repoRoot: root)
                if let target = found.first(where: { $0.port == port }) {
                    if let refusal = DeviceBooter.deviceInUseRefusal(
                        deviceName: target.device, keys: target.udid.map { [$0] } ?? [],
                        force: force, leaseStateDir: leaseStateDir) {
                        ConsoleOut.out("❌ \(refusal)")
                        throw ExitCode(1)
                    }
                // **走査に載らなかったポートを「引けないから通す」に倒さない** —— 応答が無いのは
                // 死んでいるときだけでなく**駆動中で忙しい**ときも起きる(XCUITest は操作中 /status を
                // 返さない)。鍵(udid)が引けないので lease も照合できず、そのまま止めると走っている
                // run / MCP セッションを無言で壊す(実地 2026-09-22)。待受しているなら断り、
                // 待受も無ければ従来どおり通す(固まったブリッジを止める手段を奪わない)
                } else {
                    let probe = await BridgeDiscovery.probeStatus(port: port, repoRoot: root)
                    if let refusal = BridgeDownRefusal.unresponsiveButBoundRefusal(
                        ports: [port], force: force, probe: { _ in probe }) {
                        ConsoleOut.out("❌ \(refusal)")
                        throw ExitCode(1)
                    }
                    // **鍵(udid)が listener から読めるなら、なお lease を照合する** ——
                    // busy 判定を通っても、listener の実体からデバイスが特定できる形(シミュレータの
                    // xcodebuild ランナー等)は run/MCP が握ったままのことがある。
                    // 識別子が読めない形は従来どおり通す(固まったブリッジを止める手段を奪わない)
                    if let udid = PortHolder.deviceUDID(fromListenerOn: port),
                       let refusal = DeviceBooter.deviceInUseRefusal(
                            deviceName: "the device on port \(port) (udid \(udid))",
                            keys: [udid], force: force, leaseStateDir: leaseStateDir) {
                        ConsoleOut.out("❌ \(refusal)")
                        throw ExitCode(1)
                    }
                }
                // physical は stop() が見ない(kind を知らない経路からも止められるよう、
                // stop() 側が条件分岐しない宣言をしている)ので false でよい
                let launcher = BridgeLauncher(repoRoot: root, port: port, physical: false)
                try launcher.stop()
                ConsoleOut.out("✅ Stopped the bridge (port: \(port))")
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the bridge status")

        @OptionGroup var driverOptions: DriverOptions

        func validate() throws { try driverOptions.rejectVersionSkewFlag(in: "bridge status") }

        func run() async throws {
            if driverOptions.resolvedPlatform == "android" {
                for serial in try AndroidBridgeCLI.serials(only: driverOptions.serial) {
                    let driver = try AndroidDriver(serial: serial)
                    ConsoleOut.out("\(serial): \(driver.bridgeDoctorSummary())")
                }
                return
            }
            // **1本だけ見て「何も無い」と言わない**(2026-09-04 の実害): 既定ポートへ問い合わせて
            // 落ちるだけの実装では、**8本動いている状態で**「nothing listening / アプリが
            // 落ちたのだろう」と報告していた(既定の 8123 が空いていただけ)。Android 側は
            // 元から接続中の全 serial を列挙しており、非対称でもあった。**動いているものを全部出す**
            let found = await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
            ConsoleOut.out(BridgeStatusReport.render(found, requested: driverOptions.resolvedPort))
        }
    }
}

/// `fleetest bridge status`(iOS)の表示。**純関数にしてあるのはテストのため** ——
/// 走査そのものはブリッジが要るのでテストから通せない
enum BridgeStatusReport {
    static func render(_ found: [BridgeDiscovery.Found], requested: UInt16) -> String {
        guard !found.isEmpty else {
            return "no bridge is running on this machine"
                + " (ports \(BridgeDiscovery.scannedPortsDescription) were scanned)."
                + " Start one with: fleetest bridge up"
        }
        // **要求されたポートに印を付ける**(--port を渡した人が自分の1本を見失わないため)
        return found.sorted { $0.port < $1.port }.map { entry in
            let mark = entry.port == requested ? "→ " : "  "
            let udid = entry.udid.map { " udid \($0)" } ?? ""
            return "\(mark)port \(entry.port): \(entry.device) (\(entry.engine))\(udid)"
        }.joined(separator: "\n")
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
