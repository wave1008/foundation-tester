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
        abstract: "Create machine, app and run profiles consistently (idempotent)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Target platform: ios / android / both")
    var platform: String

    @Option(help: "Machine profile name (defaults to the registered name, or the only entry in machines/)")
    var machine: String?

    @Option(help: "Logical device name (defaults to ios=simulator1 / android=emulator1)")
    var deviceName: String?

    @Option(help: "iOS: simulator model name (e.g. \"iPhone 17 Pro\")")
    var simulator: String?

    @Option(help: "iOS: OS version (e.g. 27.0)")
    var os: String?

    @Option(help: "iOS: UDID of a simulator or physical device (takes precedence over the model name)")
    var udid: String?

    @Option(help: "Android: AVD ID")
    var avd: String?

    @Option(help: "Android: serial of a physical device (the left column of adb devices)")
    var serial: String?

    @Option(help: "App profile name (profiles/apps/<ref>.json; defaults to the lowercased project name)")
    var appRef: String?

    @Option(help: "Display name of the app (defaults to the project name)")
    var appName: String?

    @Option(name: .customLong("app-id"), help: "App bundle ID / package name")
    var appID: String

    @Option(help: "Path to a built .app/.apk (setting it enables autoInstall)")
    var appPath: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json; defaults to the platform name)")
    var run: String?

    @Flag(help: "Pick a device automatically (iOS: an existing simulator on the newest OS, excluding iPads / Android: the existing AVD with the highest API level)")
    var autoDevice = false

    func run() async throws {
        let platforms: [String]
        switch platform {
        case "both":
            platforms = ["ios", "android"]
            // 同じ名前を両プラットフォームに使うと、後の1回が前の1回を上書き/重複エラーになる
            if run != nil {
                throw ValidationError("--platform both cannot be combined with --run"
                    + " (each platform needs its own run profile name)")
            }
            if deviceName != nil {
                throw ValidationError("--platform both cannot be combined with --device-name"
                    + " (logical names must be unique across ios and android)")
            }
        case "ios", "android": platforms = [platform]
        default: throw ValidationError("--platform must be one of ios / android / both: \(platform)")
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
                print("   Run:     profiles/runs/all.json … devices=[\(deviceNames.joined(separator: ", "))]")
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

        var device = Self.deviceEntry(platform: platform, name: deviceName,
                                      simulator: simulator, os: os, udid: udid,
                                      avd: avd, serial: serial)
        // 実体が1つも指定されていないときだけ自動選定する。**キー数では判定しない**
        // (host/name は常に入っている。ProfileWriter.hasDeviceBody の宣言を参照)
        if !ProfileWriter.hasDeviceBody(device), autoDevice {
            if platform == "ios" {
                let picked = try Self.pickSimulator()
                device["simulator"] = picked.name
                // プロファイルの os は接頭辞なし("27.0")が規約。SimDeviceInfo.os は "iOS 27.0"
                // 形式なので剥がして書く(表示側とリゾルバが "iOS " を付けるため、
                // そのまま書くと「iOS iOS 27.0」と二重表示になる。2026-08-19 の実害)
                let os = ApiInstalledDevicesCommand.normalizeOS(picked.os)
                device["os"] = os
                device["udid"] = picked.udid
                print("   Auto-picked (ios): \(picked.name) / \(os) / \(picked.udid)")
            } else {
                let picked = try Self.pickAVD()
                device["avd"] = picked
                print("   Auto-picked (android): \(picked)")
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

        if ProfileWriter.hasDeviceBody(device) {
            let updatedMachine = try ProfileWriter.upsertingDevice(
                inProfileObject: machineObject, platform: platform, device: device)
            try ProfileWriter.json(updatedMachine).write(to: machineURL, options: .atomic)
            machineDetail = "registered \(deviceName) under \(platform)"
        } else {
            guard MachineProfileEditor.deviceNames(inProfileObject: machineObject)
                .contains(deviceName) else {
                throw ValidationError(
                    "device \(deviceName) is not in machines/\(machineName).json. "
                    + "Point at a concrete device (iOS: --simulator/--udid, Android: --avd/--serial), "
                    + "or create one first with ftester api create-device")
            }
            machineDetail = "\(deviceName) is already registered (unchanged)"
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

        print("✅ Created the profiles (project \(testProject.name))")
        print("   Machine: profiles/machines/\(machineName).json … \(machineDetail)")
        print("   App:     profiles/apps/\(appRef).json … \(appID)")
        print("   Run:     profiles/runs/\(runName).json … app=\(appRef) devices=[\(deviceName)]")

        // 検証ゲート: 書いた実行プロファイルが実際に解決できることまで確認する
        let resolved = try ProfileResolver.resolve(
            project: testProject, runName: runName, machineName: machineName)
        for warning in resolved.warnings {
            print("⚠️ \(warning)")
        }
        let devices = resolved.devices.map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
        print("   Resolved: \(resolved.appName) @ \(machineName) / \(devices)")
        print("   To run: ftester run --project \(testProject.name) --profile \(runName)")
        return deviceName
    }

    /// マシンプロファイルへ書く1件を組み立てる(I/O 無し。自動選定と kind の判定は呼び出し側)。
    /// host は必ず書く(手元なら "local"。省略はプロファイル直下の既定を継ぐ意味になり、
    /// 既定がリモートのプロファイルでは手元のデバイスが別の機械のもの扱いになる)
    static func deviceEntry(platform: String, name: String, simulator: String?, os: String?,
                            udid: String?, avd: String?, serial: String?) -> [String: Any] {
        var device: [String: Any] = [
            "host": DeviceHostGrouping.localDisplayName, "name": name,
        ]
        if platform == "ios" {
            if let simulator { device["simulator"] = simulator }
            if let os { device["os"] = os }
            if let udid { device["udid"] = udid }
        } else {
            if let avd { device["avd"] = avd }
            if let serial { device["serial"] = serial }
        }
        return device
    }

    private func readObject(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ValidationError("cannot parse as JSON (fix it by hand and run again): \(url.path)")
        }
        return object
    }

    /// 既存シミュレータから1台選ぶ。SimulatorCatalog は 起動中 → OS 降順 → 名前順 なので、
    /// 最新 OS の中で "Pro" を優先する(無ければ先頭)。**iPad は自動選定の対象外**。
    /// 作成はしない(重い・失敗理由が増える)
    static func pickSimulator() throws -> SimDeviceInfo {
        let simulators = try SimulatorCatalog.devices().filter { !$0.physical }
        guard let index = DevicePicker.pickSimulatorIndex(
            simulators.map { (name: $0.name, os: $0.os) }) else {
            if simulators.contains(where: { DevicePicker.isIPad(name: $0.name) }) {
                throw ValidationError("no simulator is eligible for auto-selection"
                    + " (iPads are excluded). Install an iPhone simulator, "
                    + "or specify one explicitly with --simulator/--udid")
            }
            throw ValidationError("no simulators available"
                + " (install a runtime/device via Xcode, or create one with ftester api create-device)")
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
            throw ValidationError("no AVDs available"
                + " (create one in Android Studio, or with ftester api create-device)")
        }
        return picked
    }

    /// --machine が指定されていればそれ。無ければ通常の決定規則(実行プロファイルの machine >
    /// FT_MACHINE > machines/ が1つ)。**「この Mac の登録名」は見ない**(2026-08-17 に廃止。
    /// 理由は ProfileResolver.determineMachine の宣言)
    private func resolveMachineName(project: TestProject) throws -> String {
        if let machine, !machine.isEmpty {
            return machine
        }
        return try ProfileResolver.determineMachine(project: project).name
    }
}
