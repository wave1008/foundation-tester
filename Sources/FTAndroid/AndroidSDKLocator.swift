// AndroidSDKLocator.swift
// Android SDK ルート・avdmanager の場所解決。ftester api device-catalog / create-device が使う。
// AndroidDriver.findADB / DeviceBooter.findEmulatorBinary と同じ探索方針
// ($ANDROID_HOME → $ANDROID_SDK_ROOT → 既定パス → adb からの相対推定)を SDK ルート単位でまとめる。

import Foundation

public enum AndroidSDKLocator {

    /// Android SDK ルートの解決:
    /// $ANDROID_HOME → $ANDROID_SDK_ROOT → ~/Library/Android/sdk の順で
    /// 存在するディレクトリ。どれも無ければ AndroidDriver.findADB() が見つかればその 2 つ上
    /// (<sdk>/platform-tools/adb → <sdk>)。それも無ければ nil
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

    /// avdmanager の場所解決:
    /// <sdk>/cmdline-tools/latest/bin/avdmanager →
    /// <sdk>/cmdline-tools/*/bin/avdmanager(ディレクトリ名でソートして最初に見つかったもの)→
    /// <sdk>/tools/bin/avdmanager(旧レイアウト)の順。SDK ルート自体が無ければ nil
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
