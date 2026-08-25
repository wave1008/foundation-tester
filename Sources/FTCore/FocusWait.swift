// FocusWait.swift
// pressEnter 前の焦点待ちの定数。MCP(fleetest-mcp の awaitFocus)と DSL(StepExecutor+Actions の
// pressEnter)が同じ値を使うための唯一の定義元。

/// フォーカス待ちの上限。**短い**のは、報告しないフレームワークで毎回これを丸ごと待つため
public enum FocusWait {
    public static let waitSeconds: Double = 1.5
    public static let pollSeconds: Double = 0.15
}
