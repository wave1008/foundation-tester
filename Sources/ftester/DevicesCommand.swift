// DevicesCommand.swift
// マシンプロファイルに定義されたデバイス群の起動・停止 CLI。
//   ftester devices up   … 段階的起動(負荷ゲート付き・起動済みスキップ・iOS はブリッジ供給まで)
//   ftester devices down … 全ブリッジ停止+シミュレータ/エミュレータ全終了
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
            abstract: "全デバイスを段階的に起動する(負荷を見ながら最大2台同時。起動済みはスキップ)")

        @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
        var project: String?

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
            let profile = try JSONDecoder().decode(
                MachineProfile.self, from: Data(contentsOf: url))

            // iOS は起動直後にそのままブリッジ供給まで行う(1 台単位で完結)
            let repoRoot = noBridge ? nil : try RepoRoot.find()
            await DeviceBooter.bootAll(machine: profile, repoRoot: repoRoot) { print($0) }
            print("✅ デバイス起動シーケンス完了")
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "全ブリッジを停止し、シミュレータとエミュレータを全て終了する(Android 実機は対象外)")

        func run() async throws {
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
    }
}
