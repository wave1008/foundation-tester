// マシンプロファイルに定義されたデバイス群の起動・停止 CLI。
//   fleetest devices up   … 並行起動(最大2台同時・起動済みスキップ・iOS はブリッジ供給まで)
//   fleetest devices down … 全ブリッジ停止+シミュレータ/エミュレータ全終了
// どちらも --profile(実行プロファイル名)指定時は、そのプロファイルが参照するデバイスのみを
// 対象にする(RunProfileScope.swift。省略時はマシンプロファイルの全デバイス)。
// DeviceBooter / BridgeProvisioner を直接使う(fleetest api device-up/device-down と共通の実装)。

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
                + " With --profile, only the devices that profile references)")

        @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(help: "Run profile name (when given, only the devices that profile references are started; otherwise every device in the machine profile)")
        var profile: String?

        @Flag(name: .customLong("no-bridge"), help: "Do not provision the iOS bridge")
        var noBridge = false

        @Option(name: [.customLong("device-machine"), .customLong("device-host")], help: ArgumentHelp(
            "Operate on the devices that belong to this machine (registered host name)."
            + " Default: the devices with no host (this machine). Used when a parent dispatches"
            + " to a runner: remote exec <name> -- ... --device-host <name>"))
        var deviceHost: String?

        func run() async throws {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile, deviceHost: deviceHost,
                noteAutoMachine: { print($0) },
                warn: { print($0) })

            // iOS はブート完了分をバッチで束ねてブリッジ供給する(bootAll 内。ブートと供給は並行)
            let repoRoot = noBridge ? nil : try RepoRoot.find()
            await DeviceBooter.bootAll(machine: machineProfile, repoRoot: repoRoot) { print($0) }
            print("✅ Device start-up sequence complete")
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop every bridge and shut down all simulators and emulators (physical Android devices are"
                + " excluded). With --profile, only the devices that profile references are stopped individually)")

        @Option(help: "Test project name (only used with --profile; defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(help: "Run profile name (when given, only the devices that profile references are stopped individually; otherwise every bridge is stopped and all simulators and emulators are shut down)")
        var profile: String?

        @Option(name: [.customLong("device-machine"), .customLong("device-host")], help: ArgumentHelp(
            "Operate on the devices that belong to this machine (registered host name)."
            + " Default: the devices with no host (this machine). Used when a parent dispatches"
            + " to a runner: remote exec <name> -- ... --device-host <name>"))
        var deviceHost: String?

        func run() async throws {
            if let profile {
                await shutdownProfile(profile)
                return
            }

            if let root = try? RepoRoot.find() {
                let stopped = BridgeLauncher.stopAll(repoRoot: root)
                if !stopped.isEmpty {
                    print("✅ Bridges stopped (port: \(stopped.joined(separator: ", ")))")
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
                    print("→ Some simulators have not shut down yet — retrying (\(attempt)/3)...")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            if shutdownConfirmed {
                print("✅ All simulators shut down")
            } else {
                print("⚠️ Some simulators will not stop (check xcrun simctl list devices)")
            }
            // gRPC SHUTDOWN 優先(adb 経路死亡でも届く)・不可なら emu kill。
            // それでも offline には届かないため、残った qemu を最後に直接落とす
            if let adb = try? AndroidDriver.findADB(),
               let serials = try? AndroidDeviceCatalog.allEmulatorSerials() {
                for serial in serials {
                    if await !EmulatorControl.shutdown(serial: serial) {
                        _ = try? Shell.run([adb, "-s", serial, "emu", "kill"])
                    }
                    print("✅ Emulator shut down (\(serial))")
                }
                if !serials.isEmpty {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    _ = try? Shell.run(["pkill", "-9", "-f", "sdk/emulator/qemu"])
                }
            }
        }

        /// 対象デバイスのみ ios→android の順で shutdownOne により個別停止する(ApiDeviceDown と
        /// 同じ流儀)。マシン解決・読み込み・個々の停止いずれの失敗も警告に留めて続行し
        /// (1台の失敗で全体を止めない)、exit 0 で完走する
        private func shutdownProfile(_ profile: String) async {
            do {
                let filtered = try MachineProfileLoad.load(
                    project: project, profile: profile, deviceHost: deviceHost,
                    noteAutoMachine: { print($0) },
                    warn: { print($0) })

                // iOS はシミュレータ停止前に稼働ブリッジも探して停止する(ゾンビ化防止)。repoRoot
                // 未検出時はブリッジ停止をスキップし simctl shutdown のみ行う(ApiDeviceDown と同じ)
                let repoRoot = try? RepoRoot.find()
                for spec in filtered.ios?.devices ?? [] {
                    do {
                        try await DeviceBooter.shutdownOne(
                            spec: spec, platform: "ios", repoRoot: repoRoot, log: { print($0) })
                    } catch {
                        print("⚠️ \(spec.name): \(error.localizedDescription)")
                    }
                }
                for spec in filtered.android?.devices ?? [] {
                    do {
                        try await DeviceBooter.shutdownOne(
                            spec: spec, platform: "android", log: { print($0) })
                    } catch {
                        print("⚠️ \(spec.name): \(error.localizedDescription)")
                    }
                }
            } catch {
                print("⚠️ \(error.localizedDescription)")
            }
        }
    }
}

/// devices up/down・api devices-up 共通: プロジェクト/実行プロファイルからマシンプロファイルを
/// 解決して読み込む(profile 指定時はそのプロファイルが参照するデバイスのみに絞る)。
/// Up の従来コードをそのまま移した実装(ApiDeviceOperation の machineProfileNotFound ガードは
/// 意図的に取り込まない。ファイル未検出時は Data(contentsOf:) がそのまま throw する Up 従来挙動を維持)
enum MachineProfileLoad {
    /// - deviceHost: **どの機械のデバイスを扱うか**(nil/"local" = 手元)。リモート機で自分の
    ///   デバイスを起こすときに使う —— 転送されたマシンプロファイルにはそのデバイスの host
    ///   (= その機械の登録名)が書いてあり、CLI には「自分が誰か」を知る手段が無いため、
    ///   呼び出し側(親)が明示する。例: `remote exec M1Max -- devices up --profile p --device-host M1Max`
    static func load(project: String?, profile: String?, deviceHost: String? = nil,
                     noteAutoMachine: (String) -> Void,
                     warn: (String) -> Void) throws -> MachineProfile {
        let testProject = try ScenarioHost.project(named: project)
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

        if let profile {
            machineProfile = try RunProfileScope.filteredMachineProfile(
                project: testProject, machineName: machine.name, machineProfile: machineProfile,
                runProfileName: profile, warn: warn)
        }
        return keepingDevices(of: deviceHost, in: machineProfile, warn: warn)
    }

    /// **この機械が扱えるデバイスだけ**にする(既定は手元 = host 無し)。起動・停止は simctl/adb を
    /// 叩く操作なので、別の機械のデバイスはここからは扱えない —— 残すと「起動待機のまま
    /// 終わらないタイル」と、存在しない UDID への simctl boot(必ず失敗)を並べることになる
    /// (2026-08-17 の実害)。落とした分は必ず言う(黙って減らさない)。
    /// `deviceHost` を渡すと、そのホストのデバイスを**手元のものとして**扱う(上の doc 参照)
    static func keepingDevices(of deviceHost: String?, in profile: MachineProfile,
                               warn: (String) -> Void) -> MachineProfile {
        let wanted = MachineHostDispatch.normalize(deviceHost)
        let entries = DeviceHostGrouping.entries(machine: profile)
        let others = entries.filter { $0.host != wanted }
        guard !others.isEmpty else { return profile }

        for (host, devices) in DeviceHostGrouping.groups(others, host: { $0.host }) {
            let names = devices.map(\.name).joined(separator: ", ")
            let hostLabel = DeviceHostGrouping.display(host)
            warn("→ Skipping \(devices.count) device(s) on \(hostLabel): \(names)"
                + (host == nil
                   ? " (they are on this machine; drop --device-host to use them)"
                   : " (start them there: fleetest remote exec \(hostLabel)"
                     + " -- devices up --device-host \(hostLabel))"))
        }
        let kept = entries.filter { $0.host == wanted }
        let ios = kept.filter { $0.platform == "ios" }.map(\.spec)
        let android = kept.filter { $0.platform == "android" }.map(\.spec)
        return MachineProfile(
            machine: profile.machine,
            ios: ios.isEmpty ? nil : MachineDeviceList(devices: ios),
            android: android.isEmpty ? nil : MachineDeviceList(devices: android))
    }
}
