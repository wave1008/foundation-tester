// マシンプロファイルに定義されたデバイス群の起動・停止 CLI。
//   fleetest devices up   … 並行起動(最大2台同時・起動済みスキップ・iOS はブリッジ供給まで。
//                           1台以上あって0台成功=全滅は exit 1、部分失敗は要約1行を出し exit 0)
//   fleetest devices down … 全ブリッジ停止+シミュレータ/エミュレータ全終了(--profile 無しは
//                           登録簿の全マシンでも同じ掃討を走らせる。RemoteDeviceFanout.dispatchSweep)
// どちらも --profile(実行プロファイル名)指定時は、そのプロファイルが参照するデバイスのみを
// 対象にする(RunProfileScope.swift。省略時はマシンプロファイルの全デバイス)。
// DeviceBooter / BridgeProvisioner を直接使う(fleetest api start-device/stop-device と共通の実装)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct DevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "Start and stop the devices in the machine profile",
        subcommands: [Up.self, Down.self])

    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start every device (at most two at a time; already-running devices are skipped."
                + " With --profile, only the devices that profile references. Exit code 1 if every"
                + " device failed to start; partial failures still exit 0 but are summarized)")

        @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(help: "Run profile name (when given, only the devices that profile references are started; otherwise every device in the machine profile)")
        var profile: String?

        @Flag(name: .customLong("no-bridge"), help: "Do not provision the iOS bridge")
        var noBridge = false

        @Option(name: .customLong("device-machine"), help: ArgumentHelp(
            "Operate on the devices that belong to this machine (a name registered with fleetest remote machines)."
            + " Default: the devices with no host (this machine). Used when a parent dispatches"
            + " to a runner: remote exec <name> -- ... --device-machine <name>"))
        var deviceMachine: String?

        func run() async throws {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile, deviceMachine: deviceMachine,
                foreign: .notHandled,  // `devices up` は分散しない(api start-all-devices が分散する側)
                noteAutoMachine: { ConsoleOut.out($0) },
                warn: { ConsoleOut.out($0) })

            // iOS はブート完了分をバッチで束ねてブリッジ供給する(bootAll 内。ブートと供給は並行)
            let repoRoot = noBridge ? nil : try RepoRoot.find()
            let outcomes = await DeviceBooter.bootAll(
                machine: machineProfile, repoRoot: repoRoot) { ConsoleOut.out($0) }
            let summary = DeviceBooter.BootOutcomeSummarizer.summarize(outcomes)
            // 1台も無い/全部成功は従来どおりの1行。**全滅は exit 1**(1台以上あって0台成功。
            // 1台も起動できていないのに exit 0 で ✅ を出していたのが不具合1の実害)。
            // 部分失敗は exit 0 のまま(CLAUDE.md「1台の失敗で全体を落とさない」)だが必ず要約する
            if summary.failedNames.isEmpty {
                ConsoleOut.out("✅ Device start-up sequence complete")
            } else if summary.allFailed {
                ConsoleOut.out("❌ Device start-up failed: 0/\(summary.total) started"
                    + " — failed: \(summary.failedNames.joined(separator: ", "))")
                throw ExitCode(1)
            } else {
                ConsoleOut.out("⚠️ Device start-up sequence complete: \(summary.succeededCount)/\(summary.total) started"
                    + " — failed: \(summary.failedNames.joined(separator: ", "))")
            }
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop every bridge and shut down all simulators and emulators, on this machine and"
                + " on every machine in the remote registry (physical devices are never shut down, but"
                + " their bridges are always stopped too). With --profile, only the devices that profile"
                + " references are stopped individually, on this machine only (physical devices in scope"
                + " get their bridge stopped, but are never shut down).")

        @Option(help: "Test project name (only used with --profile; defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(help: "Run profile name (when given, only the devices that profile references are stopped individually; otherwise every bridge is stopped and all simulators and emulators are shut down)")
        var profile: String?

        @Option(name: .customLong("device-machine"), help: ArgumentHelp(
            "Operate on the devices that belong to this machine (a name registered with fleetest remote machines)."
            + " Default: the devices with no host (this machine). Used when a parent dispatches"
            + " to a runner: remote exec <name> -- ... --device-machine <name>"))
        var deviceMachine: String?

        func run() async throws {
            if let profile {
                await shutdownProfile(profile)
                return
            }

            // 手元だけ掃討しても**モニターに出ているリモートの台は残る**(「全て終了」を押しても
            // 消えない。実害 2026-08-30)。監視と同じ集合(登録簿の全マシン)へ同じ掃討を投げる。
            // 子は `--device-machine local` で走るので入れ子にはならない
            async let fanout: Void = RemoteDeviceFanout.dispatchSweep(
                machines: RemoteDeviceFanout.sweepMachines(deviceMachine: deviceMachine),
                relay: { ConsoleOut.out($0) })

            if let root = try? RepoRoot.find() {
                // 実機ランナー(xcodebuild)も掃討対象 —— 「全て終了」は実機のブリッジも
                // 止める(ユーザー決定 2026-09-08)。stopAll は ps を見て殺すだけで、実機の
                // 端末そのものには simctl/adb 相当のコマンドを一切撃たない
                let stopped = BridgeLauncher.stopAll(repoRoot: root, skipPhysical: false)
                if !stopped.isEmpty {
                    ConsoleOut.out("✅ Bridges stopped (port: \(stopped.joined(separator: ", ")))")
                }
            }
            // exit code でなくカタログの実状態で成否判定し、Booted が残れば再試行する
            // (DeviceBooter.shutdownOne と同じ理由: macOS 27 beta の 405 レース、および
            // 生き残ったセッションによる shutdown 中の再ブート)
            var shutdownConfirmed = false
            for attempt in 1...3 {
                _ = try? Shell.run(["xcrun", "simctl", "shutdown", "all"])
                let stillBooted = (try? SimulatorCatalog.devices())?.contains(where: \.booted) ?? false
                if !stillBooted {
                    shutdownConfirmed = true
                    break
                }
                if attempt < 3 {
                    ConsoleOut.out("→ Some simulators have not shut down yet — retrying (\(attempt)/3)...")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            if shutdownConfirmed {
                ConsoleOut.out("✅ All simulators shut down")
            } else {
                ConsoleOut.out("⚠️ Some simulators will not stop (check xcrun simctl list devices)")
            }
            // gRPC SHUTDOWN 優先(adb 経路死亡でも届く)・不可なら emu kill。
            // それでも offline には届かないため、残った qemu を最後に直接落とす
            if let adb = try? AndroidDriver.findADB(),
               let serials = try? AndroidDeviceCatalog.allEmulatorSerials() {
                for serial in serials {
                    if await !EmulatorControl.shutdown(serial: serial) {
                        _ = try? Shell.run([adb, "-s", serial, "emu", "kill"])
                    }
                    ConsoleOut.out("✅ Emulator shut down (\(serial))")
                }
                if !serials.isEmpty {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    _ = try? Shell.run(["pkill", "-9", "-f", "sdk/emulator/qemu"])
                }
            }
            // 実機のブリッジも掃討対象(ユーザー決定 2026-09-08)。emu kill/pkill は撃たない ——
            // connectedSerials()(adb に見えている全台)から allEmulatorSerials() を引いた残りが
            // 実機の serial で、AndroidDriver.stopBridge() はアプリの force-stop + adb forward
            // 解除だけを行い端末の電源には触らない
            if let connected = try? AndroidDeviceCatalog.connectedSerials(),
               let emulators = try? AndroidDeviceCatalog.allEmulatorSerials() {
                let emulatorSerials = Set(emulators)
                for serial in connected where !emulatorSerials.contains(serial) {
                    if let driver = try? AndroidDriver(serial: serial) {
                        driver.stopBridge()
                        ConsoleOut.out("✅ Bridge stopped (physical device \(serial), device itself keeps running)")
                    }
                }
            }
            await fanout  // リモート分の完走まで抜けない(呼び出し側の「全部終わった」の合図)
        }

        /// 対象デバイスのみ ios→android の順で shutdownOne により個別停止する(ApiDeviceDown と
        /// 同じ流儀)。マシン解決・読み込み・個々の停止いずれの失敗も警告に留めて続行し
        /// (1台の失敗で全体を止めない)、exit 0 で完走する。実機の扱い(端末は落とさずブリッジ
        /// だけ止める)は shutdownOne 側の分岐に任せる —— 呼び出し側に実機の知識を持たせない
        private func shutdownProfile(_ profile: String) async {
            do {
                let filtered = try MachineProfileLoad.load(
                    project: project, profile: profile, deviceMachine: deviceMachine,
                    foreign: .notHandled,  // --profile 付きの掃討は手元だけ
                    noteAutoMachine: { ConsoleOut.out($0) },
                    warn: { ConsoleOut.out($0) })

                // iOS はシミュレータ停止前に稼働ブリッジも探して停止する(ゾンビ化防止)。repoRoot
                // 未検出時はブリッジ停止をスキップし simctl shutdown のみ行う(ApiDeviceDown と同じ)
                let repoRoot = try? RepoRoot.find()
                for spec in filtered.ios?.devices ?? [] {
                    do {
                        try await DeviceBooter.shutdownOne(
                            spec: spec, platform: "ios", repoRoot: repoRoot, log: { ConsoleOut.out($0) })
                    } catch {
                        ConsoleOut.out("⚠️ \(spec.name): \(error.localizedDescription)")
                    }
                }
                for spec in filtered.android?.devices ?? [] {
                    do {
                        try await DeviceBooter.shutdownOne(
                            spec: spec, platform: "android", log: { ConsoleOut.out($0) })
                    } catch {
                        ConsoleOut.out("⚠️ \(spec.name): \(error.localizedDescription)")
                    }
                }
            } catch {
                ConsoleOut.out("⚠️ \(error.localizedDescription)")
            }
        }
    }
}

/// devices up/down・api start-all-devices 共通: プロジェクト/実行プロファイルからマシンプロファイルを
/// 解決して読み込む(profile 指定時はそのプロファイルが参照するデバイスのみに絞る)。
/// Up の従来コードをそのまま移した実装(ApiDeviceOperation の machineProfileNotFound ガードは
/// 意図的に取り込まない。ファイル未検出時は Data(contentsOf:) がそのまま throw する Up 従来挙動を維持)
enum MachineProfileLoad {
    /// - deviceMachine: **どの機械のデバイスを扱うか**(nil/"local" = 手元)。リモート機で自分の
    ///   デバイスを起こすときに使う —— 転送されたマシンプロファイルにはそのデバイスの host
    ///   (= その機械の登録名)が書いてあり、CLI には「自分が誰か」を知る手段が無いため、
    ///   呼び出し側(親)が明示する。例: `remote exec M1Max -- devices up --profile p --device-machine M1Max`
    /// **他の機械のデバイスを呼び出し側がどう扱うか**。既定値を置かない —— 分散する経路で
    /// 「その機械で起動してください」と案内すると、直後にツール自身が起動するので嘘になる
    /// (実害 2026-08-30: 一括起動のログで、案内の 2 秒後に fan-out が同じ台を起動していた)
    enum ForeignDevices {
        /// 呼び出し側が RemoteDeviceFanout でその機械へ回す(api start-all-devices / stop-all-devices)
        case dispatchedByCaller
        /// 誰も扱わない = 本当に落とす(手元専用の経路)
        case notHandled
    }

    static func load(project: String?, profile: String?, deviceMachine: String? = nil,
                     foreign: ForeignDevices,
                     noteAutoMachine: (String) -> Void,
                     warn: (String) -> Void) throws -> MachineProfile {
        try load(project: try ScenarioHost.project(named: project), profile: profile,
                 deviceMachine: deviceMachine,
                 registry: (LocalConfig.load().remoteHosts ?? []).map(\.machine),
                 foreign: foreign,
                 noteAutoMachine: noteAutoMachine, warn: warn)
    }

    /// プロジェクトと登録簿を受け取る本体(テストが差し替えられるように分けてある)。
    static func load(project testProject: TestProject, profile: String?, deviceMachine: String?,
                     registry: [String], foreign: ForeignDevices,
                     noteAutoMachine: (String) -> Void,
                     warn: (String) -> Void) throws -> MachineProfile {
        // **実行プロファイルを選んでいなければ台帳を1つに決めない** —— machines/ を全部畳み、
        // 手元 + リモート実行の登録簿にあるマシンの台を対象にする(監視 = ApiMonitorCommand・
        // 単体操作 = ApiDeviceOperation と同じ規律)。決められないという理由で操作を断らない:
        // 台帳が2つある案件では「(プロファイルなし)」のまま「デバイスを全て起動」を押しても
        // `cannot tell which machine profile to use` で即死し、**画面には何も起きない**
        // (実害 2026-08-29)
        guard let profile else {
            let inventory = MachineInventory.merge(
                sources: MachineInventory.loadAllNamed(project: testProject) { warn("→ \($0)") },
                registry: registry, existsLocally: nil)
            // 食い違いを黙って畳むと、実在しないほうの実体で起動しようとして
            // `no simulator with that UDID` になる。**ここは先頭優先のまま警告だけ** ——
            // 実在で決着させる述語(ApiMonitorCommand.localPresencePredicate)は simctl/adb を
            // 叩くので、単発コマンドの応答へ載せない
            for conflict in inventory.conflicts { warn("→ \(conflict.message)") }
            let merged = MachineInventory.mergedProfile(inventory.entries)
            return keepingDevices(of: deviceMachine, in: merged, foreign: foreign, warn: warn)
        }
        // --profile の machine 明示指定を最優先(ProfileResolver.resolve() と同じ優先順位)
        let machine = try ProfileResolver.determineMachine(
            project: testProject,
            runProfileName: profile)
        if machine.auto {
            noteAutoMachine("→ Using machine profile \(machine.name) automatically")
        }
        let url = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
        var machineProfile = try JSONDecoder().decode(
            MachineProfile.self, from: Data(contentsOf: url))

        machineProfile = try RunProfileScope.filteredMachineProfile(
            project: testProject, machineName: machine.name, machineProfile: machineProfile,
            runProfileName: profile, warn: warn)
        return keepingDevices(of: deviceMachine, in: machineProfile, foreign: foreign, warn: warn)
    }

    /// **この機械が扱えるデバイスだけ**にする(既定は手元 = host 無し)。起動・停止は simctl/adb を
    /// 叩く操作なので、別の機械のデバイスはここからは扱えない —— 残すと「起動待機のまま
    /// 終わらないタイル」と、存在しない UDID への simctl boot(必ず失敗)を並べることになる
    /// (2026-08-17 の実害)。落とした分は必ず言う(黙って減らさない)。
    /// `deviceMachine` を渡すと、そのマシンのデバイスを**手元のものとして**扱う(上の doc 参照)
    static func keepingDevices(of deviceMachine: String?, in profile: MachineProfile,
                               foreign: ForeignDevices,
                               warn: (String) -> Void) -> MachineProfile {
        let wanted = MachineDispatch.normalize(deviceMachine)
        let entries = DeviceMachineGrouping.entries(machine: profile)
        let others = entries.filter { $0.machine != wanted }
        guard !others.isEmpty else { return profile }

        for (machine, devices) in DeviceMachineGrouping.groups(others, machine: { $0.machine }) {
            let names = devices.map(\.name).joined(separator: ", ")
            let machineLabel = DeviceMachineGrouping.display(machine)
            if foreign == .dispatchedByCaller, machine != nil {
                // 呼び出し側がこの後その機械へ回す。手動の案内を出すと嘘になる
                warn("→ Dispatching \(devices.count) device(s) to \(machineLabel): \(names)")
                continue
            }
            warn("→ Skipping \(devices.count) device(s) on \(machineLabel): \(names)"
                + (machine == nil
                   ? " (they are on this machine; drop --device-machine to use them)"
                   : " (start them there: fleetest remote exec \(machineLabel)"
                     + " -- devices up --device-machine \(machineLabel))"))
        }
        let kept = entries.filter { $0.machine == wanted }
        let ios = kept.filter { $0.platform == "ios" }.map(\.spec)
        let android = kept.filter { $0.platform == "android" }.map(\.spec)
        return MachineProfile(
            machine: profile.machine,
            ios: ios.isEmpty ? nil : MachineDeviceList(devices: ios),
            android: android.isEmpty ? nil : MachineDeviceList(devices: android))
    }
}
