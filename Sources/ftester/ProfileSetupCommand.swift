// ftester profile setup
// マシン/アプリ/実行の3プロファイルを**1コマンドで整合させて**書く。
// エージェントに JSON を手書きさせると、machines の device 名と runs の参照名がずれる・
// 指示していないプラットフォームの run が残る、という不整合が実際に起きた(2026-07-29)。
// 書き込みロジックは FTCore.ProfileWriter に集約し、ここは引数の解決とファイル I/O だけ。

import ArgumentParser
import Foundation
import FTCore

struct ProfileSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "マシン/アプリ/実行プロファイルを整合させて作成する(冪等)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "対象プラットフォーム: ios / android")
    var platform: String

    @Option(help: "マシンプロファイル名(省略時: 登録名 → machines/ が 1 つならそれ)")
    var machine: String?

    @Option(help: "デバイスの論理名(省略時: ios=simulator1 / android=emulator1)")
    var deviceName: String?

    @Option(help: "iOS: シミュレータの機種名(例 \"iPhone 17 Pro\")")
    var simulator: String?

    @Option(help: "iOS: OS バージョン(例 27.0)")
    var os: String?

    @Option(help: "iOS: シミュレータ/実機の UDID(指定すると機種名より優先される)")
    var udid: String?

    @Option(help: "Android: AVD ID")
    var avd: String?

    @Option(help: "Android: 実機のシリアル(adb devices の左列)")
    var serial: String?

    @Option(help: "アプリプロファイル名(profiles/apps/<ref>.json。省略時: プロジェクト名の小文字)")
    var appRef: String?

    @Option(help: "アプリの表示名(省略時: プロジェクト名)")
    var appName: String?

    @Option(name: .customLong("app-id"), help: "アプリの bundle ID / パッケージ名")
    var appID: String

    @Option(help: "ビルド済み .app/.apk のパス(指定すると autoInstall が有効になる)")
    var appPath: String?

    @Option(help: "実行プロファイル名(profiles/runs/<名>.json。省略時: プラットフォーム名)")
    var run: String?

    func run() async throws {
        guard platform == "ios" || platform == "android" else {
            throw ValidationError("--platform は ios / android のいずれかです: \(platform)")
        }
        let testProject = try ScenarioHost.project(named: project)
        let machineName = try resolveMachineName(project: testProject)
        let deviceName = self.deviceName ?? ProfileWriter.defaultDeviceName(platform: platform)
        let appRef = self.appRef ?? testProject.name.lowercased()
        let runName = run ?? platform
        let fm = FileManager.default
        var machineDetail = ""

        // ---- マシンプロファイル(デバイスの実体) ----
        // 実体の指定が無い場合は「既に登録済みのデバイスを使う」意味にする
        // (create-device が追記した直後など。無ければどう作ればよいか分からないのでエラー)
        try fm.createDirectory(at: testProject.machinesDir, withIntermediateDirectories: true)
        let machineURL = testProject.machinesDir.appendingPathComponent("\(machineName).json")
        let machineObject = try readObject(machineURL)

        var device: [String: Any] = ["name": deviceName]
        if platform == "ios" {
            if let simulator { device["simulator"] = simulator }
            if let os { device["os"] = os }
            if let udid { device["udid"] = udid }
        } else {
            if let avd { device["avd"] = avd }
            if let serial { device["serial"] = serial }
        }
        if serial != nil || (platform == "ios" && udid != nil && simulator == nil) {
            device["kind"] = "physical"
        }

        if device.count > 1 {
            let updatedMachine = try ProfileWriter.upsertingDevice(
                inProfileObject: machineObject, platform: platform, device: device)
            try ProfileWriter.json(updatedMachine).write(to: machineURL, options: .atomic)
            machineDetail = "\(platform) に \(deviceName) を登録"
        } else {
            guard MachineProfileEditor.deviceNames(inProfileObject: machineObject)
                .contains(deviceName) else {
                throw ValidationError(
                    "デバイス \(deviceName) が machines/\(machineName).json にありません。"
                    + "実体を指定する(iOS: --simulator/--udid, Android: --avd/--serial)か、"
                    + "先に ftester api create-device で作成してください")
            }
            machineDetail = "\(deviceName) は登録済み(変更なし)"
        }

        // ---- アプリプロファイル ----
        try fm.createDirectory(at: testProject.appsDir, withIntermediateDirectories: true)
        let appURL = testProject.appsDir.appendingPathComponent("\(appRef).json")
        let updatedApp = ProfileWriter.mergingAppProfile(
            into: try readObject(appURL), platform: platform,
            appName: appName ?? testProject.name, appID: appID, appPath: appPath)
        try ProfileWriter.json(updatedApp).write(to: appURL, options: .atomic)

        // ---- 実行プロファイル(マシン側の論理名をそのまま参照する) ----
        try fm.createDirectory(at: testProject.runsDir, withIntermediateDirectories: true)
        let runURL = testProject.runsDir.appendingPathComponent("\(runName).json")
        try ProfileWriter.json(ProfileWriter.runProfile(appRef: appRef, deviceNames: [deviceName]))
            .write(to: runURL, options: .atomic)

        print("✅ プロファイルを作成しました(プロジェクト \(testProject.name))")
        print("   マシン: profiles/machines/\(machineName).json … \(machineDetail)")
        print("   アプリ: profiles/apps/\(appRef).json … \(appID)")
        print("   実行:   profiles/runs/\(runName).json … app=\(appRef) devices=[\(deviceName)]")

        // 検証ゲート: 書いた実行プロファイルが実際に解決できることまで確認する
        let resolved = try ProfileResolver.resolve(
            project: testProject, runName: runName, machineName: machineName)
        for warning in resolved.warnings {
            print("⚠️ \(warning)")
        }
        let devices = resolved.devices.map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
        print("   解決: \(resolved.appName) @ \(machineName) / \(devices)")
        print("   実行するには: ftester run --project \(testProject.name) --profile \(runName)")
    }

    private func readObject(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ValidationError("JSON として解析できません(手で直してから再実行してください): \(url.path)")
        }
        return object
    }

    private func resolveMachineName(project: TestProject) throws -> String {
        if let machine, !machine.isEmpty { return machine }
        // machines/ が空の初回は登録名(ftester machine set)を使う。それも無ければ聞く側の責務
        if let registered = LocalConfig.currentMachineName(), !registered.isEmpty {
            return registered
        }
        return try ProfileResolver.determineMachine(project: project, registered: nil).name
    }
}
