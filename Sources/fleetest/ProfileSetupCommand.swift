// fleetest profile setup
// アプリ/実行の2プロファイルを**1コマンドで整合させて**書く(デバイスの実体は実行プロファイルの devices)。
// エージェントに JSON を手書きさせると、指示していないプラットフォームの run が残る等の
// 不整合が実際に起きた。
// 書き込みロジックは FTCore.ProfileWriter に集約し、ここは引数の解決とファイル I/O だけ。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ProfileSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Create app and run profiles consistently (idempotent)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Target platform: ios / android / both")
    var platform: String

    @Option(help: "Device name (iOS simulator: the simulator's own name, as shown in Xcode; defaults to ios=simulator1 / android=emulator1)")
    var deviceName: String?

    @Option(help: "iOS: OS version (e.g. \"iOS 27.0\"; \"27.0\" is also accepted)")
    var os: String?

    @Option(help: "iOS: UDID of a simulator or physical device (takes precedence over the name)")
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

    @Option(help: "Path to a built .app/.apk/.apks (setting it enables autoInstall)")
    var appPath: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json; defaults to the platform name)")
    var run: String?

    @Flag(help: "Pick a device automatically (iOS: an existing simulator on the newest OS, excluding iPads / Android: the existing AVD with the highest API level)")
    var autoDevice = false

    func run() async throws {
        guard InitCommand.isValidAppID(appID) else {
            throw ValidationError("invalid --app-id: \(appID)"
                + " (bundle ID / package name: letters, digits, '.', '_' and '-' only)")
        }
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
        var devices: [[String: Any]] = []
        for target in platforms {
            devices.append(try await setUp(platform: target))
        }
        // 古い雛形が作った all.json はデバイスの実在を知らないまま残る。
        // 両方作ったときはここで揃える。**無ければ作らない** —— 今の雛形は all.json を置かない(ユーザー決定)
        if platforms.count > 1 {
            let testProject = try ScenarioHost.project(named: project)
            let allURL = testProject.runsDir.appendingPathComponent("all.json")
            if FileManager.default.fileExists(atPath: allURL.path) {
                var object = try readObject(allURL)
                object["app"] = appRef ?? testProject.name.lowercased()
                for device in devices {
                    object = try RunProfileDeviceEditor.upsertingDevice(inRunProfileObject: object, device: device)
                }
                try ProfileWriter.json(object).write(to: allURL, options: .atomic)
                let names = devices.compactMap { $0["name"] as? String }
                ConsoleOut.out("   Run:     profiles/runs/all.json … devices=[\(names.joined(separator: ", "))]")
            }
        }
    }

    /// 書いた devices[] の1要素を返す(all.json をまとめるのに使う)
    @discardableResult
    private func setUp(platform: String) async throws -> [String: Any] {
        let testProject = try ScenarioHost.project(named: project)
        var deviceName = self.deviceName ?? ProfileWriter.defaultDeviceName(platform: platform)
        let appRef = self.appRef ?? testProject.name.lowercased()
        let runName = run ?? platform
        let fm = FileManager.default
        var deviceDetail = ""

        var device = Self.deviceEntry(platform: platform, name: deviceName,
                                      osVersion: os, udid: udid, avd: avd, serial: serial)
        // 実体が1つも指定されていないときだけ自動選定する。**キー数では判定しない**
        // (platform/machine/name は常に入っている。ProfileWriter.hasDeviceBody の宣言を参照)
        if !ProfileWriter.hasDeviceBody(device), autoDevice {
            if platform == "ios" {
                let picked = try Self.pickSimulator()
                Self.stampSimulator(picked, model: SimulatorCatalog.modelNamesByUDID()[picked.udid],
                                    into: &device)
                ConsoleOut.out("   Auto-picked (ios): \(picked.name) / \(device["osVersion"] ?? "") / \(picked.udid)")
            } else {
                let picked = try Self.pickAVD()
                device["avd"] = picked
                ConsoleOut.out("   Auto-picked (android): \(picked)")
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
        // iOS シミュレータは name をシミュレータ自身の名前に揃え、機種名(model)を控える。
        // udid 指定ならその台、名前指定なら名前(+ os)で引く。見つからなければ下の登録済み検索へ落ちる
        if platform == "ios", device["kind"] == nil, udid != nil || self.deviceName != nil,
           let simulators = try? SimulatorCatalog.devices().filter({ !$0.physical }) {
            let match: SimDeviceInfo?
            if let udid {
                match = simulators.first { $0.udid == udid }
            } else {
                match = try? SimulatorCatalog.resolve(spec: DeviceSpec(name: deviceName, osVersion: os), in: simulators)
            }
            if let match {
                Self.stampSimulator(match, model: SimulatorCatalog.modelNamesByUDID()[match.udid],
                                    into: &device)
            }
        }
        deviceName = (device["name"] as? String) ?? deviceName

        // 実体の指定が無い場合は「他の実行プロファイルに登録済みの手元の台を使う」意味にする
        // (create-device が追記した直後など。無ければどう作ればよいか分からないのでエラー)
        if ProfileWriter.hasDeviceBody(device) {
            deviceDetail = "registered \(deviceName) (\(platform))"
        } else {
            let known = MachineInventory.loadAll(project: testProject) { _ in }
                .flatMap { DeviceMachineGrouping.entries(roster: $0) }
                .first { $0.platform == platform && $0.machine == nil && $0.name == deviceName }
            guard let known else {
                throw ValidationError(
                    "device \(deviceName) (\(platform)) is not in any run profile. "
                    + "Point at a concrete device (iOS: --simulator/--udid, Android: --avd/--serial), "
                    + "or create one first with fleetest api create-device")
            }
            device = Self.entryObject(platform: platform, spec: known.spec)
            deviceDetail = "\(deviceName) is already registered (copied as is)"
        }

        // ---- アプリプロファイル ----
        try fm.createDirectory(at: testProject.appsDir, withIntermediateDirectories: true)
        let appURL = testProject.appsDir.appendingPathComponent("\(appRef).json")
        let updatedApp = ProfileWriter.mergingAppProfile(
            into: try readObject(appURL), platform: platform,
            appName: appName ?? testProject.name, appID: appID, appPath: appPath)
        try ProfileWriter.json(updatedApp).write(to: appURL, options: .atomic)

        // ---- 実行プロファイル(デバイスの実体を持つ。既存なら app を揃えて台を upsert) ----
        try fm.createDirectory(at: testProject.runsDir, withIntermediateDirectories: true)
        let runURL = testProject.runsDir.appendingPathComponent("\(runName).json")
        let runObject: [String: Any]
        if fm.fileExists(atPath: runURL.path) {
            var existing = try readObject(runURL)
            existing["app"] = appRef
            runObject = try RunProfileDeviceEditor.upsertingDevice(inRunProfileObject: existing, device: device)
        } else {
            runObject = ProfileWriter.runProfile(appRef: appRef, devices: [device])
        }
        try ProfileWriter.json(runObject).write(to: runURL, options: .atomic)

        ConsoleOut.out("✅ Created the profiles (project \(testProject.name))")
        ConsoleOut.out("   App:     profiles/apps/\(appRef).json … \(appID)")
        ConsoleOut.out("   Run:     profiles/runs/\(runName).json … app=\(appRef) / \(deviceDetail)")

        // 検証ゲート: 書いた実行プロファイルが実際に解決できることまで確認する
        let resolved = try ProfileResolver.resolve(project: testProject, runName: runName)
        for warning in resolved.warnings {
            ConsoleOut.out("⚠️ \(warning)")
        }
        let devices = resolved.devices.map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
        ConsoleOut.out("   Resolved: \(resolved.appName) / \(devices)")
        ConsoleOut.out("   To run: fleetest run --project \(testProject.name) --profile \(runName)")
        return device
    }

    /// 実行プロファイルの devices[] へ書く1件を組み立てる(I/O 無し。自動選定と kind の判定は呼び出し側)。
    /// machine は必ず書く(手元なら "local")
    static func deviceEntry(platform: String, name: String, osVersion: String?,
                            udid: String?, avd: String?, serial: String?) -> [String: Any] {
        var device: [String: Any] = [
            "platform": platform, "machine": DeviceMachineGrouping.localDisplayName, "name": name,
        ]
        if platform == "ios" {
            if let osVersion {
                device["osVersion"] = osVersion.hasPrefix("iOS") ? osVersion : "iOS \(osVersion)"
            }
            if let udid { device["udid"] = udid }
        } else {
            if let avd { device["avd"] = avd }
            if let serial { device["serial"] = serial }
        }
        return device
    }

    /// シミュレータの実体を1件へ書き込む(name = シミュレータの名前・osVersion・udid・model)。
    /// osVersion は Xcode の OS Version と同じ表記("iOS 27.0")= SimDeviceInfo.os をそのまま書く
    static func stampSimulator(_ simulator: SimDeviceInfo, model: String?, into device: inout [String: Any]) {
        device["name"] = simulator.name
        device["osVersion"] = simulator.os
        device["udid"] = simulator.udid
        if let model { device["model"] = model }
    }

    /// 登録済みの台(spec)を devices[] の1要素へ戻す(手元の台だけを渡すこと)
    static func entryObject(platform: String, spec: DeviceSpec) -> [String: Any] {
        var object: [String: Any] = [
            "platform": platform, "machine": DeviceMachineGrouping.localDisplayName, "name": spec.name,
        ]
        if let kind = spec.kind { object["kind"] = kind.rawValue }
        if let osVersion = spec.osVersion { object["osVersion"] = osVersion }
        if let udid = spec.udid { object["udid"] = udid }
        if let port = spec.port { object["port"] = Int(port) }
        if let engine = spec.engine { object["engine"] = engine }
        if let avd = spec.avd { object["avd"] = avd }
        if let serial = spec.serial { object["serial"] = serial }
        if let model = spec.model { object["model"] = model }
        return object
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
                + " (install a runtime/device via Xcode, or create one with fleetest api create-device)")
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
                + " (create one in Android Studio, or with fleetest api create-device)")
        }
        return picked
    }
}
