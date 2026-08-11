// ステップに付く注記のうち、**run を跨いで数えたいもの**の定義。
//
// 表示文言(driverFallback → ステップ説明の括弧書き)と機械可読コードを1箇所から供給する。
// 文言をリテラルで散らして集計を文字列一致で作ると、**文言を書き換えた瞬間に集計が静かに 0 件になる**
// (検知として最悪の壊れ方 = 「問題が無い」と「測れていない」が区別できない)。
//
// 運搬経路: StepExecutor.noteCodesThisStep → StepOutcome.notes → FTRuntime.recordStep
//   → ScenarioEvent.notes → ScenarioRecordBuilder → TimelineStepRecord.notes(results/ に永続化)
// どちらの DTO でも Optional の後発追加なので旧レコードは decode できる = ProtocolVersion の +1 は不要。

import Foundation

/// ステップ 1 回に付く機械可読な注記。**失敗ではない**が run 横断で率を見たいものだけを置く
/// (毎回出る注記を足しても集計の役に立たない)。
public enum StepNote: String, Sendable, Codable, CaseIterable {
    /// 整定の収束判定がポーリング上限で打ち切られ、**画面が動いたまま先へ進んだ**。
    /// 赤になる前の先行指標: ここが増えている状態で構造的な高速化を入れると、
    /// フレーク率の上昇として遅れて現れる(docs/performance-tuning.md の採用ゲート)。
    /// 探索の終端で出る場合だけ文言が変わる(`StepExecutor.scrollSearchNote`)が**コードは同じ**
    case settleCapped = "settle-capped"

    /// 掴んだ値だけでアサートを満たし、デバイスを 1 度も見なかった(FTRuntime の高速経路)。
    /// このステップは durationMs=0 で記録されるため、**内訳の母数から抜ける**。
    /// 「速くなったのは実装のおかげか、この経路の当たり率が上がっただけか」を切り分けるために数える
    case heldValue = "held-value"

    /// `scrollFrame` が明示されているのに探索開始時点(または探索中)の snapshot で
    /// 1件も解決できず、**スワイプを1本も送らずに**探索を打ち切った。MCP(RefGuard 経由ではなく
    /// StepOutcome.notes 経由)がこのコードで fail-fast 専用の文へ分岐する。
    /// 実測(2026-08-08・Apple マップ): 申告した容器がツリーから消え、黙った全画面スワイプへ
    /// 退化してカードの「計画」ボタンを誤発火させた
    case scrollFrameMissing = "scroll-frame-missing"

    /// 探索が「内容が動かない」で打ち切られ、そのときの容器が**画面高の80%未満**だった
    /// = 半開きのボトムシートの中を探していた公算が高い(2026-08-09)。
    /// 文言側の同じ判定(`StepExecutor.scrollNotFoundMessage` のシート展開ヒント)を
    /// 機械可読にしたもので、**MCP はこのコードでシートを広げて1度だけ再試行する** ——
    /// 文字列一致で分岐すると、文言を書き換えた瞬間に静かに効かなくなる(このファイル冒頭の理由)
    case sheetCollapsed = "sheet-collapsed"

    /// occlusion-guard のスクショが凍結フレーム疑い(StaleFrameDetector.judge)で、撮り直しても
    /// なお木指紋と食い違わなかった。古い絵を根拠に FM の偽陽性反転を宣言しないための素通り
    /// (StepExecutor+Assert.swift の occlusionFlip)
    case staleScreenshot = "stale-screenshot"

    /// 人間向けの文言(FTRuntime がステップ説明へ括弧書きで付ける)
    public var text: String {
        switch self {
        case .settleCapped: return "the screen did not settle (poll limit)"
        case .heldValue: return "from the grabbed value"
        case .scrollFrameMissing: return "the scrollFrame did not resolve, so the search stopped early"
        case .sheetCollapsed: return "the list stopped moving inside a partially open sheet"
        case .staleScreenshot: return "the occlusion-guard screenshot looked stale, so the check was skipped"
        }
    }
}
