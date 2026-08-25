// Android SDK ルート・avdmanager の場所解決。
// AndroidDriver.findADB / DeviceBooter.findEmulatorBinary と同じ探索方針を SDK ルート単位でまとめる
// (探索順を変えるときはそちらとの整合も確認する)。

import Foundation

public enum AndroidSDKLocator {

    /// $ANDROID_HOME → $ANDROID_SDK_ROOT → 既定パス → adb からの相対推定の順。全て失敗で nil
    public static func findSDKRoot() -> URL? {
        let fm = FileManager.default

        func existingDirectory(_ path: String) -> URL? {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }

        for env in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let path = ProcessInfo.processInfo.environment[env],
               let dir = existingDirectory(path) {
                return dir
            }
        }
        let defaultPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk").path
        if let dir = existingDirectory(defaultPath) { return dir }

        if let adb = try? AndroidDriver.findADB() {
            let sdk = URL(fileURLWithPath: adb)
                .deletingLastPathComponent().deletingLastPathComponent()
            if let dir = existingDirectory(sdk.path) { return dir }
        }
        return nil
    }

    /// findAVDManager() が nil のときに利用者へ出す理由文。device-catalog(モデル定義が空になる)・
    /// create-device(作成不能)・doctor で同じ文言を使う。Android Studio 標準の SDK 導入では
    /// cmdline-tools が入らないことがあり、そのとき「モデルを選べない」だけが症状として出る。
    public static let avdManagerMissingMessage =
        "avdmanager not found (the Android SDK Command-line Tools are not installed)"

    /// 上の理由文に添える解決手段。モニターのダイアログは導入ボタンを併記するので使わない
    /// (ボタンの隣に同じ案内が並ぶため)
    public static let avdManagerInstallHint =
        "they can be installed with `fleetest api install-cmdline-tools`"

    /// cmdline-tools/latest → cmdline-tools/*(名前順)→ tools(旧レイアウト)の順
    public static func findAVDManager() -> URL? {
        guard let sdkRoot = findSDKRoot() else { return nil }
        let fm = FileManager.default

        let latest = sdkRoot.appendingPathComponent("cmdline-tools/latest/bin/avdmanager")
        if fm.isExecutableFile(atPath: latest.path) { return latest }

        let cmdlineToolsDir = sdkRoot.appendingPathComponent("cmdline-tools")
        if let entries = try? fm.contentsOfDirectory(
            at: cmdlineToolsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let candidate = entries
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/avdmanager") }
                .first { fm.isExecutableFile(atPath: $0.path) }
            if let candidate { return candidate }
        }

        let legacy = sdkRoot.appendingPathComponent("tools/bin/avdmanager")
        if fm.isExecutableFile(atPath: legacy.path) { return legacy }

        return nil
    }
}
