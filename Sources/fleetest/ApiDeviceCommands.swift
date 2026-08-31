// VSCode拡張のライブ操作パネル向け: マシンプロファイル記載のデバイス1台の起動・停止
// (fleetest api device-up / device-down)。起動・停止の実装(DeviceBooter/BridgeProvisioner)は
// DevicesCommand(fleetest devices)と共通。stdout には NDJSON(log* → finished)だけを出す
// (診断は stderr のみ。ok:false のときは exit code 1)。
//
// device-down は --udid/--serial の直指定モードも持つ(未登録=マシンプロファイル未記載の起動中
// デバイス向け。ApiMonitorCommand.unregisteredStates 参照)。プロジェクト・マシンプロファイル解決を
// 一切行わない(ApiDeviceDownDirectTarget/ApiDeviceDownDirectSpec)。対向: vscode-fleetest/src/monitorDeviceOps.ts

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiDeviceUp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-up",
        abstract: "Start one device listed in the machine profile (NDJSON: log* -> finished on "
            + "stdout; diagnostics on stderr only; exit code 1 when ok:false)")

    @Option(help: "Logical device name (a name under ios or android in the machine profile)")
    var name: String?

    @Option(help: "Hardware UDID of a connected physical iOS device that is not in the machine profile (starts its bridge; mutually exclusive with --name)")
    var udid: String?

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name, used to resolve the machine. When given, that profile's machine wins; otherwise FT_MACHINE, the registered machine, or the only entry in machines/")
    var profile: String?

    @Option(help: "Android GPU rendering mode (host / swiftshader_indirect; default host). Used as the CPU-rendering fallback for devices that freeze")
    var gpu: String?

    @Option(name: [.customLong("device-machine"), .customLong("device-host")],
            help: "Only match devices assigned to this machine (\"local\" or a registered host name). Set by the caller on the other end of ssh")
    var deviceMachine: String?

    func run() async throws {
        let resolvedGpu: String
        switch gpu {
        case nil:
            resolvedGpu = "host"
        case "host"?, "swiftshader_indirect"?:
            resolvedGpu = gpu!
        default:
            FileHandle.standardError.write(Data("⚠️ Unknown --gpu value — falling back to host: \(gpu!)\n".utf8))
            resolvedGpu = "host"
        }
        // 直指定モード(--udid): マシンプロファイル未記載の**接続中の実機**のブリッジを起こす。
        // 実機は端末そのものを起動・停止しないので boot は無く、供給だけが仕事
        // (対向: vscode-fleetest/src/webview/monitor/deviceTiles.js の「ブリッジを起動」)
        guard let name else {
            guard let udid else {
                throw ValidationError("specify exactly one of --name / --udid")
            }
            try await Self.startPhysicalBridge(udid: udid)
            return
        }
        guard udid == nil else {
            throw ValidationError("specify exactly one of --name / --udid")
        }
        try await ApiDeviceOperation.run(
            name: name, project: project, profile: profile, deviceMachine: deviceMachine
        ) { spec, platform, log in
            try await DeviceBooter.bootOne(spec: spec, platform: platform, gpuMode: resolvedGpu, log: log)
            // iOS はブリッジも供給する(稼働中ブリッジがあれば再利用。供給しないと画面が取れず
            // 「起動済み(ブリッジ未接続)」のままになる)
            if platform == "ios" {
                let root = try RepoRoot.find()
                _ = try await BridgeProvisioner(repoRoot: root)
                    .provision(devices: [(spec.name, spec)], log: log)
            }
        }
    }

    /// `--udid` 直指定の1台。プロジェクト・マシンプロファイル解決を経ないため
    /// `ApiDeviceOperation.run` を通らず、NDJSON の log*/finished をここで組み立てる
    /// (device-down の runDirect と同じ形)
    private static func startPhysicalBridge(udid: String) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let log: @Sendable (String) -> Void = { message in
            ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(message: message))
        }
        do {
            let devices = try IOSPhysicalDeviceCatalog.devices()
            let spec = try ApiDeviceUpDirectSpec.physicalIOSSpec(udid: udid, devices: devices)
            let root = try RepoRoot.find()
            _ = try await BridgeProvisioner(repoRoot: root)
                .provision(devices: [(spec.name, spec)], log: log)
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: true, error: nil))
        } catch {
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent.failure(error))
            throw ExitCode(1)
        }
    }
}

/// `device-up --udid` の spec 合成。**接続中の実機だけ**を受ける —— 繋がっていない端末で
/// ブリッジを起こそうとすると xcodebuild が数分かけて失敗するので、その手前で落とす。
/// engine は xcuitest 固定(`fleetest bridge up --physical` と同じ。実機に in-app 注入は無い)。
/// I/O を持たない pure 関数(ユニットテスト対象のため private にしない)
enum ApiDeviceUpDirectSpec {
    static func physicalIOSSpec(udid: String, devices: [IOSPhysicalDeviceInfo]) throws -> DeviceSpec {
        guard let device = devices.first(where: { $0.udid == udid || $0.deviceCtlIdentifier == udid }) else {
            throw IOSPhysicalDeviceCatalogError.notFound(udid: udid, available: devices)
        }
        guard device.connected else {
            throw IOSPhysicalDeviceCatalogError.notConnected(udid: device.udid, name: device.name)
        }
        return DeviceSpec(name: device.name, kind: .physical, os: device.os, udid: device.udid,
                          engine: "xcuitest")
    }
}

/// 仮想デバイス1台の Wipe Data(Android = AVD の userdata/cache/snapshots 削除、
/// iOS = simctl erase)。**識別子の直指定だけ**を受け、`api delete-device` と同じく
/// プロジェクト・マシンプロファイルを一切参照しない —— 消す対象はその AVD ディレクトリ /
/// シミュレータ UDID そのものなので、名前で引く必要が無い。名前で引く形にすると
/// **リモートでは向こうの複製が古いと `device not found` で必ず失敗する**
/// (複製が更新されるのはモニターの fan-out 開始時だけ)ため、操作のたびにプロジェクトを
/// 送り直す羽目になる —— 200 バイトの情報のために毎回 rsync を1本払う形は採らない。
/// **実機は識別子から作る spec が virtual なので原理的に来ない**が、DeviceWiper.target が
/// 別の呼び手のために拒否を持ち続ける。
/// stdout の NDJSON は device-up/down と同じ log*/finished に、フェーズ通知
/// {"kind":"wipeStatus","phase":"stopping"|"rebooting"|"done"|"failed"} を加えた形
/// (同期相手: vscode-fleetest/src/monitorDeviceLifecycle.ts の DeviceOpEvent)
struct ApiDeviceWipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-wipe",
        abstract: "Wipe one virtual device by identifier (Android: Wipe Data on --avd; iOS: simctl "
            + "erase on --udid). Resolves no project or machine profile at all, like delete-device. "
            + "NDJSON: log*/wipeStatus* -> finished on stdout; diagnostics on stderr only; exit "
            + "code 1 when ok:false")

    @Option(help: "Device platform (ios or android)")
    var platform: String

    @Option(help: "iOS simulator UDID (required with --platform ios)")
    var udid: String?

    @Option(help: "Android AVD id (required with --platform android)")
    var avd: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let log: @Sendable (String) -> Void = { message in
            ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(message: message))
        }
        do {
            let target = try ApiDeviceWipeTarget.resolve(platform: platform, udid: udid, avd: avd)
            let spec = target.spec(simCatalog: target.platform == "ios"
                                   ? ((try? SimulatorCatalog.devices()) ?? []) : [])
            // iOS はブリッジの停止・再供給に repoRoot が要る(device-down / device-up と同じ)
            let repoRoot = target.platform == "ios" ? try? RepoRoot.find() : nil
            try await DeviceWiper.wipeOne(
                spec: spec, platform: target.platform, repoRoot: repoRoot,
                status: { phase in
                    ApiDeviceEventEmitter.emit(ApiDeviceWipeStatusEvent(phase: phase))
                },
                log: log)
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: true, error: nil))
        } catch let error as ValidationError {
            throw error  // 引数の誤りは NDJSON でなく ArgumentParser の作法で返す(exit 64)
        } catch {
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent.failure(error))
            throw ExitCode(1)
        }
    }
}

/// `device-wipe` の引数から対象を決め、spec を組み立てる。I/O を持たない pure 関数
/// (ユニットテスト対象のため private にしない。ApiDeviceDownDirectSpec と同じ位置づけ)
enum ApiDeviceWipeTarget: Equatable {
    case ios(udid: String)
    case android(avd: String)

    var platform: String {
        switch self {
        case .ios: return "ios"
        case .android: return "android"
        }
    }

    /// platform に対応する識別子がちょうど1つ与えられているか検証する
    static func resolve(platform: String, udid: String?, avd: String?) throws -> ApiDeviceWipeTarget {
        switch platform {
        case "ios":
            guard avd == nil else { throw ValidationError("--avd is for --platform android") }
            guard let udid, !udid.isEmpty else { throw ValidationError("--platform ios needs --udid") }
            return .ios(udid: udid)
        case "android":
            guard udid == nil else { throw ValidationError("--udid is for --platform ios") }
            guard let avd, !avd.isEmpty else { throw ValidationError("--platform android needs --avd") }
            return .android(avd: avd)
        default:
            throw ValidationError("unknown --platform: \(platform) (expected ios or android)")
        }
    }

    /// 表示名は**人が読む1行のためだけ**に使う(操作の宛先は識別子)。iOS はカタログに載って
    /// いればシミュレータ名、無ければ UDID をそのまま出す(ApiDeviceDownDirectSpec.iosSpec と同じ方針)
    func spec(simCatalog: [SimDeviceInfo]) -> DeviceSpec {
        switch self {
        case .ios(let udid):
            let name = simCatalog.first(where: { $0.udid == udid })?.name ?? udid
            return DeviceSpec(name: name, kind: .virtual, udid: udid)
        case .android(let avd):
            return DeviceSpec(name: avd, kind: .virtual, avd: avd)
        }
    }
}

struct ApiDevicesUp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices-up",
        abstract: "Start every device in the machine profile (NDJSON: log/deviceStarting/deviceFinished -> "
            + "finished on stdout; diagnostics on stderr only)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (when given, only the devices that profile references are started)")
    var profile: String?

    @Flag(name: .customLong("no-bridge"), help: "Do not provision the iOS bridge")
    var noBridge = false

    @Option(name: .customLong("cpu-render"), parsing: .upToNextOption,
            help: "Logical names of devices to start with swiftshader_indirect (CPU rendering), keeping devices that are on the freeze fallback. Repeatable. Kept in sync with the watchdog per-device fallback: vscode-fleetest/src/monitorDeviceOps.ts")
    var cpuRender: [String] = []

    @Option(name: .customLong("restart"), parsing: .upToNextOption,
            help: "Logical names of devices to restart with down->up even if already running, to bring CPU-rendering devices back onto the GPU. Repeatable; processed two at a time in the same queue as booting stopped devices")
    var restart: [String] = []

    @Option(name: [.customLong("device-machine"), .customLong("device-host")], help: ArgumentHelp(
        "Operate on the devices that belong to this machine (registered host name)."
        + " Default: the devices with no host (this machine). Used when a parent dispatches"
        + " to a runner: remote exec <name> -- ... --device-machine <name>"))
    var deviceMachine: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile, deviceMachine: deviceMachine,
                foreign: .dispatchedByCaller,  // RemoteDeviceFanout がこの後その機械へ回す
                noteAutoMachine: { Self.logStderr($0) },
                warn: { Self.logStderr($0) })
            let repoRoot = noBridge ? nil : try RepoRoot.find()
            // **リモートのぶんはその機械へ投げる**(手元の起動と同時に走る。RemoteDeviceFanout)。
            // 起動は機械ごとに独立した資源を使うので、「同時2台」の上限は機械ごとに持てる
            let machines = RemoteDeviceFanout.remoteMachines(
                project: project, profile: profile, deviceMachine: deviceMachine)
            // **意図を変えるフラグは中継しないと黙って無視される**(FTRemote.RemoteDispatch.build と
            // 同じ規律)—— --no-bridge を渡さないと、向こうだけブリッジを供給する。
            // --restart / --cpu-render は手元の watchdog が持つ名簿なので中継しない
            async let fanout: Void = RemoteDeviceFanout.dispatch(
                subcommand: "devices-up", machines: machines, project: project, profile: profile,
                extraArgs: noBridge ? ["--no-bridge"] : [],
                relay: { ApiDeviceEventEmitter.emitRaw($0) })

            // deviceStopping/deviceStarting/deviceFinished は bootAll のワーカータスクから並行に
            // 呼ばれるため、emit(ApiDeviceEventEmitter 経由)でロックして直列化する
            await DeviceBooter.bootAll(
                machine: machineProfile, repoRoot: repoRoot,
                restartNames: Set(restart),
                cpuRenderNames: Set(cpuRender),
                log: { message in ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(message: message)) },
                deviceStopping: { name, platform in
                    ApiDeviceEventEmitter.emit(
                        ApiDevicesUpLifecycleEvent(kind: "deviceStopping", name: name, platform: platform,
                                                   machine: MachineDispatch.normalize(deviceMachine)))
                },
                deviceStarting: { name, platform in
                    ApiDeviceEventEmitter.emit(
                        ApiDevicesUpLifecycleEvent(kind: "deviceStarting", name: name, platform: platform,
                                                   machine: MachineDispatch.normalize(deviceMachine)))
                },
                deviceFinished: { name, platform in
                    ApiDeviceEventEmitter.emit(
                        ApiDevicesUpLifecycleEvent(kind: "deviceFinished", name: name, platform: platform,
                                                   machine: MachineDispatch.normalize(deviceMachine)))
                })
            await fanout  // リモート分の完走まで finished を出さない(受け手の「全部終わった」の合図)
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: true, error: nil))
        } catch {
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent.failure(error))
            throw ExitCode(1)
        }
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

struct ApiDevicesRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices-restart",
        abstract: "Restart the given devices with down->up, two at a time (NDJSON: "
            + "log/deviceStopping/deviceStarting/deviceFinished -> finished on stdout; "
            + "diagnostics on stderr only; exit code 1 when ok:false)")

    @Option(name: .customLong("name"), parsing: .upToNextOption,
            help: "Logical names of the devices to restart (under ios or android in the machine profile). Repeatable")
    var name: [String] = []

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (when given, only the devices that profile references are affected)")
    var profile: String?

    @Option(name: [.customLong("device-machine"), .customLong("device-host")], help: ArgumentHelp(
        "Operate on the devices that belong to this machine (registered host name)."
        + " Default: the devices with no host (this machine)"))
    var deviceMachine: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard !name.isEmpty else {
            throw ValidationError("specify at least one --name")
        }
        do {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile, deviceMachine: deviceMachine,
                foreign: .notHandled,  // devices-restart は分散しない(watchdog 由来で手元専用)
                noteAutoMachine: { Self.logStderr($0) },
                warn: { Self.logStderr($0) })

            var items: [RestartItem] = []
            for deviceName in name {
                // machineProfile は MachineProfileLoad.load が deviceMachine で絞った後なので、
                // ここに残っているのは「この機械の台」だけ(entries が host を焼き込んでいる)
                guard case .found(let spec, let platform) = ApiDeviceOperation.findDevice(
                    name: deviceName, deviceMachine: deviceMachine, in: machineProfile) else {
                    ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(
                        ok: false, error: "device not found: \(deviceName)"))
                    throw ExitCode(1)
                }
                if spec.isPhysical {
                    ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(
                        message: "✔ \(spec.name): physical device — restart leaves it alone"
                            + " (its bridge only starts/stops from a run or the tile menu)"))
                    continue
                }
                items.append(RestartItem(spec: spec, platform: platform))
            }

            let repoRoot = try? RepoRoot.find()
            let queue = RestartQueue(items)
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<min(2, items.count) {
                    group.addTask {
                        while let item = await queue.next() {
                            await Self.restartOne(item, repoRoot: repoRoot)
                        }
                    }
                }
            }
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: true, error: nil))
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent.failure(error))
            throw ExitCode(1)
        }
    }

    /// 1 台分の down→up。shutdownOne/bootOne いずれかが失敗しても deviceFinished は必ず送出する
    /// (呼び出し側 VSCode 拡張の再スキャン契約。ApiDevicesUp の deviceFinished 契約と同じ)
    private static func restartOne(_ item: RestartItem, repoRoot: URL?) async {
        let spec = item.spec
        let platform = item.platform
        let log: @Sendable (String) -> Void = { message in
            ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(message: message))
        }
        ApiDeviceEventEmitter.emit(
            ApiDevicesUpLifecycleEvent(kind: "deviceStopping", name: spec.name, platform: platform,
                                       machine: spec.machine))
        do {
            try await DeviceBooter.shutdownOne(
                spec: spec, platform: platform,
                repoRoot: platform == "ios" ? repoRoot : nil, log: log)
            ApiDeviceEventEmitter.emit(
                ApiDevicesUpLifecycleEvent(kind: "deviceStarting", name: spec.name, platform: platform,
                                           machine: spec.machine))
            try await DeviceBooter.bootOne(spec: spec, platform: platform, log: log)
        } catch {
            log("❌ \(spec.name): \(error.localizedDescription)")
        }
        ApiDeviceEventEmitter.emit(
            ApiDevicesUpLifecycleEvent(kind: "deviceFinished", name: spec.name, platform: platform,
                                       machine: spec.machine))
    }

    private struct RestartItem: Sendable {
        let spec: DeviceSpec
        let platform: String
    }

    private actor RestartQueue {
        private var items: [RestartItem]
        init(_ items: [RestartItem]) { self.items = items }
        func next() -> RestartItem? { items.isEmpty ? nil : items.removeFirst() }
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

struct ApiDevicesDown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices-down",
        abstract: "Stop every device in the machine profile (NDJSON: log/deviceStopping/deviceFinished -> "
            + "finished on stdout; diagnostics on stderr only; exit code 1 when ok:false). "
            + "With --profile, only the devices that profile references. The shutdown logic is identical "
            + "to shutdownProfile in DevicesCommand.Down (sequential ios->android shutdownOne) with "
            + "per-device progress added")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (when given, only the devices that profile references are stopped)")
    var profile: String?

    @Option(name: [.customLong("device-machine"), .customLong("device-host")], help: ArgumentHelp(
        "Operate on the devices that belong to this machine (registered host name)."
        + " Default: the devices with no host (this machine). Used when a parent dispatches"
        + " to a runner: remote exec <name> -- ... --device-machine <name>"))
    var deviceMachine: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile, deviceMachine: deviceMachine,
                foreign: .dispatchedByCaller,  // RemoteDeviceFanout がこの後その機械へ回す
                noteAutoMachine: { Self.logStderr($0) },
                warn: { Self.logStderr($0) })
            // リモートのぶんはその機械へ投げる(起動と同じ分散。RemoteDeviceFanout)
            let machines = RemoteDeviceFanout.remoteMachines(
                project: project, profile: profile, deviceMachine: deviceMachine)
            async let fanout: Void = RemoteDeviceFanout.dispatch(
                subcommand: "devices-down", machines: machines, project: project, profile: profile,
                relay: { ApiDeviceEventEmitter.emitRaw($0) })

            // shutdownProfile と同じ ios→android 逐次(1台落ちるごとに deviceFinished を出すので、
            // 拡張側は落ちた順にタイルを「未起動」へ倒せる)。iOS のみブリッジ停止のため repoRoot を渡す。
            let repoRoot = try? RepoRoot.find()
            for spec in machineProfile.ios?.devices ?? [] {
                if spec.isPhysical {
                    Self.logPhysicalSkip(spec: spec)
                    continue
                }
                await Self.shutdownOneEmitting(spec: spec, platform: "ios", repoRoot: repoRoot)
            }
            for spec in machineProfile.android?.devices ?? [] {
                if spec.isPhysical {
                    Self.logPhysicalSkip(spec: spec)
                    continue
                }
                await Self.shutdownOneEmitting(spec: spec, platform: "android", repoRoot: nil)
            }
            await fanout  // リモート分の完走まで finished を出さない(受け手の「全部終わった」の合図)
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: true, error: nil))
        } catch {
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent.failure(error))
            throw ExitCode(1)
        }
    }

    /// 実機はスキップし理由を1行だけ log イベントで報告する(deviceStopping/deviceFinished は
    /// 出さない —— 拡張のタイルは「その台を一括操作の対象にしていない」ことがそのまま伝わる
    /// べきで、シャットダウン中の表示に倒すべきではない)
    private static func logPhysicalSkip(spec: DeviceSpec) {
        ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(
            message: "✔ \(spec.name): physical device — bulk stop leaves it alone"
                + " (stop its bridge from the tile menu)"))
    }

    /// 1台停止。失敗しても deviceFinished は必ず送出する(拡張の再スキャン契約。
    /// ApiDevicesUp/Restart の deviceFinished 契約と同じ)。
    private static func shutdownOneEmitting(spec: DeviceSpec, platform: String, repoRoot: URL?) async {
        let log: @Sendable (String) -> Void = { message in
            ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(message: message))
        }
        ApiDeviceEventEmitter.emit(
            ApiDevicesUpLifecycleEvent(kind: "deviceStopping", name: spec.name, platform: platform,
                                       machine: spec.machine))
        do {
            try await DeviceBooter.shutdownOne(spec: spec, platform: platform, repoRoot: repoRoot, log: log)
        } catch {
            log("❌ \(spec.name): \(error.localizedDescription)")
        }
        ApiDeviceEventEmitter.emit(
            ApiDevicesUpLifecycleEvent(kind: "deviceFinished", name: spec.name, platform: platform,
                                       machine: spec.machine))
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

struct ApiDeviceDown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-down",
        abstract: "Stop one device listed in the machine profile (NDJSON: log* -> finished on "
            + "stdout; diagnostics on stderr only; exit code 1 when ok:false). Exactly one of "
            + "--name/--udid/--serial must be given; --udid/--serial stop a device directly "
            + "(no project/machine-profile resolution at all) for devices the monitor found "
            + "running but that are not listed in any machine profile (registered:false; see "
            + "ApiMonitorCommand.unregisteredStates)")

    @Option(help: "Logical device name (a name under ios or android in the machine profile)")
    var name: String?

    @Option(help: "iOS simulator UDID. Direct mode: stops this simulator without resolving a project or machine profile")
    var udid: String?

    @Option(help: "Android emulator adb serial. Direct mode: stops this emulator without resolving a project or machine profile")
    var serial: String?

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project). Ignored in direct (--udid/--serial) mode")
    var project: String?

    @Option(help: "Run profile name, used to resolve the machine. When given, that profile's machine wins; otherwise FT_MACHINE, the registered machine, or the only entry in machines/. Ignored in direct (--udid/--serial) mode")
    var profile: String?

    @Option(name: [.customLong("device-machine"), .customLong("device-host")],
            help: "Only match devices assigned to this machine (\"local\" or a registered host name). Set by the caller on the other end of ssh")
    var deviceMachine: String?

    func run() async throws {
        switch try ApiDeviceDownDirectTarget.resolve(name: name, udid: udid, serial: serial) {
        case .name(let name):
            try await ApiDeviceOperation.run(
                name: name, project: project, profile: profile, deviceMachine: deviceMachine
            ) { spec, platform, log in
                // iOS はシミュレータ停止前に稼働ブリッジも探して停止する(ゾンビ化防止。
                // BridgeProvisioner.provision の失敗時後始末と対)。repoRoot 未検出時は nil のまま
                // 渡しブリッジ停止をスキップして simctl shutdown のみ行う
                let repoRoot = platform == "ios" ? try? RepoRoot.find() : nil
                try await DeviceBooter.shutdownOne(
                    spec: spec, platform: platform, repoRoot: repoRoot, log: log)
            }
        case .udid(let udid):
            let simCatalog = (try? SimulatorCatalog.devices()) ?? []
            let spec = ApiDeviceDownDirectSpec.iosSpec(udid: udid, simCatalog: simCatalog)
            try await Self.runDirect(spec: spec, platform: "ios", repoRoot: try? RepoRoot.find())
        case .serial(let serial):
            let runningAVDs = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
            switch ApiDeviceDownDirectSpec.androidSpec(serial: serial, runningAVDs: runningAVDs) {
            case .success(let spec):
                try await Self.runDirect(spec: spec, platform: "android", repoRoot: nil)
            case .failure(let message):
                try Self.emitDirectFailure(message)
            }
        }
    }

    /// 直指定モード(--udid/--serial)の1台停止。プロジェクト・マシンプロファイル解決を経ないため
    /// ApiDeviceOperation.run を通らず、NDJSON の log*/finished 出力だけをここで組み立てる
    private static func runDirect(spec: DeviceSpec, platform: String, repoRoot: URL?) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let log: @Sendable (String) -> Void = { message in
            ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(message: message))
        }
        do {
            try await DeviceBooter.shutdownOne(spec: spec, platform: platform, repoRoot: repoRoot, log: log)
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: true, error: nil))
        } catch {
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent.failure(error))
            throw ExitCode(1)
        }
    }

    private static func emitDirectFailure(_ message: String) throws -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: false, error: message))
        throw ExitCode(1)
    }
}

/// --name/--udid/--serial のうちどれで device-down を実行するかの判定。I/O を持たない pure 関数
/// (ユニットテスト対象のため private にしない)
enum ApiDeviceDownDirectTarget: Equatable {
    case name(String)
    case udid(String)
    case serial(String)

    /// ちょうど1つが指定されているか検証する。0個/2個以上は ValidationError
    static func resolve(name: String?, udid: String?, serial: String?) throws -> ApiDeviceDownDirectTarget {
        let given = [name, udid, serial].compactMap { $0 }
        guard given.count == 1 else {
            throw ValidationError("specify exactly one of --name / --udid / --serial")
        }
        if let name { return .name(name) }
        if let udid { return .udid(udid) }
        return .serial(serial!)
    }
}

/// 直指定モードの spec 合成。マシンプロファイルに実在しない(未登録)デバイス向けのため、
/// カタログ照合のみで組み立てる。I/O を持たない pure 関数(ユニットテスト対象のため private にしない)
enum ApiDeviceDownDirectSpec {
    /// androidSpec の結果(Swift の Result は Failure: Error 制約があり String を使えない)
    enum SpecResult: Equatable {
        case success(DeviceSpec)
        case failure(String)
    }

    /// simCatalog に udid が一致すればシミュレータ名を表示名にする。一致しなければ udid をそのまま使う
    /// (未登録シミュレータが simctl 一覧から既に消えている場合の保険)
    static func iosSpec(udid: String, simCatalog: [SimDeviceInfo]) -> DeviceSpec {
        let name = simCatalog.first(where: { $0.udid == udid })?.name ?? udid
        return DeviceSpec(name: name, udid: udid)
    }

    /// runningAVDs(serial -> canonical AVD ID)から解決する。見つからなければ呼び出し側が
    /// emitFinished(ok:false) するためのメッセージを返す
    static func androidSpec(serial: String, runningAVDs: [String: String]) -> SpecResult {
        guard let avdID = runningAVDs[serial] else {
            return .failure("serial not found among running emulators: \(serial)")
        }
        return .success(DeviceSpec(name: avdID, avd: avdID))
    }
}

/// fleetest api device-up / device-down 共通の実行ロジック
/// (マシンプロファイル読み込み・--name 解決・NDJSON ストリーミング・エラー処理)
enum ApiDeviceOperation {
    static func run(
        name: String, project: String?, profile: String?, deviceMachine: String? = nil,
        body: @escaping @Sendable (
            DeviceSpec, String, @escaping @Sendable (String) -> Void
        ) async throws -> Void
    ) async throws {
        // finished 到達を読み手が確実に検知できるよう、log イベントもすぐ流す
        setvbuf(stdout, nil, _IOLBF, 0)

        let testProject = try ScenarioHost.project(named: project)
        // **台帳の決め方は実行プロファイルの有無で変わる**(監視 = ApiMonitorCommand と同じ規律):
        //   選んでいる: その machine の台帳(runProfileName を渡すと determineMachine が
        //     実行プロファイルの machine を最優先で解決する)
        //   選んでいない: **台帳を1つに決めない** —— machines/ を全部畳み、手元 +
        //     リモート実行の登録簿にあるマシンの台から探す(MachineInventory)
        //
        // 決められないという理由で操作を断らない —— **タイルに出ている台は操作できるべき**。
        // 台帳が2つある案件では「(プロファイルなし)」でタイルからブリッジを起動すると必ず
        // determineMachine が落ち、しかも NDJSON を出さずに終わるので拡張には何も出なかった
        // (実害 2026-08-29)
        let machineProfile: MachineProfile
        let machineLabel: String
        if profile != nil {
            let machine = try ProfileResolver.determineMachine(
                project: testProject, runProfileName: profile)
            if machine.auto {
                logStderr("→ Using machine profile \(machine.name) automatically (it is the only one in machines/)")
            }
            let machineURL = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
            guard FileManager.default.fileExists(atPath: machineURL.path) else {
                throw ProfileError.machineProfileNotFound(
                    machine: machine.name,
                    available: ProfileResolver.machineNames(project: testProject))
            }
            do {
                machineProfile = try JSONDecoder().decode(
                    MachineProfile.self, from: Data(contentsOf: machineURL))
            } catch {
                throw ProfileError.decodeFailed(machineURL, detail: "\(error)")
            }
            machineLabel = machine.name
        } else {
            let registry = (LocalConfig.load().remoteHosts ?? []).map(\.machine)
            machineProfile = MachineInventory.mergedProfile(MachineInventory.observableEntries(
                profiles: MachineInventory.loadAll(project: testProject) { logStderr("→ \($0)") },
                registry: registry))
            machineLabel = "machines/"
        }

        let spec: DeviceSpec
        let platform: String
        switch findDevice(name: name, deviceMachine: deviceMachine, in: machineProfile) {
        case .found(let foundSpec, let foundPlatform):
            spec = foundSpec
            platform = foundPlatform
        case .ambiguous(let hosts):
            emitFinished(ok: false, error: "\(name) exists on more than one machine"
                + " (\(hosts.joined(separator: ", "))) — pass --device-machine to say which one"
                + " (machine \(machineLabel))")
            throw ExitCode(1)
        case .missing:
            emitFinished(ok: false, error: "device not found: \(name)"
                + (deviceMachine == nil ? ""
                   : " on \(DeviceMachineGrouping.display(MachineDispatch.normalize(deviceMachine)))")
                + " (machine \(machineLabel))")
            throw ExitCode(1)
        }

        do {
            try await body(spec, platform) { message in emitLog(message) }
            emitFinished(ok: true, error: nil)
        } catch {
            // .failure() を通す —— 素の emitFinished だと署名エラーの機械可読フィールド
            // (signingProblems/signingLogPath)が落ち、登録済みデバイスのタイル起動だけ
            // 拡張の案内が英語1行に退化する(--udid 直指定の startPhysicalBridge と同じ形にする)
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent.failure(error))
            throw ExitCode(1)
        }
    }

    /// --name をマシンプロファイルの ios/android 両方から検索する(ApiDevicesRestart も利用するため fileprivate)。
    /// **一意なのは name 単体ではなく (host, name)** —— 名前だけで引くと、同名の台が別の機械にも
    /// 居るとき(フリートでは通常)**別の機械のつもりの操作が手元の台に当たる**。
    ///
    /// `deviceMachine` を渡さない(= nil)ときは**候補が1つのときだけ**採る。2つ以上あれば
    /// `.ambiguous` で止める —— 黙って手元を選ぶと「M1Max を止めたつもりで手元が止まる」に
    /// なり、しかも成功したように見える(2026-08-17 に実際に起きた: 版の古い拡張が
    /// `--device-machine` を付けずに撃ち、手元の同名シミュレータが2台停止した)。
    /// 実行プロファイルの参照解決(`DeviceMachineGrouping.resolve`)と同じ規律
    enum DeviceLookup {
        case found(spec: DeviceSpec, platform: String)
        case missing
        case ambiguous(machines: [String])
    }

    static func findDevice(
        name: String, deviceMachine: String?, in machine: MachineProfile
    ) -> DeviceLookup {
        let entries = DeviceMachineGrouping.entries(machine: machine).filter { $0.name == name }
        guard deviceMachine != nil else {
            let machines = DeviceMachineGrouping.groups(entries, machine: { MachineDispatch.normalize($0.spec.machine) })
            if machines.count > 1 {
                return .ambiguous(machines: machines.map { DeviceMachineGrouping.display($0.machine) })
            }
            guard let entry = entries.first else { return .missing }
            return .found(spec: entry.spec, platform: entry.platform)
        }
        let wanted = MachineDispatch.normalize(deviceMachine)
        guard let entry = entries.first(where: { MachineDispatch.normalize($0.spec.machine) == wanted })
        else { return .missing }
        return .found(spec: entry.spec, platform: entry.platform)
    }

    private static func emitLog(_ message: String) {
        ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(message: message))
    }

    private static func emitFinished(ok: Bool, error: String?) {
        ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: ok, error: error))
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// stdout への NDJSON 1行出力(JSONEncoder sortedKeys)。ApiDeviceOperation(1台のみ・並行呼び出し
/// なし)と ApiDevicesUp(bootAll のワーカータスクから並行に呼ばれる)で共有する。NSLock で
/// print までを直列化し、複数タスクからの出力が1行の途中で混ざらないようにする
private enum ApiDeviceEventEmitter {
    private static let lock = NSLock()

    /// 子プロセス(リモートへ分散したぶん)の NDJSON を**そのまま**流す。行を作り直すと
    /// host 等のフィールドを落としかねないので、解釈せず中継する
    static func emitRaw(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        print(line)
    }

    static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        print(line)
    }
}

/// 進捗ログ 1 行分(DeviceBooter/BridgeProvisioner の log コールバック由来)
private struct ApiDeviceLogEvent: Encodable {
    let kind = "log"
    let message: String
}

/// device-wipe のフェーズ通知(DeviceWiper/AndroidDataWiper の status コールバック由来)。
/// 拡張はこれをタイルの Wipe 表示(wipeStatus)へそのまま流す —— run 開始時の自動 Wipe
/// (ApiRunCommand の wipeStatus イベント)と**同じフェーズ集合**にしてある
private struct ApiDeviceWipeStatusEvent: Encodable {
    let kind = "wipeStatus"
    let phase: String
}

/// devices-up の per-device 進捗(kind: "deviceStarting" / "deviceFinished")。
/// devices-restart も同型を使い、加えて kind: "deviceStopping" を送出する。
/// 消費側: vscode-fleetest/src/monitorModel.ts isDevicesUpEvent(契約の同期相手)
private struct ApiDevicesUpLifecycleEvent: Encodable {
    let kind: String
    let name: String
    let platform: String
    /// **どの機械のデバイスか**(マシン名 = エイリアス。手元は nil)。同名のデバイスが別の機械にも
    /// 居るのは通常なので、名前だけでは受け手がタイルを特定できない(拡張のタイル id は
    /// platform:machine/name)。リモートへ分散したときは、子プロセスの行をそのまま中継するので
    /// 値は子が入れる。**キーは "machine"**(2026-08-26 改名。対向は
    /// vscode-fleetest/src/monitorDeviceLifecycle.ts の DevicesUpEvent)
    let machine: String?
}

/// 末尾イベント。error は省略可能フィールドとして明示的に null を encode する
/// (ApiScenarioInfo と同方針)
private struct ApiDeviceFinishedEvent: Encodable {
    let kind = "finished"
    let ok: Bool
    let error: String?
    /// 実機の署名設定で止まったときに**何が欠けているか**(XcodeSigningProblem の raw 値)。
    /// error は英語の案内(CLI 利用者向け)で、受け手はこちらから**自分の言語で**案内を
    /// 組み立てる(対向: vscode-fleetest/src/monitorDeviceOps.ts の signingGuidance)。
    /// 追加のみの省略可能フィールド = 旧い受け手は error をそのまま出すだけで壊れない
    var signingProblems: [String]?
    /// そのときの xcodebuild の全出力の在り処(受け手の案内に載せる)
    var signingLogPath: String?

    private enum CodingKeys: String, CodingKey {
        case kind, ok, error, signingProblems, signingLogPath
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        try container.encodeIfPresent(signingProblems, forKey: .signingProblems)
        try container.encodeIfPresent(signingLogPath, forKey: .signingLogPath)
    }

    /// 失敗イベント。**署名の欠けだけは機械可読でも返す**(受け手が自分の言語で案内を出せるように)
    static func failure(_ error: Error) -> ApiDeviceFinishedEvent {
        guard case .codeSigningIncomplete(let problems, let logPath)? = error as? LauncherError else {
            return ApiDeviceFinishedEvent(ok: false, error: error.localizedDescription)
        }
        return ApiDeviceFinishedEvent(
            ok: false, error: error.localizedDescription,
            signingProblems: problems.map(\.rawValue), signingLogPath: logPath)
    }
}
