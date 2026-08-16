// DefaultWait.swift
// 検証コマンドの既定待ち秒数の唯一の定義元。MCP(ftester-mcp の defaultWaitSeconds)と
// DSL(FTRuntime.defaultTimeout の既定値)が同じ値を使うための橋渡し(FocusWait と同じ形)。
// 揃えておかないと「MCP では出たのにシナリオでは間に合わない」が起きる。

public enum DefaultWait {
    public static let seconds: Double = 5
}
