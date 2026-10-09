/// DSL の `settle: false`(1コマンドだけ操作後の整定待ちを飛ばす)をドライバ層へ運ぶ TaskLocal。
/// `StepExecutor.execute` がステップ全体を `$skip.withValue(step.settle == false)` で包む。
/// BridgeClient は true の間 `BridgeAPI.settleHeader`(`X-FT-Settle: 0`)を送り、AndroidDriver は
/// `settleViaBridge` を飛ばす。AppDriver のシグネチャ(ラッパーが10個以上)を変えないための経路。
/// 飛ばすのは操作後の整定だけ(確認の待ち・操作前の待ち・複数手コマンドの内側の整定は残す)。
public enum SettleOverride {
    @TaskLocal public static var skip: Bool = false
}
