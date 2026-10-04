// launch/activate の前に「そのアプリが入っているか」を読む(CLI の `launch` とライブ操作の
// launch/activate が共有する。MCP の ft_launch は fleetest-mcp 側に同じ読みを持つ)。
// 撃つか断るかの判定は `InstalledAppCheck.launchGuard` の1箇所 —— ここは読みだけ。

import FTAndroid
import FTBridgeClient
import FTCore

enum LaunchInstallVerdict {
    /// `udid` = 照会先の iOS デバイス(nil なら読めない = `.unknown`)。実機は simctl ではなく
    /// devicectl で照会する(実機の udid を simctl へ渡すと的外れな失敗になる)
    static func read(bundleID: String, driver: AppDriver, isAndroid: Bool,
                     udid: String?) -> InstalledAppCheck.InstallVerdict {
        if isAndroid {
            guard let android = driver as? AndroidDriver,
                  let installed = android.isInstalled(bundleID: bundleID) else { return .unknown("adb") }
            return installed ? .installed : .notInstalled
        }
        guard let udid else { return .unknown("no udid to check installation with") }
        if SimulatorCatalog.isPhysical(udid: udid) == true {
            guard let apps = try? IOSPhysicalAppCatalog.apps(udid: udid) else {
                return .unknown("devicectl could not list installed apps")
            }
            return apps.contains { $0.id == bundleID } ? .installed : .notInstalled
        }
        return InstalledAppCheck.simulatorInstallVerdict(udid: udid, bundleID: bundleID)
    }
}
