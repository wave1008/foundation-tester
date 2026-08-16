// IOSReduceMotion.swift
// シミュレータの「視差効果を減らす」(com.apple.Accessibility ReduceMotionEnabled)の適用。
// アニメーションを残す = Reduce Motion off。方針は FTCore/AnimationPolicy。
// 実機はホストから変更できないので呼び出し側で弾く(BridgeLauncher.enableReduceMotion 参照)。

import Foundation
import FTCore

public enum IOSReduceMotion {
    /// 引数列(単体テスト対象。true/false の綴りは defaults の -bool が受ける形)
    public static func writeArguments(udid: String, animationsEnabled: Bool) -> [String] {
        let reduceMotion = AnimationPolicy.iosReduceMotion(animationsEnabled: animationsEnabled)
        return ["xcrun", "simctl", "spawn", udid,
                "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled",
                "-bool", reduceMotion ? "true" : "false"]
    }

    /// 失敗は非致命(警告を渡して続行)。設定は以後起動されるアプリに効く
    public static func apply(udid: String, animationsEnabled: Bool, warn: (String) -> Void) {
        let result = try? Shell.run(writeArguments(udid: udid, animationsEnabled: animationsEnabled))
        guard result?.status != 0 else { return }
        warn(animationsEnabled
             ? "⚠️ Failed to turn Reduce Motion off (\(udid)). Animations may stay suppressed"
             : "⚠️ Failed to enable Reduce Motion (\(udid)). "
               + "With animations still on, action settling waits get slower")
    }
}
