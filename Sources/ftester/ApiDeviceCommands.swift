// VSCode拡張のライブ操作パネル向け: マシンプロファイル記載のデバイス1台の起動・停止
// (ftester api device-up / device-down)。起動・停止の実装(DeviceBooter/BridgeProvisioner)は
// DevicesCommand(ftester devices)と共通。stdout には NDJSON(log* → finished)だけを出す
// (診断は stderr のみ。ok:false のときは exit code 1)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiDeviceUp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-up",
        abstract: "マシンプロファイル記載のデバイス1台を起動する(NDJSON: log* → finished を"
            + "stdout に出力。診断は stderr のみ。ok:false のときは exit code 1)")

    @Option(help: "デバイスの論理名(マシンプロファイルの ios/android どちらかの name)")
    var name: String

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "実行プロファイル名(machine 解決に使う。指定時はそのプロファイルの machine を最優先。省略時は FT_MACHINE / 登録マシン / machines が 1 つならそれ)")
    var profile: String?

    @Option(help: "Android の GPU 描画モード(host / swiftshader_indirect。既定 host。凍結個体の CPU 描画フォールバック用)")
    var gpu: String?

    func run() async throws {
        let resolvedGpu: String
        switch gpu {
        case nil:
            resolvedGpu = "host"
        case "host"?, "swiftshader_indirect"?:
            resolvedGpu = gpu!
        default:
            FileHandle.standardError.write(Data("⚠️ 未知の --gpu 値のため host にフォールバック: \(gpu!)\n".utf8))
            resolvedGpu = "host"
        }
        try await ApiDeviceOperation.run(name: name, project: project, profile: profile) { spec, platform, log in
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
        abstract: "マシンプロファイルの全デバイスを起動する(NDJSON: log/deviceStarting/deviceFinished → "
            + "finished を stdout に出力。診断は stderr のみ)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "実行プロファイル名(指定時はそのプロファイルが参照するデバイスのみ起動する)")
    var profile: String?

    @Flag(name: .customLong("no-bridge"), help: "iOS ブリッジの供給を行わない")
    var noBridge = false

    @Option(name: .customLong("restart"), parsing: .upToNextOption,
            help: "起動済みでもスキップせず down→up で再起動するデバイス論理名(CPU 描画フォールバック機の GPU 復帰用。複数指定可。未起動機のブートと同一キューで2台ずつ並行処理される)")
    var restart: [String] = []

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile,
                noteAutoMachine: { Self.logStderr($0) },
                warn: { Self.logStderr($0) })
            let repoRoot = noBridge ? nil : try RepoRoot.find()
            // deviceStopping/deviceStarting/deviceFinished は bootAll のワーカータスクから並行に
            // 呼ばれるため、emit(ApiDeviceEventEmitter 経由)でロックして直列化する
            await DeviceBooter.bootAll(
                machine: machineProfile, repoRoot: repoRoot,
                restartNames: Set(restart),
                log: { message in ApiDeviceEventEmitter.emit(ApiDeviceLogEvent(message: message)) },
                deviceStopping: { name, platform in
                    ApiDeviceEventEmitter.emit(
                        ApiDevicesUpLifecycleEvent(kind: "deviceStopping", name: name, platform: platform))
                },
                deviceStarting: { name, platform in
                    ApiDeviceEventEmitter.emit(
                        ApiDevicesUpLifecycleEvent(kind: "deviceStarting", name: name, platform: platform))
                },
                deviceFinished: { name, platform in
                    ApiDeviceEventEmitter.emit(
                        ApiDevicesUpLifecycleEvent(kind: "deviceFinished", name: name, platform: platform))
                })
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
        abstract: "指定した複数デバイスを down→up で再起動する(2台ずつ並行。NDJSON: "
            + "log/deviceStopping/deviceStarting/deviceFinished → finished を stdout に出力。"
            + "診断は stderr のみ。ok:false のときは exit code 1)")

    @Option(name: .customLong("name"), parsing: .upToNextOption,
            help: "再起動するデバイスの論理名(マシンプロファイルの ios/android どちらか。複数指定可)")
    var name: [String] = []

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "実行プロファイル名(指定時はそのプロファイルが参照するデバイスのみ対象)")
    var profile: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard !name.isEmpty else {
            throw ValidationError("--name を1つ以上指定してください")
        }
        do {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile,
                noteAutoMachine: { Self.logStderr($0) },
                warn: { Self.logStderr($0) })

            var items: [RestartItem] = []
            for deviceName in name {
                guard let found = ApiDeviceOperation.findDevice(name: deviceName, in: machineProfile) else {
                    ApiDeviceEventEmitter.emit(ApiDeviceFinishedEvent(
                        ok: false, error: "デバイスが見つかりません: \(deviceName)"))
                    throw ExitCode(1)
                }
                items.append(RestartItem(spec: found.spec, platform: found.platform))
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
            ApiDevicesUpLifecycleEvent(kind: "deviceStopping", name: spec.name, platform: platform))
        do {
            try await DeviceBooter.shutdownOne(
                spec: spec, platform: platform,
                repoRoot: platform == "ios" ? repoRoot : nil, log: log)
            ApiDeviceEventEmitter.emit(
                ApiDevicesUpLifecycleEvent(kind: "deviceStarting", name: spec.name, platform: platform))
            try await DeviceBooter.bootOne(spec: spec, platform: platform, log: log)
        } catch {
            log("❌ \(spec.name): \(error.localizedDescription)")
        }
        ApiDeviceEventEmitter.emit(
            ApiDevicesUpLifecycleEvent(kind: "deviceFinished", name: spec.name, platform: platform))
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

struct ApiDeviceDown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-down",
        abstract: "マシンプロファイル記載のデバイス1台を停止する(NDJSON: log* → finished を"
            + "stdout に出力。診断は stderr のみ。ok:false のときは exit code 1)")

    @Option(help: "デバイスの論理名(マシンプロファイルの ios/android どちらかの name)")
    var name: String

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "実行プロファイル名(machine 解決に使う。指定時はそのプロファイルの machine を最優先。省略時は FT_MACHINE / 登録マシン / machines が 1 つならそれ)")
    var profile: String?

    func run() async throws {
        try await ApiDeviceOperation.run(name: name, project: project, profile: profile) { spec, platform, log in
            // iOS はシミュレータ停止前に稼働ブリッジも探して停止する(ゾンビ化防止。
            // BridgeProvisioner.provision の失敗時後始末と対)。repoRoot 未検出時は nil のまま
            // 渡しブリッジ停止をスキップして simctl shutdown のみ行う
            let repoRoot = platform == "ios" ? try? RepoRoot.find() : nil
            try await DeviceBooter.shutdownOne(
                spec: spec, platform: platform, repoRoot: repoRoot, log: log)
        }
    }
}

/// ftester api device-up / device-down 共通の実行ロジック
/// (マシンプロファイル読み込み・--name 解決・NDJSON ストリーミング・エラー処理)
private enum ApiDeviceOperation {
    static func run(
        name: String, project: String?, profile: String?,
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
            project: testProject, registered: LocalConfig.currentMachineName(),
            runProfileName: profile)
        if machine.auto {
            logStderr("→ マシンプロファイル自動採用: \(machine.name)(machines/ が 1 つのため)")
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

        guard let found = findDevice(name: name, in: machineProfile) else {
            emitFinished(ok: false, error: "デバイスが見つかりません: \(name)(マシン \(machine.name))")
            throw ExitCode(1)
        }

        do {
            try await body(found.spec, found.platform) { message in emitLog(message) }
            emitFinished(ok: true, error: nil)
        } catch {
            emitFinished(ok: false, error: error.localizedDescription)
            throw ExitCode(1)
        }
    }

    /// --name をマシンプロファイルの ios/android 両方から検索する(ApiDevicesRestart も利用するため fileprivate)
    fileprivate static func findDevice(
        name: String, in machine: MachineProfile
    ) -> (spec: DeviceSpec, platform: String)? {
        if let spec = (machine.ios?.devices ?? []).first(where: { $0.name == name }) {
            return (spec, "ios")
        }
        if let spec = (machine.android?.devices ?? []).first(where: { $0.name == name }) {
            return (spec, "android")
        }
        return nil
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
/// 消費側: vscode-ftester/src/monitorModel.ts isDevicesUpEvent(契約の同期相手)
private struct ApiDevicesUpLifecycleEvent: Encodable {
    let kind: String
    let name: String
    let platform: String
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
