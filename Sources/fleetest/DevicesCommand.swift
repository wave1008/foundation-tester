// 実行プロファイルに定義されたデバイス群の起動・停止 CLI。
//   fleetest devices up   … 並行起動(最大2台同時・起動済みスキップ・iOS はブリッジ供給まで。
//                           1台以上あって0台成功=全滅は exit 1、部分失敗は要約1行を出し exit 0)
//   fleetest devices down … 全ブリッジ停止+シミュレータ/エミュレータ全終了(--profile 無しは
//                           登録簿の全マシンでも同じ掃討を走らせる。RemoteDeviceFanout.dispatchSweep)
// どちらも --profile(実行プロファイル名)指定時は、そのプロファイルが参照するデバイスのみを
// 対象にする(RunProfileScope.swift。省略時は全実行プロファイルのデバイス)。
// DeviceBooter / BridgeProvisioner を直接使う(fleetest api start-device/stop-device と共通の実装)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct DevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "Start and stop the devices in the run profiles",
        subcommands: [Up.self, Down.self])

    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start every device (at most two at a time; already-running devices are skipped."
                + " With --profile, only the devices that profile references. Exit code 1 if every"
                + " device failed to start; partial failures still exit 0 but are summarized)")

        @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(help: "Run profile name (when given, only that profile's enabled devices are started; otherwise the devices of every run profile)")
        var profile: String?

        @Flag(name: .customLong("no-bridge"), help: "Do not provision the iOS bridge")
        var noBridge = false

        @Option(name: .customLong("device-machine"), help: ArgumentHelp(
            "Operate on the devices that belong to this machine (a name registered with fleetest remote machines)."
            + " Default: the devices with no host (this machine). Used when a parent dispatches"
            + " to a runner: remote exec <name> -- ... --device-machine <name>"))
        var deviceMachine: String?

        func run() async throws {
            let machineProfile = try DeviceRosterLoad.load(
                project: project, profile: profile, deviceMachine: deviceMachine,
                foreign: .notHandled,  // `devices up` は分散しない(api start-all-devices が分散する側)
                warn: { ConsoleOut.out($0) })

            // iOS はブート完了分をバッチで束ねてブリッジ供給する(bootAll 内。ブートと供給は並行)
            let repoRoot = noBridge ? nil : try RepoRoot.find()
            let outcomes = await DeviceBooter.bootAll(
                machine: machineProfile, repoRoot: repoRoot) { ConsoleOut.out($0) }
            let summary = DeviceBooter.BootOutcomeSummarizer.summarize(outcomes)
            // 1台も無い/全部成功は1行にまとめる。**全滅は exit 1**(1台以上あって0台成功。
            // 1台も起動できていないのに exit 0 で ✅ を出していたのが不具合1の実害)。
            // 部分失敗は exit 0 のまま(CLAUDE.md「1台の失敗で全体を落とさない」)だが必ず要約する
            if summary.failedNames.isEmpty {
                ConsoleOut.out("✅ Device start-up sequence complete")
            } else if summary.allFailed {
                ConsoleOut.out("❌ Device start-up failed: 0/\(summary.total) started"
                    + " — failed: \(summary.failedDescription)")
                throw ExitCode(1)
            } else {
                ConsoleOut.out("⚠️ Device start-up sequence complete: \(summary.succeededCount)/\(summary.total) started"
                    + " — failed: \(summary.failedDescription)")
            }
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop every bridge and shut down all simulators and emulators, on this machine and"
                + " on every machine in the remote registry (physical devices are never shut down, but"
                + " their bridges are always stopped too). With --profile, only the devices that profile"
                + " references are stopped individually, on this machine only (physical devices in scope"
                + " get their bridge stopped, but are never shut down). With --profile, exit code 1 if"
                + " every targeted device failed to stop; partial failures still exit 0 but are summarized.")

        @Option(help: "Test project name (only used with --profile; defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(help: "Run profile name (when given, only the devices that profile references are stopped individually; otherwise every bridge is stopped and all simulators and emulators are shut down)")
        var profile: String?

        @Option(name: .customLong("device-machine"), help: ArgumentHelp(
            "Operate on the devices that belong to this machine (a name registered with fleetest remote machines)."
            + " Default: the devices with no host (this machine). Used when a parent dispatches"
            + " to a runner: remote exec <name> -- ... --device-machine <name>"))
        var deviceMachine: String?

        @Flag(help: ArgumentHelp(
            "Stop even devices a fleetest run is currently using (kills that run's device access)."
            + " Without it, --profile skips the in-use devices, and the full sweep (no --profile)"
            + " is refused entirely while any run holds a device on this machine"))
        var force = false

        /// 全掃討の結果行。**読めなかったことを「止まった」と言わない**(一覧が読めないのに ✅ を出していた実害の修正)
        static func simulatorSweepLine(_ observation: SimulatorShutdownObservation) -> String {
            switch observation {
            case .stopped:
                return "✅ All simulators shut down"
            case .stillBooted:
                return "⚠️ Some simulators will not stop (check xcrun simctl list devices)"
            case .unreadable(let reason):
                return "⚠️ Could not confirm that the simulators shut down — the simulator list could not be"
                    + " read (\(reason)). Check xcrun simctl list devices"
            }
        }

        func run() async throws {
            if let profile {
                try await shutdownProfile(profile)
                return
            }

            // **掃討は台を選べないので、run が1本でも台を握っていれば丸ごと断る**(規律④)。
            // リモートへ投げる前に判定する = 断ったときはどの機械も触らない。
            // リモートの子も同じコマンドなので、ランナー機の上で同じ判定が走る
            if let refusal = DeviceBooter.sweepRefusal(
                force: force, leaseStateDir: nil, simulatorNames: DeviceBooter.simulatorNamesByUDID) {
                ConsoleOut.out("❌ \(refusal)")
                throw ExitCode(1)
            }

            // 手元だけ掃討しても**モニターに出ているリモートの台は残る**(「全て終了」を押しても
            // 消えない。実害)。監視と同じ集合(登録簿の全マシン)へ同じ掃討を投げる。
            // 子は `--device-machine local` で走るので入れ子にはならない
            async let fanout: Void = RemoteDeviceFanout.dispatchSweep(
                machines: RemoteDeviceFanout.sweepMachines(deviceMachine: deviceMachine),
                force: force,
                relay: { ConsoleOut.out($0) })

            if let root = try? RepoRoot.find() {
                // 実機ランナー(xcodebuild)も掃討対象 —— 「全て終了」は実機のブリッジも
                // 止める(ユーザー決定)。stopAll は ps を見て殺すだけで、実機の
                // 端末そのものには simctl/adb 相当のコマンドを一切撃たない
                let stopped = BridgeLauncher.stopAll(repoRoot: root, skipPhysical: false)
                if !stopped.isEmpty {
                    ConsoleOut.out("✅ Bridges stopped (port: \(stopped.joined(separator: ", ")))")
                }
            }
            // exit code でなくカタログの実状態で成否判定し、Booted が残れば再試行する
            // (DeviceBooter.shutdownOne と同じ理由: macOS 27 beta の 405 レース、および
            // 生き残ったセッションによる shutdown 中の再ブート)
            var observation = SimulatorShutdownObservation.stillBooted
            for attempt in 1...3 {
                _ = try? Shell.run(["xcrun", "simctl", "shutdown", "all"])
                observation = SimulatorCatalog.shutdownObservation(udid: nil)
                if observation == .stopped { break }
                if attempt < 3 {
                    ConsoleOut.out("→ Could not confirm that every simulator shut down yet — retrying (\(attempt)/3)...")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            ConsoleOut.out(Self.simulatorSweepLine(observation))
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
            // 実機のブリッジも掃討対象(ユーザー決定)。emu kill/pkill は撃たない ——
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

        /// 対象デバイスのみ ios→android の順で DeviceBooter.shutdownAll により個別停止する
        /// (ApiStopAllDevicesCommand と共通の実装)。**全部成功=✅・部分失敗=⚠️ 要約 exit 0・
        /// 全滅(1台以上あって0台成功)=❌ 要約 exit 1** の3分岐(Up.run と同じ形。「1台の失敗で
        /// 全体を落とさない」規律は部分失敗の側で保たれる)。実機の扱い(端末は落とさずブリッジ
        /// だけ止める)は shutdownAll 側の分岐に任せる —— 呼び出し側に実機の知識を持たせない
        private func shutdownProfile(_ profile: String) async throws {
            let filtered: DeviceRoster
            do {
                filtered = try DeviceRosterLoad.load(
                    project: project, profile: profile, deviceMachine: deviceMachine,
                    foreign: .notHandled,  // --profile 付きの掃討は手元だけ
                    warn: { ConsoleOut.out($0) })
            } catch {
                // プロファイル自体の読み込み失敗は1台も停止を試みていないので「全滅」とは区別し、
                // 警告に留めて exit 0 で帰る(下の3分岐とは別軸)
                ConsoleOut.out("⚠️ \(error.localizedDescription)")
                return
            }

            // iOS はシミュレータ停止前に稼働ブリッジも探して停止する(ゾンビ化防止)。repoRoot
            // 未検出時はブリッジ停止をスキップし simctl shutdown のみ行う(ApiStopAllDevicesCommand と同じ)
            let repoRoot = try? RepoRoot.find()
            let outcomes = await DeviceBooter.shutdownAll(
                machine: filtered, repoRoot: repoRoot, force: force, log: { ConsoleOut.out($0) })
            let summary = DeviceBooter.BootOutcomeSummarizer.summarize(outcomes)
            if summary.failedNames.isEmpty {
                ConsoleOut.out("✅ Device shutdown complete")
            } else if summary.allFailed {
                ConsoleOut.out("❌ Device shutdown failed: 0/\(summary.total) stopped"
                    + " — failed: \(summary.failedDescription)")
                throw ExitCode(1)
            } else {
                ConsoleOut.out("⚠️ Device shutdown complete: \(summary.succeededCount)/\(summary.total) stopped"
                    + " — failed: \(summary.failedDescription)")
            }
        }
    }
}

/// devices up/down・api start-all-devices 共通: プロジェクト/実行プロファイルから台帳を読み込む
/// (profile 指定時はそのプロファイルの enabled の台、無指定なら全実行プロファイルの和)。
enum DeviceRosterLoad {
    /// - deviceMachine: **どの機械のデバイスを扱うか**(nil/"local" = 手元)。リモート機で自分の
    ///   デバイスを起こすときに使う —— CLI には「自分が誰か」を知る手段が無いため、
    ///   呼び出し側(親)が明示する。例: `remote exec M1Max -- devices up --profile p --device-machine M1Max`
    /// **他の機械のデバイスを呼び出し側がどう扱うか**。既定値を置かない —— 分散する経路で
    /// 「その機械で起動してください」と案内すると、直後にツール自身が起動するので嘘になる
    /// (実害: 一括起動のログで、案内の 2 秒後に fan-out が同じ台を起動していた)
    enum ForeignDevices {
        /// 呼び出し側が RemoteDeviceFanout でその機械へ回す(api start-all-devices / stop-all-devices)
        case dispatchedByCaller
        /// 誰も扱わない = 本当に落とす(手元専用の経路)
        case notHandled
    }

    static func load(project: String?, profile: String?, deviceMachine: String? = nil,
                     foreign: ForeignDevices,
                     warn: (String) -> Void) throws -> DeviceRoster {
        try load(project: try ScenarioHost.project(named: project), profile: profile,
                 deviceMachine: deviceMachine,
                 registry: (LocalConfig.load().remoteHosts ?? []).map(\.machine),
                 foreign: foreign, warn: warn)
    }

    /// プロジェクトと登録簿を受け取る本体(テストが差し替えられるように分けてある)。
    static func load(project testProject: TestProject, profile: String?, deviceMachine: String?,
                     registry: [String], foreign: ForeignDevices,
                     warn: (String) -> Void) throws -> DeviceRoster {
        // **実行プロファイルを選んでいなければ台帳を1つに決めない** —— runs/ を全部畳み、
        // 手元 + リモート実行の登録簿にあるマシンの台を対象にする(監視 = ApiMonitorCommand・
        // 単体操作 = ApiDeviceOperation と同じ規律)。決められないという理由で操作を断らない:
        // 台帳が2つある案件では「(プロファイルなし)」のまま「デバイスを全て起動」を押しても
        // 即死し、**画面には何も起きない**(実害)
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
        let roster = try RunProfileScope.roster(project: testProject, runProfileName: profile)
        return keepingDevices(of: deviceMachine, in: roster, foreign: foreign, warn: warn)
    }

    /// **この機械が扱えるデバイスだけ**にする(既定は手元 = host 無し)。起動・停止は simctl/adb を
    /// 叩く操作なので、別の機械のデバイスはここからは扱えない —— 残すと「起動待機のまま
    /// 終わらないタイル」と、存在しない UDID への simctl boot(必ず失敗)を並べることになる
    /// (実害)。落とした分は必ず言う(黙って減らさない)。
    /// `deviceMachine` を渡すと、そのマシンのデバイスを**手元のものとして**扱う(上の doc 参照)
    static func keepingDevices(of deviceMachine: String?, in profile: DeviceRoster,
                               foreign: ForeignDevices,
                               warn: (String) -> Void) -> DeviceRoster {
        let wanted = MachineDispatch.normalize(deviceMachine)
        let entries = DeviceMachineGrouping.entries(roster: profile)
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
        return DeviceRoster(
            ios: ios.isEmpty ? nil : DeviceRosterList(devices: ios),
            android: android.isEmpty ? nil : DeviceRosterList(devices: android))
    }
}
