// 失敗ステップの「素性」の定義(2026-08-20)。
//
// **事実だけを置く**。「環境要因の失敗」「アプリが遅い」のような**原因の推定は置かない** ——
// アプリが重いのかマシンが混んでいるのかはツールから区別できず、推測を混ぜると
// 「誤った緑・誤った赤」を作る(2026-08-20 の受け手方針)。ここが答えるのは
// 「**どの経路で落ちたか**」だけで、それを何と読むかは読み手の仕事。
//
// 文字列は結果 JSON(FailedStepRecord.failureKind)に出る**機械可読な出口**なので、
// 一度出した rawValue は変えない(読み手の集計が黙って 0 件になる)。
//
// 運搬経路: StepExecutor.failureKindThisStep → StepOutcome.failureKind
//   → FTRuntime.recordStep → ScenarioEvent.failureKind → FailedStepRecord.failureKind
// 後発追加の Optional なので旧レコードもそのまま decode できる(StepNote と同じ理由)。

import Foundation

/// 失敗ステップがどの経路で落ちたか。**言えないときは nil**(推測で埋めない)
public enum StepFailureKind: String, Sendable, Codable, CaseIterable {
    /// 実行前の構文検証で落とした。**デバイスには1度も触っていない** = 端末やアプリの状態と無関係
    case selectorSyntax = "selector-syntax"

    /// ロケータが解決できなかった(スクロール探索まで含めて、その要素が木に居ない)。
    /// 「画面が違う」と「セレクタが古い」を区別するものではない —— どちらもここに来る
    case notFound = "not-found"

    /// 要素は掴めたが、期待した値・状態と違った(textIs 等の不一致・可視性照合の不成立)
    case assertion = "assertion"

    /// ドライバ(ブリッジ)へ到達できなかった。接続拒否・応答なし・アプリのプロセス死を含む。
    /// **ステップの内容とは独立**に起きる形
    case driverUnreachable = "driver-unreachable"

    /// ドライバは応答したがエラーを返した(HTTP のエラー応答)。到達はしている
    case driverError = "driver-error"

    /// ステップの実行が制限時間内に返らなかった(FTSync.commandTimeout)
    case timeout = "timeout"

    /// 対象アプリがデバイスに入っていなかった(起動前の検査で確定した事実)
    case appNotInstalled = "app-not-installed"
}

/// **エラー自身が素性を名乗る**。`failureKind(thrown:)` が文言ではなくこれを見るので、
/// 新しいエラー型を足す側が仕分けを持てる(FTCore が下位モジュールのエラー型を知らずに済む)。
/// 名乗れないエラーは**準拠しない** = nil のまま(「その他」に丸めない)。
public protocol StepFailureKindProviding {
    var stepFailureKind: StepFailureKind? { get }
}
