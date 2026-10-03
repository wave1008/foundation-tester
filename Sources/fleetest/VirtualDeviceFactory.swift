// シミュレータ/AVD を実際に作る処理。`fleetest api create-device`(ApiCreateDeviceCommand)と
// `fleetest profile setup --auto-device`(ProfileSetupCommand)が共有する。
// プロファイルへの追記・NDJSON は呼び手の責務。進捗は log クロージャで受ける。

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

enum VirtualDeviceFactory {

    /// create-device の finished.error にそのまま載る(LocalizedError)
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct CreatedSimulator {
        let udid: String
        let deviceTypeName: String
        /// "27.0"(接頭辞 "iOS " なし)
        let runtimeVersion: String
    }

    // MARK: - iOS

    /// `deviceTypeID` / `runtimeID` は simctl の identifier。overwrite のときだけ同名の既存を消す
    /// (iOS は同名を何台でも作れる。付けなければ同名が並ぶ = simctl の既定)
    static func createSimulator(name: String, deviceTypeID: String, runtimeID: String, overwrite: Bool,
                                log: (String) -> Void) throws -> CreatedSimulator {
        log("Resolving the simulator model/runtime...")
        let deviceTypesResult = try Shell.run(["xcrun", "simctl", "list", "-j", "devicetypes"])
        guard deviceTypesResult.status == 0,
              let deviceTypesData = deviceTypesResult.output.data(using: .utf8),
              let deviceTypesJSON = (try? JSONSerialization.jsonObject(with: deviceTypesData))
                as? [String: Any],
              let rawDeviceTypes = deviceTypesJSON["devicetypes"] as? [[String: Any]] else {
            throw Failure("simctl list devicetypes failed: \(deviceTypesResult.tail)")
        }
        guard let deviceTypeEntry = rawDeviceTypes.first(where: {
            ($0["identifier"] as? String) == deviceTypeID
        }), let deviceTypeName = deviceTypeEntry["name"] as? String else {
            throw Failure("simulator model not found: \(deviceTypeID)")
        }

        let listRuntimes = { () throws -> [[String: Any]] in
            let runtimesResult = try Shell.run(["xcrun", "simctl", "list", "-j", "runtimes"])
            guard runtimesResult.status == 0,
                  let runtimesData = runtimesResult.output.data(using: .utf8),
                  let runtimesJSON = (try? JSONSerialization.jsonObject(with: runtimesData))
                    as? [String: Any],
                  let rawRuntimes = runtimesJSON["runtimes"] as? [[String: Any]] else {
                throw Failure("simctl list runtimes failed: \(runtimesResult.tail)")
            }
            return rawRuntimes
        }
        let findRuntime = { (raw: [[String: Any]]) in
            raw.first(where: { ($0["identifier"] as? String) == runtimeID })
        }
        var foundRuntime = findRuntime(try listRuntimes())
        // 未導入でも、選択中の Xcode の SDK の版が入れるランタイム(DevicePicker.predictedIOSRuntimeIdentifier)
        // と一致するときだけ導入してから作る。一致しない identifier は導入の当てが無いので従来どおり not found
        if foundRuntime == nil, let sdk = IOSRuntimeInstaller.sdkVersion(),
           DevicePicker.predictedIOSRuntimeIdentifier(version: sdk) == runtimeID {
            try installRuntime(version: sdk, identifier: runtimeID, log: log)
            foundRuntime = findRuntime(try listRuntimes())
        }
        guard let runtimeEntry = foundRuntime, let runtimeVersion = runtimeEntry["version"] as? String else {
            throw Failure("runtime not found: \(runtimeID)")
        }

        if overwrite {
            try deleteExistingSimulators(named: name, log: log)
        }

        log("Creating the simulator: \(name) (\(deviceTypeName) / iOS \(runtimeVersion))...")
        let createResult = try Shell.run(["xcrun", "simctl", "create", name, deviceTypeID, runtimeID])
        guard createResult.status == 0 else {
            throw Failure("simctl create failed: \(createResult.tail)")
        }
        let udid = createResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw Failure("simctl create produced no output (UDID)")
        }
        log("Created the simulator (UDID: \(udid))")
        return CreatedSimulator(udid: udid, deviceTypeName: deviceTypeName, runtimeVersion: runtimeVersion)
    }

    /// IOSRuntimeInstaller の Failure を、この型の Failure(呼び手が表示に使う)へ写して導入する
    private static func installRuntime(version: String, identifier: String, log: (String) -> Void) throws {
        do {
            try IOSRuntimeInstaller.install(version: version, expectedIdentifier: identifier, log: log)
        } catch let error as IOSRuntimeInstaller.Failure {
            throw Failure(error.message)
        }
    }

    /// 判定は削除コマンドと同じ FTCore.DeviceDeletion(起動中は消さない)。
    /// 同名が複数あれば全部消す(1台だけ残すと「上書きしたのに古いのが残る」)
    private static func deleteExistingSimulators(named name: String, log: (String) -> Void) throws {
        let matches = ((try? SimulatorCatalog.devices()) ?? []).filter { $0.name == name }
        guard !matches.isEmpty else { return }
        for device in matches {
            if let reason = DeviceDeletion.refusalReason(
                isRunning: device.booted, exists: true, then: "create it again") {
                throw Failure("cannot overwrite \(name): \(reason)")
            }
        }
        for device in matches {
            log("Deleting the existing simulator before recreating it: \(name) (\(device.udid))...")
            let result = try Shell.run(DeviceDeletion.iosCommand(udid: device.udid))
            guard result.status == 0 else {
                throw Failure("simctl delete failed: \(result.tail)")
            }
        }
    }

    // MARK: - Android

    /// 作った AVD の ID を返す。ID は名前から機械的に生成する(avdmanager -n の制約に合わせて英数字・._- のみ)。
    /// 既存 AVD と衝突したら overwrite なら消して同じ ID で作り直し、でなければ _2, _3... を足して両方残す
    /// (呼び出し側が「上書きするか」を人に聞けるようにするため、ここでは黙って選ばない)
    static func createAVD(name: String, deviceID: String, package: String, overwrite: Bool,
                          log: (String) -> Void) throws -> String {
        guard let avdmanagerURL = AndroidSDKLocator.findAVDManager() else {
            throw Failure(AndroidSDKLocator.avdManagerMissingMessage + ". "
                + AndroidSDKLocator.avdManagerInstallHint)
        }
        let installedIDs = Set(AndroidDeviceCatalog.installedAVDs().map(\.id))
        let baseID = RunProfileDeviceEditor.sanitizedAVDID(from: name)
        var avdID = baseID
        if installedIDs.contains(baseID), overwrite {
            try deleteExistingAVD(baseID, avdmanagerPath: avdmanagerURL.path, log: log)
        } else {
            var suffix = 2
            while installedIDs.contains(avdID) {
                avdID = "\(baseID)_\(suffix)"
                suffix += 1
            }
        }

        log("Creating the AVD: \(avdID) (\(deviceID) / \(package))...")
        try runAVDManagerCreate(
            avdmanagerPath: avdmanagerURL.path, avdID: avdID, package: package, deviceID: deviceID)
        log("Created the AVD: \(avdID)")

        updateDisplayName(avdID: avdID, displayName: name)
        return avdID
    }

    /// 判定は削除コマンドと同じ FTCore.DeviceDeletion。ここで別の規則を書くと
    /// 「delete-device では拒否されるのに create --overwrite では消える」が起きる
    private static func deleteExistingAVD(_ avdID: String, avdmanagerPath: String,
                                          log: (String) -> Void) throws {
        let running = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
        if let reason = DeviceDeletion.refusalReason(
            isRunning: running.values.contains(avdID), exists: true, then: "create it again") {
            throw Failure("cannot overwrite \(avdID): \(reason)")
        }
        log("Deleting the existing AVD before recreating it: \(avdID)...")
        let result = try Shell.run(AndroidSDKLocator.avdManagerCommand(
            URL(fileURLWithPath: avdmanagerPath), Array(DeviceDeletion.androidCommand(avd: avdID).dropFirst())))
        guard result.status == 0 else {
            throw Failure("avdmanager delete avd failed: \(result.tail)")
        }
    }

    /// avdmanager create avd の上限(秒)。AVD の作成は手元のファイル操作だけ(実測 数秒)。
    /// **尽きたとき** = 答えていない対話プロンプト(「カスタムハードウェアプロファイルを作成しますか?」
    /// 以外の未知の問い)で止まっている形なので、待ち続けず子孫ごと止めてエラーにする
    static let avdManagerCreateTimeoutSeconds: Double = 60

    /// 「カスタムハードウェアプロファイルを作成しますか? [no]」という stdin 待ちの対話プロンプトが出るので
    /// stdin に "no\n" を渡す(`Shell.run(stdin:)`。素の Process + `readDataToEndOfFile` は
    /// 未知のプロンプトで EOF が来ず永久に返らなかった)
    private static func runAVDManagerCreate(
        avdmanagerPath: String, avdID: String, package: String, deviceID: String
    ) throws {
        let result: Shell.Result
        do {
            result = try Shell.run(
                AndroidSDKLocator.avdManagerCommand(
                    URL(fileURLWithPath: avdmanagerPath), ["create", "avd", "-n", avdID, "-k", package, "-d", deviceID]),
                timeout: avdManagerCreateTimeoutSeconds, stdin: Data("no\n".utf8))
        } catch let error as ShellError {
            throw Failure(
                "avdmanager create avd did not finish within \(Int(avdManagerCreateTimeoutSeconds))s "
                + "(an unanswered prompt?): \(ErrorText.user(error))")
        }
        guard result.status == 0 else {
            throw Failure("avdmanager create avd failed: \(result.output)")
        }
    }

    /// AVD ホーム($ANDROID_AVD_HOME || ~/.android/avd)の <avdID>.avd/config.ini へ
    /// avd.ini.displayname を追記/置換する(表示名を機種名では無くデバイス論理名に揃えるため)。
    /// config.ini が見つからない場合は致命的ではないので stderr に警告するだけで続行する
    private static func updateDisplayName(avdID: String, displayName: String) {
        let avdHome = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".android/avd")
        let configURL = avdHome.appendingPathComponent("\(avdID).avd/config.ini")
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            ConsoleOut.err("⚠️ config.ini not found (skipping the display-name setup): \(configURL.path)")
            return
        }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLine = "avd.ini.displayname=\(displayName)"
        if let index = lines.firstIndex(where: { $0.hasPrefix("avd.ini.displayname") }) {
            lines[index] = newLine
        } else {
            lines.append(newLine)
        }
        guard let updated = lines.joined(separator: "\n").data(using: .utf8) else { return }
        do {
            try updated.write(to: configURL, options: .atomic)
        } catch {
            ConsoleOut.err("⚠️ Failed to write the display name into config.ini: \(error.localizedDescription)")
        }
    }

    // MARK: - 自動選定(profile setup --auto-device)

    struct EnsuredSimulator {
        let info: SimDeviceInfo
        /// 機種名(device type 名。実行プロファイルの model)
        let model: String
        let created: Bool
    }

    /// 自動選定した機種・ランタイム(target)の「<機種>(<OS>)-NN」を用意する。
    /// 手元に `<base>-NN` で中身(blueprint の deviceType と runtime)が target と同じものがあれば番号最小を
    /// 再利用(冪等)、無ければ未使用の最小番号で新規作成する。**既存シミュレータは改名も削除もしない**。
    /// explicitName があれば連番の代わりにその名前の完全一致で使う(中身は確かめない)。
    /// **ランタイムの導入は作るときだけ**(要ダウンロードは同じ版の既存が在り得ないので必ず導入 → 作成)
    static func ensureSimulator(target: IOSAutoDevice, explicitName: String?,
                                log: (String) -> Void) throws -> EnsuredSimulator {
        let simulators = try SimulatorCatalog.devices().filter { !$0.physical }
        let name: String
        if let explicitName {
            if let found = simulators.first(where: { $0.name == explicitName }) {
                let foundModel = SimulatorCatalog.modelNamesByUDID()[found.udid] ?? target.modelName
                return EnsuredSimulator(info: found, model: foundModel, created: false)
            }
            name = explicitName
        } else {
            let base = VirtualDeviceNaming.baseName(model: target.modelName, osLabel: target.runtimeName)
            let blueprints = SimulatorCatalog.blueprintsByUDID()
            let sameContent = { (device: SimDeviceInfo) in
                blueprints[device.udid]?.deviceTypeIdentifier == target.deviceTypeID
                    && blueprints[device.udid]?.runtimeIdentifier == target.runtimeID
            }
            // simulators は 起動中 → OS 降順(SimulatorCatalog.resolve と同じ曖昧さの扱い)。
            // 同名が複数あれば中身が一致する最初の1台
            if let existingName = VirtualDeviceNaming.lowestMatching(
                base: base, names: simulators.map(\.name),
                matches: { candidate in simulators.contains { $0.name == candidate && sameContent($0) } }),
               let found = simulators.first(where: { $0.name == existingName && sameContent($0) }) {
                let foundModel = SimulatorCatalog.modelNamesByUDID()[found.udid] ?? target.modelName
                return EnsuredSimulator(info: found, model: foundModel, created: false)
            }
            guard let next = VirtualDeviceNaming.nextUnusedNames(
                base: base, existing: simulators.map(\.name), count: 1).first else {
                throw Failure("all serial numbers 01-99 of \(base) are in use; delete some or pass --device-name")
            }
            name = next
        }
        if target.needsDownload {
            try installRuntime(version: target.runtimeVersion, identifier: target.runtimeID, log: log)
        }
        let made = try createSimulator(
            name: name, deviceTypeID: target.deviceTypeID,
            runtimeID: target.runtimeID, overwrite: false, log: log)
        let info = SimDeviceInfo(udid: made.udid, name: name, os: "iOS \(made.runtimeVersion)", booted: false)
        return EnsuredSimulator(info: info, model: made.deviceTypeName, created: true)
    }

    struct EnsuredAVD {
        let id: String
        let name: String
        let created: Bool
    }

    /// 機種(deviceID・modelName)と system image の「<機種>(<OS>)-NN」を用意する(方針は ensureSimulator と同じ。
    /// 中身 = hw.device.name と image package)。手元に `<base>-NN` で中身が一致する AVD があれば番号最小を再利用、
    /// 無ければ未使用の最小番号で新規作成する。explicitName があれば連番の代わりにその名前の完全一致で使う(中身は確かめない)。
    /// package のイメージは導入済みであること(導入は呼び手の責務)
    static func ensureAVD(deviceID: String, modelName: String, package: String, apiLevel: Int, tag: String,
                          explicitName: String?, beforeCreate: () throws -> Void = {},
                          log: (String) -> Void) throws -> EnsuredAVD {
        let installed = AndroidDeviceCatalog.installedAVDs()
        let labelOf = { (avd: (id: String, displayName: String?)) in avd.displayName ?? avd.id }
        let name: String
        if let explicitName {
            if let found = installed.first(where: { labelOf($0) == explicitName }) {
                return EnsuredAVD(id: found.id, name: explicitName, created: false)
            }
            name = explicitName
        } else {
            let base = VirtualDeviceNaming.baseName(
                model: modelName, osLabel: VirtualDeviceNaming.androidOSLabel(apiLevel: apiLevel, tag: tag))
            let sameContent = { (avd: (id: String, displayName: String?)) in
                AndroidDeviceCatalog.avdModelAndOS(id: avd.id).model == deviceID
                    && AndroidDeviceCatalog.avdSystemImage(id: avd.id)?.package == package
            }
            if let existingName = VirtualDeviceNaming.lowestMatching(
                base: base, names: installed.map(labelOf),
                matches: { candidate in installed.contains { labelOf($0) == candidate && sameContent($0) } }),
               let found = installed.first(where: { labelOf($0) == existingName && sameContent($0) }) {
                return EnsuredAVD(id: found.id, name: existingName, created: false)
            }
            guard let next = VirtualDeviceNaming.nextUnusedNames(
                base: base, existing: installed.map(labelOf), count: 1).first else {
                throw Failure("all serial numbers 01-99 of \(base) are in use; delete some or pass --device-name")
            }
            name = next
        }
        // 導入(ライセンス承諾)は作るときだけ要る。再利用できるなら呼ばない
        try beforeCreate()
        let id = try createAVD(name: name, deviceID: deviceID, package: package, overwrite: false, log: log)
        return EnsuredAVD(id: id, name: name, created: true)
    }
}
