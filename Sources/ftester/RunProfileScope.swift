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

        // **参照の同一性は (host, name)**(FTCore.DeviceHostGrouping)。名前だけで絞ると、
        // 同名のデバイスが別のホストにも居るとき**選んでいない台まで混ざる**
        // (モニターに未選択のタイルが並ぶ実害。2026-08-17)。実効ホストは entries が
        // spec.host へ書き戻すので、以降の利用側(モニターのホスト表示)もそれを読める
        let entries = DeviceHostGrouping.entries(machine: machineProfile)
        // **並びはマシンプロファイル順**(実行プロファイルの記述順で並べ替えない。起動順の契約。
        // testPreservesMachineProfileOrderNotRunProfileOrder)ので、採用は「印」で持つ
        var matchedKeys = Set<String>()
        var missingNames: [String] = []
        for ref in deviceRefs {
            switch DeviceHostGrouping.resolve(ref, in: entries) {
            case .found(let entry):
                matchedKeys.insert("\(DeviceHostGrouping.display(entry.host))\t\(entry.name)")
            case .missing:
                missingNames.append(ref.name)
            case .ambiguous(let hosts):
                // 曖昧な参照は**触らない**(どちらの機械の台か決まらないまま起動・監視しない)。
                // run 側は同じ状況で中止する(ProfileError.ambiguousDeviceRef)
                warn("⚠️ device \"\(ref.name)\" in run profile \(runProfileName) is ambiguous"
                    + " (it exists on \(hosts.joined(separator: ", "))) — skipping it."
                    + " Add \"host\" to the device entry to say which one")
            }
        }
        if !missingNames.isEmpty {
            warn(
                "⚠️ Some devices referenced by run profile \(runProfileName) are missing from machine profile " +
                "\(machineName): \(Set(missingNames).sorted().joined(separator: ", "))")
        }

        let matched = entries.filter {
            matchedKeys.contains("\(DeviceHostGrouping.display($0.host))\t\($0.name)")
        }
        let filteredIOS = matched.filter { $0.platform == "ios" }.map(\.spec)
        let filteredAndroid = matched.filter { $0.platform == "android" }.map(\.spec)
        guard !filteredIOS.isEmpty || !filteredAndroid.isEmpty else {
            throw ValidationError(
                "none of the devices referenced by run profile \(runProfileName) " +
                "(\(deviceRefs.map(\.name).joined(separator: ", "))) " +
                "exist in machine profile \(machineName)")
        }
        return MachineProfile(
            ios: filteredIOS.isEmpty ? nil : MachineDeviceList(devices: filteredIOS),
            android: filteredAndroid.isEmpty ? nil : MachineDeviceList(devices: filteredAndroid))
    }
}
