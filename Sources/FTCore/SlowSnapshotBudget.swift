// SlowSnapshotBudget.swift
// 期限切れ後に「もう1枚」snapshot を撃ってよいかの判定と、その陽性対照の注入口。
//
// 背景: 検証コマンドの既定待ちは5秒(FlowStep.defaultWaitSeconds)だが、1枚の snapshot は
// 冷えたフリートで最大45秒かかる(BridgeClient.Timeout.session)。StepExecutor+Assert.swift の
// 各アサーションループは期限を周回の合間でしか見ないため、期限切れ後の取り直し
// (AssertFreshRetry.arm)や deadline 延長(firstFrameExtended)が積み重なると、120秒の
// コマンド上限(FTDSL.FTSync.commandTimeout)を無情報の timeout で使い切ってしまう。

import Foundation

/// [snapshot 予算] 期限切れ後の追加 snapshot を撃ってよいか。
/// **直前の snapshot がどれだけかかったか**を「次も同じくらいかかる」と見積もり、
/// コマンド全体の上限に収まる見込みが無ければ止める(通常時は数十msなので常に true)。
public enum SlowSnapshotBudget {
    /// - stepElapsedMs: このアサーションの周回開始(deadline を作った時点)からの経過
    /// - lastSnapshotMs: 直前に撃った snapshot 1回の実測
    /// - commandTimeoutMs: 呼び出し元の外枠(FTDSL.FTSync.commandTimeout をミリ秒にしたもの)。
    ///   **FTCore から FTDSL は参照できない**ので呼び出し側(FTRuntime)が渡す。
    ///   nil は「外枠を持たない呼び出し元」(MCP 等。FTSync でラップされていない)を表し、
    ///   常に許可する = 従来どおり
    public static func mayRetake(stepElapsedMs: Int, lastSnapshotMs: Int,
                                 commandTimeoutMs: Int?) -> Bool {
        guard let commandTimeoutMs else { return true }
        return stepElapsedMs + lastSnapshotMs < commandTimeoutMs
    }
}

/// **陽性対照の注入口**(`FrozenInjection` と同じ思想。Sources/FTCore/FrozenVerdict.swift 参照)。
/// フリートが冷えたときの45秒級 snapshot は意図的に起こせないので、これが無いと
/// SlowSnapshotBudget の実効果を単体テストの外(実機・シミュレータ)で通せない。
/// **観測(計測される所要)だけを変え、driver への実際の呼び出しやデバイスの状態には触れない**。
public enum SlowSnapshotInjection {
    /// 例: `FT_FAKE_SNAPSHOT_DELAY_MS=2000`(全 snapshot に一律2秒足す)
    public static let environmentKey = "FT_FAKE_SNAPSHOT_DELAY_MS"

    public static func delay(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Duration? {
        guard let raw = environment[environmentKey], let ms = Int(raw), ms > 0 else { return nil }
        return .milliseconds(ms)
    }
}
