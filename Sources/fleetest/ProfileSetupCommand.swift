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

    @Option(help: "Target platform: ios / android / hybrid (both). Written to the app profile's platform; adding the other OS to an existing app profile makes it hybrid")
    var platform: String

    @Option(help: "Device name (iOS simulator: the simulator's own name, as shown in Xcode). With --auto-device it defaults to \"<model>(<OS>)-NN\" (e.g. \"iPhone 17 Pro(iOS 27.0)-01\"); with --avd it defaults to the AVD's display name")
    var deviceName: String?

    @Option(help: "iOS: OS version (e.g. \"iOS 27.0\"; \"27.0\" is also accepted)")
    var os: String?

    @Option(help: "iOS: UDID of a simulator or physical device (takes precedence over the name)")
    var udid: String?

    @Option(help: "Android: AVD ID")
    var avd: String?

    @Option(help: "Android: serial of a physical device (the left column of adb devices)")
    var serial: String?

    @Option(help: "App profile name (profiles/apps/<ref>.json; omitted: the one the run profile already uses, else the --platform value: ios / android / hybrid)")
    var appRef: String?

    @Option(help: "Display name of the app (omitted: keeps the existing one, else the project name)")
    var appName: String?

    @Option(name: .customLong("app-id"), help: "App bundle ID / package name")
    var appID: String

    @Option(help: "Path to a built .app/.apk/.apks (setting it enables autoInstall; omitted: keeps the existing one)")
    var appPath: String?

    @Option(help: "Run profile name (profiles/runs/<name>.json; defaults to the platform name)")
    var run: String?

    @Flag(help: ArgumentHelp("Pick a device automatically (iOS: the newest runtime of the selected Xcode (installed with xcodebuild -downloadPlatform iOS when missing: several GB, can take a long time) and the newest plain iPhone <N> (no Pro/Plus/Air/e/mini/SE variants) that it supports / Android: the newest Pixel phone model (pixel_<number> or pixel_<number>a; the plain one wins a tie; Pro/Fold variants are excluded) with the newest google_apis system image for this Mac's ABI, installed or downloadable)."
        + " Registers \"<model>(<OS>)-NN\": reuses the lowest-numbered one whose model and runtime/system image also match, else creates one with the lowest unused number."
        + " The OS label is the runtime name (iOS) or \"Android 16, API 36, APIs\" (\"..., Play\" for Play Store images). Your own simulators/AVDs are never renamed or deleted."
        + " An Android system image that is not installed needs --accept-licenses"))
    var autoDevice = false

    @Flag(name: .customLong("accept-licenses"), help: ArgumentHelp(
        "Accept the Android SDK license(s) of the system image that --auto-device has to download."
        + " Without it the command refuses and installs nothing. The caller must ask the person first;"
        + " this CLI never accepts licenses on its own"))
    var acceptLicenses = false

    func run() async throws {
        guard InitCommand.isValidAppID(appID) else {
            throw ValidationError("invalid --app-id: \(appID)"
                + " (bundle ID / package name: letters, digits, '.', '_' and '-' only)")
        }
        let platforms: [String]
        switch platform {
        case "hybrid":
            platforms = ["ios", "android"]
            // 同じ名前を両プラットフォームに使うと、後の1回が前の1回を上書き/重複エラーになる
            if run != nil {
                throw ValidationError("--platform hybrid cannot be combined with --run"
                    + " (each platform needs its own run profile name)")
            }
            if deviceName != nil {
                throw ValidationError("--platform hybrid cannot be combined with --device-name"
                    + " (logical names must be unique across ios and android)")
            }
        case "ios", "android": platforms = [platform]
        default: throw ValidationError("--platform must be one of ios / android / hybrid: \(platform)")
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
                object["app"] = appRef ?? platform
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
        let explicitName = self.deviceName
        // 名前未定は ""(実体の判定 hasDeviceBody は name を見ない)。下の確定後に空なら ValidationError
        var deviceName = explicitName ?? ""
        let runName = run ?? platform
        let fm = FileManager.default
        let appRef = ProfileWriter.resolvedAppRef(
            explicit: self.appRef,
            existingRunProfile: try readObject(testProject.runsDir.appendingPathComponent("\(runName).json")),
            platform: self.platform)
        var deviceDetail = ""

        var device = Self.deviceEntry(platform: platform, name: deviceName,
                                      osVersion: os, udid: udid, avd: avd, serial: serial)
        // 実体が1つも指定されていないときだけ自動選定する。**キー数では判定しない**
        // (platform/machine/name は常に入っている。ProfileWriter.hasDeviceBody の宣言を参照)
        var autoProvisioned = false
        if !ProfileWriter.hasDeviceBody(device), autoDevice {
            autoProvisioned = true
            let log: (String) -> Void = { ConsoleOut.out("   \($0)") }
            if platform == "ios" {
                let ensured: VirtualDeviceFactory.EnsuredSimulator
                do {
                    ensured = try VirtualDeviceFactory.ensureSimulator(
                        target: try IOSAutoDevice.resolve(), explicitName: explicitName, log: log)
                } catch let error as IOSRuntimeInstaller.Failure {
                    throw ValidationError(error.message)
                }
                Self.stampSimulator(ensured.info, model: ensured.model, into: &device)
                ConsoleOut.out("   Auto-picked (ios): \(ensured.info.name) / \(ensured.info.os) / "
                    + "\(ensured.info.udid) (\(ensured.created ? "created" : "existing"))")
            } else {
                let target = try await Self.pickAndroidTarget()
                let acceptLicenses = self.acceptLicenses
                let ensured = try VirtualDeviceFactory.ensureAVD(
                    deviceID: target.deviceID, modelName: target.modelName, package: target.image.package,
                    apiLevel: target.image.apiLevel, tag: target.image.tag, explicitName: explicitName,
                    beforeCreate: { try Self.installIfNeeded(target, acceptLicenses: acceptLicenses, log: log) },
                    log: log)
                device["avd"] = ensured.id
                device["name"] = ensured.name
                ConsoleOut.out("   Auto-picked (android): \(ensured.name) / \(ensured.id) "
                    + "(\(ensured.created ? "created" : "existing"))")
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
        // udid 指定ならそのデバイス、名前指定なら名前(+ os)で引く。見つからなければ下の登録済み検索へ落ちる
        if platform == "ios", device["kind"] == nil, !autoProvisioned, udid != nil || explicitName != nil,
           let simulators = try? SimulatorCatalog.devices().filter({ !$0.physical }) {
            let match: SimDeviceInfo?
            if let udid {
                match = simulators.first { $0.udid == udid }
            } else {
                match = try? SimulatorCatalog.resolve(spec: DeviceSpec(name: explicitName ?? "", osVersion: os), in: simulators)
            }
            if let match {
                Self.stampSimulator(match, model: SimulatorCatalog.modelNamesByUDID()[match.udid],
                                    into: &device)
            }
        }
        // Android で --avd だけ指定されたときの名前は、その AVD の表示名(無ければ ID)
        if platform == "android", explicitName == nil, let avd {
            let installed = AndroidDeviceCatalog.installedAVDs().first { $0.id == avd }
            device["name"] = installed?.displayName ?? avd
        }
        deviceName = (device["name"] as? String) ?? deviceName
        guard !deviceName.isEmpty else {
            throw ValidationError("cannot decide the device name for \(platform): pass --device-name,"
                + " a concrete device (iOS: --udid, Android: --avd), or --auto-device")
        }
        device["name"] = deviceName

        // 実体の指定が無い場合は「他の実行プロファイルに登録済みの手元のデバイスを使う」意味にする
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
                    + "Point at a concrete device (iOS: --device-name/--os or --udid, Android: --avd/--serial), "
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
            appName: appName, defaultAppName: testProject.name, appID: appID, appPath: appPath)
        try ProfileWriter.json(updatedApp).write(to: appURL, options: .atomic)

        // ---- 実行プロファイル(デバイスの実体を持つ。既存なら app を揃えてデバイスを upsert) ----
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

    /// 登録済みのデバイス(spec)を devices[] の1要素へ戻す(手元のデバイスだけを渡すこと)
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

    /// Android の自動選定で使うシステムイメージの tag(拡張の「デバイスを追加」の既定
    /// DEFAULT_ANDROID_SERVICE = modals.js と同じ。片方だけ変えない)
    static let autoDeviceSystemImageTag = "google_apis"

    struct AndroidAutoTarget {
        let deviceID: String
        let modelName: String
        let image: DevicePicker.SystemImageCandidate
        let isInstalled: Bool
        let sizeBytes: Int?
        let license: String?
    }

    /// 最新の Pixel(pixel_<数字> / pixel_<数字>a)と、tag = google_apis・ホスト ABI で API が最大のイメージ
    /// (インストール済み + ダウンロード可能。同じ API ならインストール済み)を選ぶ。作成も導入もしない
    static func pickAndroidTarget() async throws -> AndroidAutoTarget {
        guard let avdmanager = AndroidSDKLocator.findAVDManager() else {
            throw ValidationError(AndroidSDKLocator.avdManagerMissingMessage + ". "
                + AndroidSDKLocator.avdManagerInstallHint)
        }
        let listed = try Shell.run(AndroidSDKLocator.avdManagerCommand(avdmanager, ["list", "device"]))
        guard let output = listed.outputIfSucceeded else {
            throw ValidationError("avdmanager list device failed (exit \(listed.status)): \(listed.tail)")
        }
        let models = ApiDeviceCatalogCommand.parseDeviceDefinitions(output).map { (id: $0.id, name: $0.name) }
        guard DevicePicker.newestPixelPhone(models) != nil else {
            throw ValidationError("no Pixel phone model (pixel_<number> or pixel_<number>a) found in avdmanager list device;"
                + " specify an AVD explicitly with --avd")
        }

        guard let sdkRoot = AndroidSDKLocator.findSDKRoot() else {
            throw ValidationError("Android SDK not found (check ANDROID_HOME / ANDROID_SDK_ROOT)")
        }
        let installedImages = ApiDeviceCatalogCommand.systemImages(sdkRoot: sdkRoot)
        let (downloadable, downloadableError) = await SystemImageRepository.fetchDownloadable(
            installedPackages: Set(installedImages.map(\.package)))
        if let downloadableError {
            ConsoleOut.err("⚠️ \(downloadableError); choosing among the installed system images only")
        }
        let candidate = { (package: String, apiLevel: Int, tag: String, abi: String) in
            DevicePicker.SystemImageCandidate(package: package, apiLevel: apiLevel, tag: tag, abi: abi)
        }
        guard let picked = DevicePicker.androidAutoTarget(
            models: models,
            installed: installedImages.map { candidate($0.package, $0.apiLevel, $0.tag, $0.abi) },
            downloadable: downloadable.map { candidate($0.package, $0.apiLevel, $0.tag, $0.abi) },
            tag: autoDeviceSystemImageTag, abi: SystemImageRepository.hostABI) else {
            throw ValidationError("no \(autoDeviceSystemImageTag) system image for \(SystemImageRepository.hostABI)"
                + " is installed or downloadable; specify an AVD explicitly with --avd")
        }
        let entry = downloadable.first { $0.package == picked.image.package }
        return AndroidAutoTarget(
            deviceID: picked.model.id, modelName: picked.model.name, image: picked.image, isInstalled: picked.isInstalled,
            sizeBytes: entry?.sizeBytes, license: entry?.license)
    }

    /// 未導入のイメージを入れる。ライセンスは --accept-licenses が無ければ承諾せず止める
    /// (本人への確認はエージェントの責務。SystemImageInstaller の契約)
    static func installIfNeeded(_ target: AndroidAutoTarget, acceptLicenses: Bool,
                                log: (String) -> Void) throws {
        guard !target.isInstalled else { return }
        guard acceptLicenses else {
            let size = target.sizeBytes.map { "\($0 / 1_000_000) MB" } ?? "unknown"
            throw ValidationError("the system image \(target.image.package) (download size: \(size);"
                + " license: \(target.license ?? "unknown")) is not installed, and installing it requires"
                + " accepting its Android SDK license. Nothing was installed. Ask the person whether to accept;"
                + " if they agree, run the same command again with --accept-licenses")
        }
        do {
            try SystemImageInstaller.install(package: target.image.package, log: log)
        } catch let error as SystemImageInstaller.Failure {
            throw ValidationError(error.message)
        }
    }
}
