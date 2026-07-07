// WindowDiscovery.swift
// ScreenCaptureKit によるデバイスウィンドウの列挙。
// iOS: Xcode 27 ではシミュレータのウィンドウホストが Device Hub(com.apple.dt.Devices)。
//      旧 Simulator.app(com.apple.iphonesimulator)もフォールバックとして対象にする。
// Android: エミュレータは qemu-system-* プロセス(タイトル "Android Emulator - <AVD>:<port>")。

import CoreGraphics
import ScreenCaptureKit

struct CapturableDeviceWindow: Identifiable {
    enum Kind {
        case iosSimulator
        case androidEmulator
    }

    let id: CGWindowID
    let scWindow: SCWindow
    let title: String
    let kind: Kind
}

enum WindowDiscovery {
    private static let iosHostBundleIDs: Set<String> = [
        "com.apple.dt.Devices",        // Xcode 27 Device Hub(ウィンドウタイトル = デバイス名)
        "com.apple.iphonesimulator",   // 旧 Simulator.app
    ]

    static func findDeviceWindows() async throws -> [CapturableDeviceWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        var result: [CapturableDeviceWindow] = []
        for window in content.windows {
            // タイトル無し・小サイズ(ツールバー等の付随ウィンドウ)は除外
            guard let title = window.title, !title.isEmpty,
                  window.frame.width >= 150, window.frame.height >= 250,
                  let app = window.owningApplication else { continue }

            let kind: CapturableDeviceWindow.Kind
            if iosHostBundleIDs.contains(app.bundleIdentifier) {
                kind = .iosSimulator
            } else if app.applicationName.localizedCaseInsensitiveContains("qemu")
                        || app.bundleIdentifier == "com.android.Emulator"
                        || title.hasPrefix("Android Emulator") {
                kind = .androidEmulator
            } else {
                continue
            }
            result.append(CapturableDeviceWindow(
                id: window.windowID, scWindow: window, title: title, kind: kind))
        }
        return result
    }

    /// 画面収録権限の確認(プロンプトは出さない)
    static func preflightPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 画面収録権限を要求する(未許可ならシステムのプロンプト/設定画面へ誘導される)
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
