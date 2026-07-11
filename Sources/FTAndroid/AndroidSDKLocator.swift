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
