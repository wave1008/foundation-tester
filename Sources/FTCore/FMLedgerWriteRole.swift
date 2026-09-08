// FM 台帳(FMLiveness / FMUsageLedger)を production の実行ファイルだけに書かせるための門。
//
// 元の門は「XCTestConfigurationFilePath が無ければ書く」(fail-open)だった。だが
// `swift test --parallel` のワーカープロセスではこの環境変数が立たないことがあり、
// FMHealth.record を合成値で直接叩く単体テスト(FMGateWaitWiringTests 等)が本番の台帳へ
// 偽の「生存」を書いていた(実測 2026-09-08)。
//
// **向きを反転**: production の実行ファイル(fleetest / fleetest-scenarios-* / fleetest-mcp)が
// 起動直後に1回 `enableForProduction()` を呼んだときだけ書く(fail-closed)。呼び忘れは
// 「不明」(台帳が書かれないだけ)であって「嘘」ではない —— このリポジトリの規律
// (FMLiveness.swift 冒頭③「不明と死を混ぜない」)と同じ向き。
//
// opt-in する入口の集合は FMLedgerWriteRoleWiringTests がソース走査で固定する。

import Foundation

public enum FMLedgerWriteRole {
    private static let lock = NSLock()
    private static var isProduction = false

    /// production の実行ファイルが起動直後に1回呼ぶ。呼ばなければ `permitsProductionWrite` は
    /// 常に false のまま(= FMLiveness/FMUsageLedger は既定の書き込み先を開かない)
    public static func enableForProduction() {
        lock.lock()
        isProduction = true
        lock.unlock()
    }

    /// 既定の書き込み先(~/.fleetest/…)を開いてよいか。**`FT_FM_LIVENESS_DIR` /
    /// `FT_FM_USAGE_DIR` の明示指定はこれより先に呼び出し側で判定させること**(このプロパティは
    /// opt-in の有無だけを見る)。`XCTestConfigurationFilePath` の判定は呼び出し側が別途重ねる
    /// 二重の備え(FMLiveness.swift / FMUsageLedger.swift)
    public static var permitsProductionWrite: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isProduction
    }

    /// テスト専用。プロセス内の opt-in 状態を初期値へ戻す
    static func resetForTesting() {
        lock.lock()
        isProduction = false
        lock.unlock()
    }
}
