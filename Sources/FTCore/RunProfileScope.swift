// 実行プロファイル(profiles/runs/<name>.json)が走らせる台(enabled の devices)を台帳にする共通ヘルパー。
// `fleetest api monitor --profile`・`fleetest devices up/down --profile`・
// `fleetest api list-devices --profile`・`ft_list_devices(profile:)` が共通で使う。
// ProfileResolver.resolve() は app 参照の解決・bundle ID 検証まで行い、監視・起動制御には
// 過剰なため、ここでは RunProfileDocument を直接デコードして devices だけを見る。

import Foundation

public enum RunProfileScope {
    /// 実行プロファイルの台を台帳にして返す(並びは devices の記述順 = 起動順の契約)。
    /// - enabledOnly: true = 走らせる台だけ(監視・起動の絞り込み)/ false = enabled: false も含む
    ///   (名前で1台を引く単体操作。一覧に出ている台は操作できるべき)
    /// - 実行プロファイルが存在しない・デコード不能・devices が空: ProfileError を投げる。
    /// - 対象が1台も無い: ProfileError.noEnabledDevices を投げる。
    public static func roster(project: TestProject, runProfileName: String,
                              enabledOnly: Bool = true) throws -> DeviceRoster {
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
        guard let devices = runDoc.devices, !devices.isEmpty else {
            throw ProfileError.missingDevices(run: runProfileName)
        }
        let roster = DeviceRoster(
            entries: DeviceMachineGrouping.entries(runDevices: devices, enabledOnly: enabledOnly))
        guard !roster.isEmpty else {
            throw ProfileError.noEnabledDevices(run: runProfileName)
        }
        return roster
    }
}
