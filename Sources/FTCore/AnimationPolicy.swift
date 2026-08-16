// AnimationPolicy.swift
// アプリのアニメーションを残すか(既定 = 残さない)の唯一の判定元。
// 伝搬経路: 実行プロファイルの enableAnimations → FT_ANIMATIONS(ApiRunCommand / ProfileRunner が
// setenv)→ ここ → AndroidBridge.applyAnimationSettings / BridgeLauncher.applyReduceMotion。
// プロファイルを通らない経路(MCP・bridge up・explore)は未設定 = 無効化のまま。

import Foundation

public enum AnimationPolicy {
    public static let environmentKey = "FT_ANIMATIONS"

    /// Android の Developer options 側スケール3種(0 = 無効・1 = OS 既定速度)
    public static let androidScaleKeys = [
        "window_animation_scale", "transition_animation_scale", "animator_duration_scale",
    ]

    /// アニメーションを残すか。未設定・未知の値は false(= 無効化する既定へ倒す)
    public static func animationsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch environment[environmentKey]?.lowercased() {
        case "1", "true", "on", "yes": return true
        default: return false
        }
    }

    /// `settings put global <key> <値>` に渡す文字列
    public static func androidScaleValue(animationsEnabled: Bool) -> String {
        animationsEnabled ? "1" : "0"
    }

    /// iOS の com.apple.Accessibility ReduceMotionEnabled。アニメーションを残す = Reduce Motion off
    public static func iosReduceMotion(animationsEnabled: Bool) -> Bool { !animationsEnabled }
}
