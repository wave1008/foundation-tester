// マシンプロファイルに定義されたデバイス群の起動・停止 CLI。
//   ftester devices up   … 並行起動(最大2台同時・起動済みスキップ・iOS はブリッジ供給まで)
//   ftester devices down … 全ブリッジ停止+シミュレータ/エミュレータ全終了
// どちらも --profile(実行プロファイル名)指定時は、そのプロファイルが参照するデバイスのみを
// 対象にする(RunProfileScope.swift。省略時はマシンプロファイルの全デバイス)。
// DeviceBooter / BridgeProvisioner を直接使う(ftester api device-up/device-down と共通の実装)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct DevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "マシンプロファイルのデバイス群の起動・停止",
        subcommands: [Up.self, Down.self])

    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "全デバイスを起動する(最大2台同時。起動済みはスキップ。"
                + "--profile 指定時はそのプロファイルが参照するデバイスのみ)")

        @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
        var project: String?

        @Option(help: "実行プロファイル名(指定時はそのプロファイルが参照するデバイスのみ起動する。省略時はマシンプロファイルの全デバイス)")
        var profile: String?

        @Flag(name: .customLong("no-bridge"), help: "iOS ブリッジの供給を行わない")
        var noBridge = false

        func run() async throws {
            let machineProfile = try MachineProfileLoad.load(
                project: project, profile: profile,
                noteAutoMachine: { print($0) },
                warn: { print($0) })

            // iOS はブート完了分をバッチで束ねてブリッジ供給する(bootAll 内。ブートと供給は並行)
            let repoRoot = noBridge ? nil : try RepoRoot.find()
            await DeviceBooter.bootAll(machine: machineProfile, repoRoot: repoRoot) { print($0) }
            print("✅ デバイス起動シーケンス完了")
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "全ブリッジを停止し、シミュレータとエミュレータを全て終了する(Android 実機は対象外。"
                + "--profile 指定時はそのプロファイルが参照するデバイスのみを個別に停止する)")

        @Option(help: "テストプロジェクト名(--profile 指定時のみ使用。省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
        var project: String?

        @Option(help: "実行プロファイル名(指定時はそのプロファイルが参照するデバイスのみを個別に停止する。省略時は従来どおり全ブリッジ停止+シミュレータ全終了+全エミュレータ終了)")
        var profile: String?

        func run() async throws {
            if let profile {
                await shutdownProfile(profile)
                return
            }

            if let root = try? RepoRoot.find() {
                let stopped = BridgeLauncher.stopAll(repoRoot: root)
                if !stopped.isEmpty {
                    print("✅ ブリッジ停止(port: \(stopped.joined(separator: ", ")))")
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
                    print("→ 停止が反映されないシミュレータがあるため再試行(\(attempt)/3)...")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            if shutdownConfirmed {
                print("✅ シミュレータを全て終了しました")
            } else {
                print("⚠️ 一部のシミュレータが停止しません(xcrun simctl list devices で確認してください)")
            }
            // offline のエミュレータには emu kill が届かないため、残った qemu を直接落とす
            if let adb = try? AndroidDriver.findADB(),
               let serials = try? AndroidDeviceCatalog.allEmulatorSerials() {
                for serial in serials {
                    _ = try? Shell.run([adb, "-s", serial, "emu", "kill"])
                    print("✅ エミュレータを終了しました(\(serial))")
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
                    project: project, profile: profile,
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
    static func load(project: String?, profile: String?,
                     noteAutoMachine: (String) -> Void,
                     warn: (String) -> Void) throws -> MachineProfile {
        let testProject = try ScenarioHost.project(named: project)
        // --profile の machine 明示指定を最優先(ProfileResolver.resolve() と同じ優先順位)
        let machine = try ProfileResolver.determineMachine(
            project: testProject, registered: LocalConfig.currentMachineName(),
            runProfileName: profile)
        if machine.auto {
            noteAutoMachine("→ マシンプロファイル自動採用: \(machine.name)")
        }
        let url = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
        var machineProfile = try JSONDecoder().decode(
            MachineProfile.self, from: Data(contentsOf: url))

        if let profile {
            machineProfile = try RunProfileScope.filteredMachineProfile(
                project: testProject, machineName: machine.name, machineProfile: machineProfile,
                runProfileName: profile, warn: warn)
        }
        return machineProfile
    }
}
