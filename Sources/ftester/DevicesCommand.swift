// DevicesCommand.swift
// マシンプロファイルに定義されたデバイス群の起動・停止 CLI。
//   ftester devices up   … 段階的起動(負荷ゲート付き・起動済みスキップ・iOS はブリッジ供給まで)
//   ftester devices down … 全ブリッジ停止+シミュレータ/エミュレータ全終了
// どちらも --profile(実行プロファイル名)指定時は、そのプロファイルが参照するデバイスのみを
// 対象にする(RunProfileScope.swift。省略時は従来どおりマシンプロファイルの全デバイス)。
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
            abstract: "全デバイスを段階的に起動する(負荷を見ながら最大2台同時。起動済みはスキップ。"
                + "--profile 指定時はそのプロファイルが参照するデバイスのみ)")

        @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
        var project: String?

        @Option(help: "実行プロファイル名(指定時はそのプロファイルが参照するデバイスのみ起動する。省略時はマシンプロファイルの全デバイス)")
        var profile: String?

        @Flag(name: .customLong("no-bridge"), help: "iOS ブリッジの供給を行わない")
        var noBridge = false

        func run() async throws {
            let testProject = try ScenarioHost.project(named: project)
            let machine = try ProfileResolver.determineMachine(
                project: testProject, registered: LocalConfig.currentMachineName())
            if machine.auto {
                print("→ マシンプロファイル自動採用: \(machine.name)")
            }
            let url = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
            var machineProfile = try JSONDecoder().decode(
                MachineProfile.self, from: Data(contentsOf: url))

            if let profile {
                machineProfile = try RunProfileScope.filteredMachineProfile(
                    project: testProject, machineName: machine.name, machineProfile: machineProfile,
                    runProfileName: profile, warn: { print($0) })
            }

            // iOS は起動直後にそのままブリッジ供給まで行う(1 台単位で完結)
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
            _ = try? Shell.run(["xcrun", "simctl", "shutdown", "all"])
            print("✅ シミュレータを全て終了しました")
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

        /// --profile 指定時: そのプロファイルが参照するデバイスのみを ios→android の順で
        /// `DeviceBooter.shutdownOne` により個別停止する(ApiDeviceDown と同じ流儀。iOS は
        /// repoRoot を渡してブリッジも停止する)。既存 Down の try? ベストエフォート方針に合わせ、
        /// マシン解決・プロファイル読み込み・個々のデバイス停止のいずれの失敗も警告に留めて続行し
        /// (1台の失敗で全体を止めない)、exit 0 で完走する。
        private func shutdownProfile(_ profile: String) async {
            do {
                let testProject = try ScenarioHost.project(named: project)
                let machine = try ProfileResolver.determineMachine(
                    project: testProject, registered: LocalConfig.currentMachineName())
                if machine.auto {
                    print("→ マシンプロファイル自動採用: \(machine.name)")
                }
                let url = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
                let machineProfile = try JSONDecoder().decode(
                    MachineProfile.self, from: Data(contentsOf: url))
                let filtered = try RunProfileScope.filteredMachineProfile(
                    project: testProject, machineName: machine.name, machineProfile: machineProfile,
                    runProfileName: profile, warn: { print($0) })

                // iOS はシミュレータ停止前に、接続している稼働ブリッジも探して停止する(ゾンビ化防止)。
                // repoRoot が見つからない場合(通常起こらない)はブリッジ停止をスキップして
                // simctl shutdown のみ行う(ApiDeviceDown と同じフォールバック)
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
