// BackEffect.swift
// 「back の前後で木が同一 = システム back がこの画面に効かなかった」の判定。
// MCP(ft_navigate)と DSL の back() が**同じ判定を共有する**(2箇所に持つと同じ画面で
// 食い違う)。自前ナビの画面はシステム back を無視するので、黙って次のステップへ進ませない。

import Foundation

public enum BackEffect {
    /// MCP がポーリングする回数・間隔。**DSL は after を1回しか撮らない**(ポーリングしない) ——
    /// MCP は1回のツール応答で判定を確定させる必要があるためポーリングで取りこぼしを減らすが、
    /// DSL は back() のたびに払う経路なので after は1枚だけ読んで判定する。
    ///
    /// **DSL は before も毎回素直に撮る**: 「前回の back() の後の木を
    /// 使い回す」自己シード方式を試したが、back() が連続していない限り一度も発火しない ——
    /// 実際 E2E 全 SUT で back() は各シナリオ1回ずつしか呼ばれず、この検知は恒久的に沈黙していた
    /// (「常に false を返す検出器」と区別が付かない = CLAUDE.md が名指しで戒める失敗の型)。
    /// DSL 側には StepExecutor のような「直前の木」を持ち回る仕組みが無いので、
    /// 持たせて状態を増やすより素直に読む方を選んだ(before+after で back() 1回につき
    /// スナップショット2枚。back() は E2E 全体で8回だけなので、フル実行に足しても数秒)
    public static let pollCount = 4
    public static let pollIntervalSeconds: Double = 0.3

    /// 木が同一かどうかの唯一の判定。指紋は StaleFrameDetector.treeFingerprint を使う
    /// (2つ目の指紋実装を作らない)
    public static func treesAreIdentical(before: [ElementInfo], after: [ElementInfo]) -> Bool {
        StaleFrameDetector.treeFingerprint(of: before) == StaleFrameDetector.treeFingerprint(of: after)
    }

    /// 注記を出すべきか。observations が空(=1度も撮り直せなかった)なら「変わっていない」と
    /// 断言する材料が無いので false(黙る)。1件でも before と異なる木があれば back は効いたので
    /// false。1件以上あり**すべてが before と同一**なら true
    public static func shouldWarn(before: [ElementInfo], afterObservations: [[ElementInfo]]) -> Bool {
        guard !afterObservations.isEmpty else { return false }
        return afterObservations.allSatisfy { treesAreIdentical(before: before, after: $0) }
    }

    /// 注記の中核文。呼び手ごとに末尾(advice)だけ変える —— MCP はツール呼び出しとして
    /// 「send back again」と言えるが、DSL の読者はシナリオを書いている人なので
    /// 「call back() again」と DSL コマンドで言う
    public static let summary = "the tree is identical to the one before back — back appears to"
        + " have had no effect on this screen (apps drawing their own back button often ignore"
        + " the system back)"
    public static let mcpAdvice = "tap the app's own back control, or send back again"
    public static let dslAdvice = "tap the app's own back control, or call back() again"

    public static func note(advice: String) -> String { "\(summary); \(advice)" }
}
