// CoreSimulator 直叩き(FTCoreSimShim)によるアプリ起動/インストール確認。
// SimulatorCatalog のデバイス列挙(simctl 567ms → 6ms)と同じ作法: シム利用不能/失敗時は
// 呼び出し側が simctl へフォールバックする。殺しスイッチ: FT_SIMULATOR_CONTROL=simctl。

import Foundation
import FTCoreSimShim

enum CoreSimAppControl {

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["FT_SIMULATOR_CONTROL"] != "simctl"
    }

    struct LaunchResult {
        let success: Bool
        let pid: Int32?
        let error: String?
    }

    /// nil = シム利用不能(呼び出し側は simctl launch へフォールバックする契約)。
    /// environment は **接頭辞なし**のキー名で渡すこと(simctl の SIMCTL_CHILD_ 接頭辞は
    /// CoreSimulator 経路に無い。呼び出し側で剥がす)
    static func launch(udid: String, bundleID: String, environment: [String: String],
                       terminateRunningProcess: Bool) -> LaunchResult? {
        guard enabled,
              let dict = FTCoreSimLaunch(udid, bundleID, environment, terminateRunningProcess)
        else { return nil }
        return LaunchResult(success: (dict["success"] as? Bool) ?? false,
                            pid: (dict["pid"] as? NSNumber)?.int32Value,
                            error: dict["error"] as? String)
    }

    /// nil = シム利用不能(呼び出し側は simctl get_app_container へフォールバックする契約)
    static func isInstalled(udid: String, bundleID: String) -> Bool? {
        guard enabled, let result = FTCoreSimIsInstalled(udid, bundleID) else { return nil }
        return result.boolValue
    }
}
