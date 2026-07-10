// RunProfileScope.swift
// 実行プロファイル(profiles/runs/<name>.json)によるマシンプロファイルの絞り込み(共通ヘルパー)。
// `ftester api monitor --profile`・`ftester devices up/down --profile` が共通で使う。
// ProfileResolver.resolve() は app 参照の解決・bundle ID 検証まで行い、監視・起動制御には
// 過剰なため、ここでは RunProfileDocument を直接デコードして devices(name 参照)だけを見る。

import ArgumentParser
import FTCore
import Foundation

enum RunProfileScope {
    /// 実行プロファイルが devices で参照するデバイスのみに絞り込んだ MachineProfile のコピーを返す。
    /// - 実行プロファイルが存在しない・デコード不能・devices が空: ProfileError を投げる。
    /// - 実行プロファイルが参照する名前のうち、マシンプロファイルに無いものがあれば warn 経由で
    ///   警告する(処理は継続。マシンごとにデバイス構成が違いうるための想定内ケース)。
    /// - 絞り込んだ結果、デバイスが1台も残らない: ValidationError を投げる。
    static func filteredMachineProfile(
        project: TestProject,
        machineName: String,
        machineProfile: MachineProfile,
        runProfileName: String,
        warn: (String) -> Void
    ) throws -> MachineProfile {
        let runURL = project.runsDir.appendingPathComponent("\(runProfileName).json")
        guard FileManager.default.fileExists(atPath: runURL.path) else {
            throw ProfileError.runProfileNotFound(
                name: runProfileName, available: ProfileResolver.runProfileNames(project: project))
        }
        let runDoc: RunProfileDocument
        do {
            runDoc = try JSONDecoder().decode(RunProfileDocument.self, from: Data(contentsOf: runURL))
        } catch {
            throw ProfileError.decodeFailed(runURL, detail: "\(error)")
        }
        guard let deviceRefs = runDoc.devices, !deviceRefs.isEmpty else {
            throw ProfileError.missingDevices(run: runProfileName)
        }

        let requestedNames = Set(deviceRefs.map(\.name))
        let iosDevices = machineProfile.ios?.devices ?? []
        let androidDevices = machineProfile.android?.devices ?? []
        let allNames = Set((iosDevices + androidDevices).map(\.name))
        let missingNames = requestedNames.subtracting(allNames)
        if !missingNames.isEmpty {
            warn(
                "⚠️ 実行プロファイル \(runProfileName) が参照するデバイスのうち、マシンプロファイル " +
                "\(machineName) に見つからないものがあります: \(missingNames.sorted().joined(separator: ", "))")
        }

        let filteredIOS = iosDevices.filter { requestedNames.contains($0.name) }
        let filteredAndroid = androidDevices.filter { requestedNames.contains($0.name) }
        guard !filteredIOS.isEmpty || !filteredAndroid.isEmpty else {
            throw ValidationError(
                "実行プロファイル \(runProfileName) が参照するデバイス" +
                "(\(deviceRefs.map(\.name).joined(separator: ", ")))が" +
                "マシンプロファイル \(machineName) に 1 台も見つかりません")
        }
        return MachineProfile(
            ios: filteredIOS.isEmpty ? nil : MachineDeviceList(devices: filteredIOS),
            android: filteredAndroid.isEmpty ? nil : MachineDeviceList(devices: filteredAndroid))
    }
}
