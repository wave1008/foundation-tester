/// DSL の `lightSettle:` 引数(1コマンドだけ簡易整定モードを上書き)をドライバ層へ運ぶ TaskLocal。
/// `StepExecutor.execute` がステップ全体を `$current.withValue(step.lightSettle)` で包み、
/// `BridgeClient` が /swipe 等のリクエストを組むときに読む。nil = 上書きなし(プロファイルの
/// `iosLightSettle` に従う)。AppDriver のシグネチャ(ラッパーが10個以上)を変えないための経路。
public enum LightSettleOverride {
    @TaskLocal public static var current: Bool?
}
