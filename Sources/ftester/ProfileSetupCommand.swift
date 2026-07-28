// ftester profile setup
// マシン/アプリ/実行の3プロファイルを**1コマンドで整合させて**書く。
// エージェントに JSON を手書きさせると、machines の device 名と runs の参照名がずれる・
// 指示していないプラットフォームの run が残る、という不整合が実際に起きた(2026-07-29)。
// 書き込みロジックは FTCore.ProfileWriter に集約し、ここは引数の解決とファイル I/O だけ。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ProfileSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "マシン/アプリ/実行プロファイルを整合させて作成する(冪等)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "対象プラットフォーム: ios / android / both")
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

    @Flag(help: "デバイスを自動で選ぶ(iOS: 最新 OS の既存シミュレータ / Android: API が最も高い既存 AVD)")
    var autoDevice = false

    func run() async throws {
        let platforms: [String]
        switch platform {
        case "both":
            platforms = ["ios", "android"]
            // 同じ名前を両プラットフォームに使うと、後の1回が前の1回を上書き/重複エラーになる
            if run != nil {
                throw ValidationError("--platform both と --run は併用できません"
                    + "(実行プロファイル名がプラットフォームごとに要ります)")
            }
            if deviceName != nil {
                throw ValidationError("--platform both と --device-name は併用できません"
                    + "(論理名は ios/android 横断で一意にする必要があります)")
            }
        case "ios", "android": platforms = [platform]
        default: throw ValidationError("--platform は ios / android / both のいずれかです: \(platform)")
        }
        // 1回の呼び出しで両方作れるようにする(承認回数を減らすため。値は各プラットフォームで解決)
        var deviceNames: [String] = []
        for target in platforms {
            deviceNames.append(try await setUp(platform: target))
        }
        // scaffold が作る all.json は machine もデバイスの実在も知らないまま残る。
        // 両方作ったときはここで揃える(拡張の編集画面で「(未指定)」にならないように)
        if platforms.count > 1 {
            let testProject = try ScenarioHost.project(named: project)
            let allURL = testProject.runsDir.appendingPathComponent("all.json")
            if FileManager.default.fileExists(atPath: allURL.path) {
                let machineName = try resolveMachineName(project: testProject)
                try ProfileWriter.json(ProfileWriter.runProfile(
                    appRef: appRef ?? testProject.name.lowercased(),
                    deviceNames: deviceNames, machine: machineName))
                    .write(to: allURL, options: .atomic)
                print("   実行:   profiles/runs/all.json … devices=[\(deviceNames.joined(separator: ", "))]")
            }
        }
    }

    /// 作成/更新したデバイスの論理名を返す(all.json をまとめるのに使う)
    @discardableResult
    private func setUp(platform: String) async throws -> String {
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
            if device.count == 1, autoDevice {
                let picked = try Self.pickSimulator()
                device["simulator"] = picked.name
                device["os"] = picked.os
                device["udid"] = picked.udid
                print("   自動選択(ios): \(picked.name) / \(picked.os) / \(picked.udid)")
            }
        } else {
            if let avd { device["avd"] = avd }
            if let serial { device["serial"] = serial }
            if device.count == 1, autoDevice {
                let picked = try Self.pickAVD()
                device["avd"] = picked
                print("   自動選択(android): \(picked)")
            }
        }
        // 実機判定を誤ると実機向けの準備処理が走って run が壊れる。iOS はカタログ上の
        // physical フラグ、Android は serial の形(emulator-XXXX はエミュレータ)で決める
        if platform == "ios", let udid,
           let known = try? SimulatorCatalog.devices().first(where: { $0.udid == udid }),
           known.physical {
            device["kind"] = "physical"
        }
        if platform == "android", let serial, DevicePicker.isPhysicalAndroidSerial(serial) {
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
        try ProfileWriter.json(ProfileWriter.runProfile(
            appRef: appRef, deviceNames: [deviceName], machine: machineName))
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
        return deviceName
    }

    private func readObject(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ValidationError("JSON として解析できません(手で直してから再実行してください): \(url.path)")
        }
        return object
    }

    /// 既存シミュレータから1台選ぶ。SimulatorCatalog は 起動中 → OS 降順 → 名前順 なので、
    /// 最新 OS の中で "Pro" を優先する(無ければ先頭)。作成はしない(重い・失敗理由が増える)
    static func pickSimulator() throws -> SimDeviceInfo {
        let simulators = try SimulatorCatalog.devices().filter { !$0.physical }
        guard let index = DevicePicker.pickSimulatorIndex(
            simulators.map { (name: $0.name, os: $0.os) }) else {
            throw ValidationError("利用できるシミュレータがありません"
                + "(Xcode で runtime/デバイスを導入するか ftester api create-device で作成してください)")
        }
        return simulators[index]
    }

    /// 既存 AVD から1台選ぶ。config.ini の image.sysdir.1 に含まれる API レベルが最大のもの
    /// (名前の見た目では新旧を判定できない。同点なら名前順で決定的に)
    static func pickAVD() throws -> String {
        let binary = try DeviceBooter.findEmulatorBinary()
        let result = try Shell.run([binary, "-list-avds"])
        let avds = result.output.split(separator: "\n").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = avds.map { avd -> (name: String, apiLevel: Int) in
            let config = home.appendingPathComponent(".android/avd/\(avd).avd/config.ini")
            let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
            return (avd, DevicePicker.apiLevel(fromConfigINI: text))
        }
        guard let picked = DevicePicker.pickAVD(candidates) else {
            throw ValidationError("利用できる AVD がありません"
                + "(Android Studio で作成するか ftester api create-device で作成してください)")
        }
        return picked
    }

    private func resolveMachineName(project: TestProject) throws -> String {
        if let machine, !machine.isEmpty {
            // 未登録なら同時に登録する(別途 ftester machine set を打たせない)
            if LocalConfig.currentMachineName()?.isEmpty ?? true {
                var config = LocalConfig.load()
                config.machineName = machine
                try config.save()
                print("   マシン名を登録しました: \(machine)(~/.config/ftester/config.json)")
            }
            return machine
        }
        // machines/ が空の初回は登録名(ftester machine set)を使う。それも無ければ聞く側の責務
        if let registered = LocalConfig.currentMachineName(), !registered.isEmpty {
            return registered
        }
        return try ProfileResolver.determineMachine(project: project, registered: nil).name
    }
}
