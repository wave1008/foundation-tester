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

        let runtimesResult = try Shell.run(["xcrun", "simctl", "list", "-j", "runtimes"])
        guard runtimesResult.status == 0,
              let runtimesData = runtimesResult.output.data(using: .utf8),
              let runtimesJSON = (try? JSONSerialization.jsonObject(with: runtimesData))
                as? [String: Any],
              let rawRuntimes = runtimesJSON["runtimes"] as? [[String: Any]] else {
            throw Failure("simctl list runtimes failed: \(runtimesResult.tail)")
        }
        guard let runtimeEntry = rawRuntimes.first(where: { ($0["identifier"] as? String) == runtimeID }),
              let runtimeVersion = runtimeEntry["version"] as? String else {
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

    /// simctl の runtime identifier → name("iOS 27.0")。simctl が非ゼロ・該当なしは Failure
    private static func runtimeName(identifier: String) throws -> String {
        let result = try Shell.run(["xcrun", "simctl", "list", "-j", "runtimes"])
        guard let output = result.outputIfSucceeded,
              let data = output.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let runtimes = json["runtimes"] as? [[String: Any]] else {
            throw Failure("simctl list runtimes failed: \(result.tail)")
        }
        guard let name = runtimes.first(where: { ($0["identifier"] as? String) == identifier })?["name"] as? String else {
            throw Failure("runtime not found: \(identifier)")
        }
        return name
    }

    /// 選んだ既存シミュレータ(picked)と同じ機種・OS の「<機種>(<OS>)-NN」を用意する。
    /// 手元に `<base>-NN` で中身(deviceType・runtime)が picked と同じものがあれば番号最小を再利用(冪等)、
    /// 無ければ未使用の最小番号で新規作成する。**picked 自身は改名も削除もしない**。
    /// explicitName があれば連番の代わりにその名前の完全一致で使う(中身は確かめない)
    static func ensureSimulator(like picked: SimDeviceInfo, explicitName: String?,
                                log: (String) -> Void) throws -> EnsuredSimulator {
        let blueprints = SimulatorCatalog.blueprintsByUDID()
        guard let model = SimulatorCatalog.modelNamesByUDID()[picked.udid],
              let blueprint = blueprints[picked.udid] else {
            throw Failure("cannot read the model/runtime of simulator \(picked.name) (\(picked.udid))"
                + " from simctl; specify one explicitly with --udid")
        }
        let simulators = try SimulatorCatalog.devices().filter { !$0.physical }
        let name: String
        if let explicitName {
            if let found = simulators.first(where: { $0.name == explicitName }) {
                let foundModel = SimulatorCatalog.modelNamesByUDID()[found.udid] ?? model
                return EnsuredSimulator(info: found, model: foundModel, created: false)
            }
            name = explicitName
        } else {
            let base = VirtualDeviceNaming.baseName(
                model: model, osLabel: try runtimeName(identifier: blueprint.runtimeIdentifier))
            let sameContent = { (device: SimDeviceInfo) in blueprints[device.udid] == blueprint }
            // simulators は 起動中 → OS 降順(SimulatorCatalog.resolve と同じ曖昧さの扱い)。
            // 同名が複数あれば中身が一致する最初の1台
            if let existingName = VirtualDeviceNaming.lowestMatching(
                base: base, names: simulators.map(\.name),
                matches: { candidate in simulators.contains { $0.name == candidate && sameContent($0) } }),
               let found = simulators.first(where: { $0.name == existingName && sameContent($0) }) {
                let foundModel = SimulatorCatalog.modelNamesByUDID()[found.udid] ?? model
                return EnsuredSimulator(info: found, model: foundModel, created: false)
            }
            guard let next = VirtualDeviceNaming.nextUnusedNames(
                base: base, existing: simulators.map(\.name), count: 1).first else {
                throw Failure("all serial numbers 01-99 of \(base) are in use; delete some or pass --device-name")
            }
            name = next
        }
        let made = try createSimulator(
            name: name, deviceTypeID: blueprint.deviceTypeIdentifier,
            runtimeID: blueprint.runtimeIdentifier, overwrite: false, log: log)
        let info = SimDeviceInfo(udid: made.udid, name: name, os: "iOS \(made.runtimeVersion)", booted: false)
        return EnsuredSimulator(info: info, model: made.deviceTypeName, created: true)
    }

    struct EnsuredAVD {
        let id: String
        let name: String
        let created: Bool
    }

    /// 選んだ既存 AVD(pickedID)と同じ機種・system image の「<機種>(<OS>)-NN」を用意する(方針は ensureSimulator と同じ。
    /// 中身 = hw.device.name と image package)。機種の表示名は avdmanager list device の Name、引けなければ hw.device.name のまま
    static func ensureAVD(like pickedID: String, explicitName: String?,
                          log: (String) -> Void) throws -> EnsuredAVD {
        guard let deviceID = AndroidDeviceCatalog.avdModelAndOS(id: pickedID).model,
              let image = AndroidDeviceCatalog.avdSystemImage(id: pickedID) else {
            throw Failure("cannot read hw.device.name / image.sysdir.1 from the config.ini of AVD \(pickedID);"
                + " specify one explicitly with --avd")
        }
        let installed = AndroidDeviceCatalog.installedAVDs()
        let labelOf = { (avd: (id: String, displayName: String?)) in avd.displayName ?? avd.id }
        let name: String
        if let explicitName {
            if let found = installed.first(where: { labelOf($0) == explicitName }) {
                return EnsuredAVD(id: found.id, name: explicitName, created: false)
            }
            name = explicitName
        } else {
            var modelLabel = deviceID
            if let avdmanager = AndroidSDKLocator.findAVDManager(),
               let listed = try? Shell.run(AndroidSDKLocator.avdManagerCommand(avdmanager, ["list", "device"])),
               let output = listed.outputIfSucceeded,
               let listedName = ApiDeviceCatalogCommand.parseDeviceDefinitions(output).first(where: { $0.id == deviceID })?.name {
                modelLabel = listedName
            }
            let base = VirtualDeviceNaming.baseName(
                model: modelLabel, osLabel: VirtualDeviceNaming.androidOSLabel(apiLevel: image.apiLevel, tag: image.tag))
            let sameContent = { (avd: (id: String, displayName: String?)) in
                AndroidDeviceCatalog.avdModelAndOS(id: avd.id).model == deviceID
                    && AndroidDeviceCatalog.avdSystemImage(id: avd.id)?.package == image.package
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
        let id = try createAVD(name: name, deviceID: deviceID, package: image.package, overwrite: false, log: log)
        return EnsuredAVD(id: id, name: name, created: true)
    }
}
