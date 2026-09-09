// RunEnvironment.swift
// 実行環境変数(FT_FAST_INPUT 等)の注入を1箇所にする唯一の定義元。
// 呼び手: fleetest の4経路(ProfileRunner / ApiRunCommand の profile 有無2経路 / Fleetest.swift の
// profile 無し経路)と fleetest-mcp の resolveProfileTarget。**値の意味は ProfileRunner の現行に揃える**
// (根拠・実測は各呼び手の旧コメント参照。ここでは「何を書くか」だけを持つ)。
//
// キーの唯一の定義元は `RunEnvironmentKeys`。読み手(BridgeClient.fastInput /
// WebViewDelegatingDriver.preActionWarmup / AdbInstallVerifier.bypassEnabled)はここを参照する。

import Foundation

public enum RunEnvironmentKeys {
    /// BridgeClient.fastInput が読む(高速入力・quiescence スキップ)
    public static let fastInput = "FT_FAST_INPUT"
    /// WebViewDelegatingDriver.preActionWarmup が読む
    public static let preActionWarmup = "FT_PRE_ACTION_WARMUP"
    /// AnimationPolicy.animationsEnabled が読む(唯一の定義元は AnimationPolicy 側なのでここは転写)
    public static let animations = AnimationPolicy.environmentKey
    /// AdbInstallVerifier.bypassEnabled が読む
    public static let playProtectBypass = "FT_PLAY_PROTECT_BYPASS"
}

public enum RunEnvironment {
    /// 何を書くか(純粋関数。setenv は `apply` 側の責務)。
    /// - fastInput: true のときだけ "1" を書く(false は書かない = 既定のまま)
    /// - preActionWarmup: false のときだけ "0" を書く(true は書かない = 既定のまま)
    /// - animations: **必ず**書く。`enableAnimations || 現在の環境で既に ON` の論理和 ——
    ///   `--set enableAnimations=true` と手動 export の両方を尊重するため、単純な上書きにしない
    /// - playProtectBypass: false のときだけ "0" を書く。**true でも "1" は書かない** ——
    ///   環境側のキルスイッチ(手動 export の "0")を上書きしてはならない
    public static func variables(
        iosFastInput: Bool, iosPreActionWarmup: Bool, enableAnimations: Bool,
        playProtectBypass: Bool,
        current: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result: [String: String] = [:]
        if iosFastInput { result[RunEnvironmentKeys.fastInput] = "1" }
        if !iosPreActionWarmup { result[RunEnvironmentKeys.preActionWarmup] = "0" }
        let animations = enableAnimations || AnimationPolicy.animationsEnabled(environment: current)
        result[RunEnvironmentKeys.animations] = animations ? "1" : "0"
        if !playProtectBypass { result[RunEnvironmentKeys.playProtectBypass] = "0" }
        return result
    }

    public static func apply(iosFastInput: Bool, iosPreActionWarmup: Bool, enableAnimations: Bool,
                             playProtectBypass: Bool) {
        for (key, value) in variables(iosFastInput: iosFastInput, iosPreActionWarmup: iosPreActionWarmup,
                                       enableAnimations: enableAnimations,
                                       playProtectBypass: playProtectBypass) {
            setenv(key, value, 1)
        }
    }

    public static func apply(_ resolved: ResolvedProfile) {
        apply(iosFastInput: resolved.iosFastInput, iosPreActionWarmup: resolved.iosPreActionWarmup,
              enableAnimations: resolved.enableAnimations, playProtectBypass: resolved.playProtectBypass)
    }

    public static func apply(_ settings: DeviceIndependentRunSettings) {
        apply(iosFastInput: settings.iosFastInput, iosPreActionWarmup: settings.iosPreActionWarmup,
              enableAnimations: settings.enableAnimations, playProtectBypass: settings.playProtectBypass)
    }
}
