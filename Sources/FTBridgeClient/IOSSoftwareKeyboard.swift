// IOSSoftwareKeyboard.swift
// シミュレータでソフトキーボードを出す(com.apple.keyboard.preferences AutomaticMinimizationEnabled = false)。
// iOS はハードウェアキーボードがあると見なすとソフトキーボードを縮めて隠す(欄に焦点は立つが木にも絵にも出ない)。
// 実測: Mac の再起動の後、この値が true の台だけ keyboardIsShown が決定的に赤(E2E-CMP / Flutter
// の 03)。false にすると Simulator の起動し直し無しで次の焦点から出る。Simulator.app 側の
// ConnectHardwareKeyboard は無関係(シミュレータは Simulator.app 無しの画面なしで動いている)。
// 実機はホストから変えられないので呼び出し側で弾く(IOSReduceMotion と同じ)。

import Foundation
import FTCore

public enum IOSSoftwareKeyboard {
    public static func writeArguments(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid,
         "defaults", "write", "com.apple.keyboard.preferences", "AutomaticMinimizationEnabled", "-bool", "false"]
    }

    /// 失敗は非致命(警告を渡して続行)
    public static func apply(udid: String, warn: (String) -> Void) {
        let result = try? Shell.run(writeArguments(udid: udid))
        guard result?.status != 0 else { return }
        warn("⚠️ Failed to keep the software keyboard shown (\(udid)). "
             + "If iOS treats a hardware keyboard as attached, the on-screen keyboard stays hidden")
    }
}
