// 画像判定(テキストの可視性検証・findImage / existImage / imageIs・分類器・screenLooksLike / screenIs)の絵を
// どちらのドライバで撮るか。撮るのは `StepExecutor.judgmentScreenshot` の1箇所。
//
// inapp モードの主ドライバ(in-app)の絵はアプリ自身の window だけで、キーボードもシステムアラートも写らない
// (覆われた要素を「見えている」と読む = 誤った緑)。毎回 XCUITest で撮ると判定のたびに数百 ms 増える
// (in-app 約 45〜125ms)ので、**覆いがあると分かっているときだけ**画面全体の絵(fallbackDriver)にする:
//   - キーボード: 判定に使う木が申告している(`KeyboardWait.isShown`。往復なし)
//   - システムアラート: CAE フェーズごとに1回 SpringBoard に聞いた答え(`GET /systemalert` 約 73ms)。
//     `UIApplication.applicationState` は端末で割れて使えない(SystemUIGate の doc)
// 通知バナー等、キーボードでもアラートでもない覆いは見逃す(利用者向け docs の制限)。

import Foundation

public enum JudgmentCapture {

    public enum Source: Equatable, Sendable {
        /// 主ドライバで撮る(今までどおり)
        case primary
        /// 画面全体を撮れる fallbackDriver(XCUITest)で撮る
        case wholeScreen
        /// このフェーズでまだアラートを聞いていない。聞いてから決め直す
        case probeSystemAlert
    }

    /// - primaryOmitsSystemUI: 主ドライバの絵にキーボード・システムアラートが写らない構成(inapp モード)
    /// - hasWholeScreen: 画面全体を撮れるドライバ(fallbackDriver)がある
    /// - alwaysWholeScreen: 判定が1回で数秒かかり、往復の差が効かないもの(screenLooksLike / screenIs の FM)
    /// - alertCovering: このフェーズの照会の答え。nil = まだ聞いていない
    public static func source(primaryOmitsSystemUI: Bool, hasWholeScreen: Bool, alwaysWholeScreen: Bool,
                              keyboardShown: Bool, alertCovering: Bool?) -> Source {
        guard primaryOmitsSystemUI, hasWholeScreen else { return .primary }
        if alwaysWholeScreen || keyboardShown { return .wholeScreen }
        switch alertCovering {
        case nil: return .probeSystemAlert
        case true?: return .wholeScreen
        case false?: return .primary
        }
    }
}
