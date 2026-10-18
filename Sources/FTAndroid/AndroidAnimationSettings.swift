// AndroidAnimationSettings.swift
// `settings get/put global *_animation_scale` の組み立てと判定(adb 実行は呼び出し側へ委譲)。
// デバイス上でしか出ない部分を残さず単体テストで固めるための切り出し。方針は FTCore/AnimationPolicy。

import Foundation
import FTCore

public enum AndroidAnimationSettings {
    /// adb の "shell" の後ろに続く引数列
    public static func putArguments(key: String, animationsEnabled: Bool) -> [String] {
        ["settings", "put", "global", key,
         AnimationPolicy.androidScaleValue(animationsEnabled: animationsEnabled)]
    }

    public static func getArguments(key: String) -> [String] {
        ["settings", "get", "global", key]
    }

    /// 3種のスケールを put し、**失敗した key** を返す(空 = 全成功)
    public static func apply(animationsEnabled: Bool, put: ([String]) -> Bool) -> [String] {
        AnimationPolicy.androidScaleKeys.filter {
            !put(putArguments(key: $0, animationsEnabled: animationsEnabled))
        }
    }

    /// `settings get` の出力が既に目的の状態か。未設定("null"・空)は Android 既定の 1.0 として扱う
    /// (= アニメーション有効側)。値が読めない場合も「違う」と見て put させる(黙って諦めない)
    public static func matches(rawValue: String?, animationsEnabled: Bool) -> Bool {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scale: Double?
        if trimmed.isEmpty || trimmed == "null" {
            scale = 1
        } else {
            scale = Double(trimmed)
        }
        guard let scale else { return false }
        return animationsEnabled ? scale != 0 : scale == 0
    }

    /// run の後に元へ戻す1件。`value == nil` は「元は未設定」= 設定を消す
    public struct Restore: Equatable, Sendable {
        public var key: String
        public var value: String?
        public init(key: String, value: String?) {
            self.key = key
            self.value = value
        }

        /// adb の "shell" の後ろに続く引数列
        public var arguments: [String] {
            value.map { ["settings", "put", "global", key, $0] } ?? ["settings", "delete", "global", key]
        }
    }

    /// 戻す対象の決定。**この run が書き換えたものだけ**(= `matches` が false だった key。run の開始時の同期が put するのと同じ条件)。
    /// `previousRaw` は読めた key の `settings get` の出力だけ(読めなかった key は元が分からないので戻さない)。
    /// "null"・空は元が未設定 → 消す。順序は `AnimationPolicy.androidScaleKeys`
    public static func restoreEntries(previousRaw: [String: String], animationsEnabled: Bool) -> [Restore] {
        AnimationPolicy.androidScaleKeys.compactMap { key in
            guard let raw = previousRaw[key],
                  !matches(rawValue: raw, animationsEnabled: animationsEnabled) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return Restore(key: key, value: (trimmed.isEmpty || trimmed == "null") ? nil : trimmed)
        }
    }
}
