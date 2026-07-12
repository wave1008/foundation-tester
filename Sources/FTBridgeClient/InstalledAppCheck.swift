// autoInstall の差分スキップ判定(iOS シミュレータ)。利用側: BridgeProvisioner(inapp の
// 注入起動前)と ProfileWorkerFactory.installIfNeeded(xcuitest エンジンの実行前インストール)。

import Foundation
import FTCore

public enum InstalledAppCheck {
    /// インストール済みアプリがインストールファイル(.app)と同一内容か。simctl install はバンドルを
    /// バイト同一でコピーする(実測)ため、ディレクトリの深比較で「更新の有無」を判定できる。
    /// 未インストール・比較不能は false(=要インストール)。
    public static func simulatorAppIsCurrent(udid: String, bundleID: String, appPath: String) -> Bool {
        guard let container = try? Shell.run(
            ["xcrun", "simctl", "get_app_container", udid, bundleID]),
            container.status == 0 else { return false }
        let installedPath = container.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !installedPath.isEmpty else { return false }
        return FileManager.default.contentsEqual(atPath: appPath, andPath: installedPath)
    }
}
