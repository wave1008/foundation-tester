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
    var name: String

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name, used to resolve the machine. When given, that profile's machine wins; otherwise FT_MACHINE, the registered machine, or the only entry in machines/")
    var profile: String?

    @Option(help: "Android GPU rendering mode (host / swiftshader_indirect; default host). Used as the CPU-rendering fallback for devices that freeze")
    var gpu: String?

    @Option(name: .customLong("device-host"),
            help: "Only match devices assigned to this machine (\"local\" or a registered host name). Set by the caller on the other end of ssh")
    var deviceHost: String?

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
        try await ApiDeviceOperation.run(
            name: name, project: project, profile: profile, deviceHost: deviceHost
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

    @Option(name: .customLong("device-host"), help: ArgumentHelp(
        "Operate on the devices that belong to this machine (registered host name)."
        + " Default: the devices with no host (this machine). Used when a parent dispatches"
        + " to a runner: remote exec <name> -- ... --device-host <name>"))
    var deviceHost: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile, deviceHost: deviceHost,
                noteAutoMachine: { Self.logStderr($0) },
                warn: { Self.logStderr($0) })
            let repoRoot = noBridge ? nil : try RepoRoot.find()
            // **リモートのぶんはその機械へ投げる**(手元の起動と同時に走る。RemoteDeviceFanout)。
            // 起動は機械ごとに独立した資源を使うので、「同時2台」の上限は機械ごとに持てる
            let hosts = RemoteDeviceFanout.remoteHosts(
                project: project, profile: profile, deviceHost: deviceHost)
            async let fanout: Void = RemoteDeviceFanout.dispatch(
                subcommand: "devices-up", hosts: hosts, project: project, profile: profile,
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
                                                   host: MachineHostDispatch.normalize(deviceHost)))
                },
                deviceStarting: { name, platform in
                    ApiDeviceEventEmitter.emit(
                        ApiDevicesUpLifecycleEvent(kind: "deviceStarting", name: name, platform: platform,
                                                   host: MachineHostDispatch.normalize(deviceHost)))
                },
                deviceFinished: { name, platform in
                    ApiDeviceEventEmitter.emit(
                        ApiDevicesUpLifecycleEvent(kind: "deviceFinished", name: name, platform: platform,
                                                   host: MachineHostDispatch.normalize(deviceHost)))
                })
            await fanout  // リモート分の完走まで finished を出さない(受け手の「全部終わった」の合図)
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: true, error: nil))
        } catch {
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: false, error: error.localizedDescription))
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

    @Option(name: .customLong("device-host"), help: ArgumentHelp(
        "Operate on the devices that belong to this machine (registered host name)."
        + " Default: the devices with no host (this machine)"))
    var deviceHost: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard !name.isEmpty else {
            throw ValidationError("specify at least one --name")
        }
        do {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile, deviceHost: deviceHost,
                noteAutoMachine: { Self.logStderr($0) },
                warn: { Self.logStderr($0) })

            var items: [RestartItem] = []
            for deviceName in name {
                // machineProfile は MachineProfileLoad.load が deviceHost で絞った後なので、
                // ここに残っているのは「この機械の台」だけ(entries が host を焼き込んでいる)
                guard case .found(let spec, let platform) = ApiDeviceOperation.findDevice(
                    name: deviceName, deviceHost: deviceHost, in: machineProfile) else {
                    ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(
                        ok: false, error: "device not found: \(deviceName)"))
                    throw ExitCode(1)
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
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: false, error: error.localizedDescription))
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
                                       host: spec.host))
        do {
            try await DeviceBooter.shutdownOne(
                spec: spec, platform: platform,
                repoRoot: platform == "ios" ? repoRoot : nil, log: log)
            ApiDeviceEventEmitter.emit(
                ApiDevicesUpLifecycleEvent(kind: "deviceStarting", name: spec.name, platform: platform,
                                           host: spec.host))
            try await DeviceBooter.bootOne(spec: spec, platform: platform, log: log)
        } catch {
            log("❌ \(spec.name): \(error.localizedDescription)")
        }
        ApiDeviceEventEmitter.emit(
            ApiDevicesUpLifecycleEvent(kind: "deviceFinished", name: spec.name, platform: platform,
                                       host: spec.host))
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

    @Option(name: .customLong("device-host"), help: ArgumentHelp(
        "Operate on the devices that belong to this machine (registered host name)."
        + " Default: the devices with no host (this machine). Used when a parent dispatches"
        + " to a runner: remote exec <name> -- ... --device-host <name>"))
    var deviceHost: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile, deviceHost: deviceHost,
                noteAutoMachine: { Self.logStderr($0) },
                warn: { Self.logStderr($0) })
            // リモートのぶんはその機械へ投げる(起動と同じ分散。RemoteDeviceFanout)
            let hosts = RemoteDeviceFanout.remoteHosts(
                project: project, profile: profile, deviceHost: deviceHost)
            async let fanout: Void = RemoteDeviceFanout.dispatch(
                subcommand: "devices-down", hosts: hosts, project: project, profile: profile,
                relay: { ApiDeviceEventEmitter.emitRaw($0) })

            // shutdownProfile と同じ ios→android 逐次(1台落ちるごとに deviceFinished を出すので、
            // 拡張側は落ちた順にタイルを「未起動」へ倒せる)。iOS のみブリッジ停止のため repoRoot を渡す。
            let repoRoot = try? RepoRoot.find()
            for spec in machineProfile.ios?.devices ?? [] {
                await Self.shutdownOneEmitting(spec: spec, platform: "ios", repoRoot: repoRoot)
            }
            for spec in machineProfile.android?.devices ?? [] {
                await Self.shutdownOneEmitting(spec: spec, platform: "android", repoRoot: nil)
            }
            await fanout  // リモート分の完走まで finished を出さない(受け手の「全部終わった」の合図)
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: true, error: nil))
        } catch {
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: false, error: error.localizedDescription))
            throw ExitCode(1)
        }
    }

    /// 1台停止。失敗しても deviceFinished は必ず送出する(拡張の再スキャン契約。
    /// ApiDevicesUp/Restart の deviceFinished 契約と同じ)。
    private static func shutdownOneEmitting(spec: DeviceSpec, platform: String, repoRoot: URL?) async {
        let log: @Sendable (String) -> Void = { message in
            ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(message: message))
        }
        ApiDeviceEventEmitter.emit(
            ApiDevicesUpLifecycleEvent(kind: "deviceStopping", name: spec.name, platform: platform,
                                       host: spec.host))
        do {
            try await DeviceBooter.shutdownOne(spec: spec, platform: platform, repoRoot: repoRoot, log: log)
        } catch {
            log("❌ \(spec.name): \(error.localizedDescription)")
        }
        ApiDeviceEventEmitter.emit(
            ApiDevicesUpLifecycleEvent(kind: "deviceFinished", name: spec.name, platform: platform,
                                       host: spec.host))
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

    @Option(name: .customLong("device-host"),
            help: "Only match devices assigned to this machine (\"local\" or a registered host name). Set by the caller on the other end of ssh")
    var deviceHost: String?

    func run() async throws {
        switch try ApiDeviceDownDirectTarget.resolve(name: name, udid: udid, serial: serial) {
        case .name(let name):
            try await ApiDeviceOperation.run(
                name: name, project: project, profile: profile, deviceHost: deviceHost
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
            ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(ok: false, error: error.localizedDescription))
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
        name: String, project: String?, profile: String?, deviceHost: String? = nil,
        body: @escaping @Sendable (
            DeviceSpec, String, @escaping @Sendable (String) -> Void
        ) async throws -> Void
    ) async throws {
        // finished 到達を読み手が確実に検知できるよう、log イベントもすぐ流す
        setvbuf(stdout, nil, _IOLBF, 0)

        let testProject = try ScenarioHost.project(named: project)
        // runProfileName を渡すと determineMachine が実行プロファイルの machine を最優先で解決する。
        // これが無いと machines/ 複数時に「マシン名が未登録」で落ちる(DevicesCommand.Up と同経路)。
        let machine = try ProfileResolver.determineMachine(
            project: testProject,
            runProfileName: profile)
        if machine.auto {
            logStderr("→ Using machine profile \(machine.name) automatically (it is the only one in machines/)")
        }
        let machineURL = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
        guard FileManager.default.fileExists(atPath: machineURL.path) else {
            throw ProfileError.machineProfileNotFound(
                machine: machine.name,
                available: ProfileResolver.machineNames(project: testProject))
        }
        let machineProfile: MachineProfile
        do {
            machineProfile = try JSONDecoder().decode(
                MachineProfile.self, from: Data(contentsOf: machineURL))
        } catch {
            throw ProfileError.decodeFailed(machineURL, detail: "\(error)")
        }

        let spec: DeviceSpec
        let platform: String
        switch findDevice(name: name, deviceHost: deviceHost, in: machineProfile) {
        case .found(let foundSpec, let foundPlatform):
            spec = foundSpec
            platform = foundPlatform
        case .ambiguous(let hosts):
            emitFinished(ok: false, error: "\(name) exists on more than one machine"
                + " (\(hosts.joined(separator: ", "))) — pass --device-host to say which one"
                + " (machine \(machine.name))")
            throw ExitCode(1)
        case .missing:
            emitFinished(ok: false, error: "device not found: \(name)"
                + (deviceHost == nil ? ""
                   : " on \(DeviceHostGrouping.display(MachineHostDispatch.normalize(deviceHost)))")
                + " (machine \(machine.name))")
            throw ExitCode(1)
        }

        do {
            try await body(spec, platform) { message in emitLog(message) }
            emitFinished(ok: true, error: nil)
        } catch {
            emitFinished(ok: false, error: error.localizedDescription)
            throw ExitCode(1)
        }
    }

    /// --name をマシンプロファイルの ios/android 両方から検索する(ApiDevicesRestart も利用するため fileprivate)。
    /// **一意なのは name 単体ではなく (host, name)** —— 名前だけで引くと、同名の台が別の機械にも
    /// 居るとき(フリートでは通常)**別の機械のつもりの操作が手元の台に当たる**。
    ///
    /// `deviceHost` を渡さない(= nil)ときは**候補が1つのときだけ**採る。2つ以上あれば
    /// `.ambiguous` で止める —— 黙って手元を選ぶと「M1Max を止めたつもりで手元が止まる」に
    /// なり、しかも成功したように見える(2026-08-17 に実際に起きた: 版の古い拡張が
    /// `--device-host` を付けずに撃ち、手元の同名シミュレータが2台停止した)。
    /// 実行プロファイルの参照解決(`DeviceHostGrouping.resolve`)と同じ規律
    enum DeviceLookup {
        case found(spec: DeviceSpec, platform: String)
        case missing
        case ambiguous(hosts: [String])
    }

    static func findDevice(
        name: String, deviceHost: String?, in machine: MachineProfile
    ) -> DeviceLookup {
        let entries = DeviceHostGrouping.entries(machine: machine).filter { $0.name == name }
        guard deviceHost != nil else {
            let hosts = DeviceHostGrouping.groups(entries, host: { MachineHostDispatch.normalize($0.spec.host) })
            if hosts.count > 1 {
                return .ambiguous(hosts: hosts.map { DeviceHostGrouping.display($0.host) })
            }
            guard let entry = entries.first else { return .missing }
            return .found(spec: entry.spec, platform: entry.platform)
        }
        let wanted = MachineHostDispatch.normalize(deviceHost)
        guard let entry = entries.first(where: { MachineHostDispatch.normalize($0.spec.host) == wanted })
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

/// devices-up の per-device 進捗(kind: "deviceStarting" / "deviceFinished")。
/// devices-restart も同型を使い、加えて kind: "deviceStopping" を送出する。
/// 消費側: vscode-fleetest/src/monitorModel.ts isDevicesUpEvent(契約の同期相手)
private struct ApiDevicesUpLifecycleEvent: Encodable {
    let kind: String
    let name: String
    let platform: String
    /// **どの機械のデバイスか**(手元は nil)。同名のデバイスが別の機械にも居るのは通常なので、
    /// 名前だけでは受け手がタイルを特定できない(拡張のタイル id は platform:host/name)。
    /// リモートへ分散したときは、子プロセスの行をそのまま中継するので値は子が入れる
    let host: String?
}

/// 末尾イベント。error は省略可能フィールドとして明示的に null を encode する
/// (ApiScenarioInfo と同方針)
private struct ApiDeviceFinishedEvent: Encodable {
    let kind = "finished"
    let ok: Bool
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case kind, ok, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
    }
}
