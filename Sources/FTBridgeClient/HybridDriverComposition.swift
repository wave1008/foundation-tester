// in-app と XCUITest を組み合わせたドライバの**組み立て方を1箇所に置く**。
//
// 呼び手は **MCP の ft_* とライブ操作**の2つ。どちらも StepExecutor を通らない直接の操作口で、
// 同じ形でなければならない —— **探索と実行で見えるものが食い違う**と「MCP では動いたのに
// シナリオでは落ちる」(およびその逆)が起きる。合成を別々に書くと、片方だけ層が抜けても
// 両方緑のまま通る。
//
// **シナリオ実行はここを通らない**(意図的): あちらは StepExecutor が「501 なら typeDriver へ」の
// 判断を持っているので、HybridFallbackDriver を被せず WebViewDelegatingDriver だけを使う。
//
// 役割分担(ユーザー決定 2026-09-22。ライブ操作もこの形に揃えた):
//   - **自アプリ** → in-app。WKWebView の中身を DOM で読めるのは in-app だけで、
//     レコーディングはそれに依る
//   - **WebView 画面 / interop ホスト** → WebViewDelegatingDriver が必要な分だけ XCUITest へ委譲
//   - **in-app が原理的に実行できない操作**(home / appSwitcher / 座標 drag・press)
//     → HybridFallbackDriver が XCUITest へ回す
//   - **別アプリ・SpringBoard** → foreignApp(別 bundle のセッションを張れる XCUITest)
//
// **attach は1インスタンスを委譲とフォールバックで共有する** —— activate/attached 状態を
// 1本にしないと余計な activate が挟まる。

import FTCore
import Foundation

public enum HybridDriverComposition {

    /// in-app を主に、XCUITest を補助に組む。**呼び手はこの関数だけを使う**(合成の順序を
    /// 各自で書かない)。
    /// - Parameters:
    ///   - inApp: 対象アプリのプロセス内ブリッジ(dylib 注入)
    ///   - attach: 対象アプリへ attach した XCUITest。委譲とフォールバックの両方に使う
    ///   - foreignApp: 別 bundle のセッションを張れる XCUITest(別アプリ・SpringBoard 用)。
    ///     nil = そこまでは面倒を見ない(シナリオ実行のように対象アプリしか触らない呼び手)
    ///   - bundleID: in-app が住んでいるアプリ。**自アプリかの判定に要る**
    public static func inAppFirst(inApp: AppDriver, attach: AppDriver, foreignApp: AppDriver?,
                                  bundleID: String) -> AppDriver {
        HybridFallbackDriver(primary: WebViewDelegatingDriver(primary: inApp, delegated: attach),
                             fallback: attach, primaryBundleID: bundleID, foreignApp: foreignApp)
    }
}
