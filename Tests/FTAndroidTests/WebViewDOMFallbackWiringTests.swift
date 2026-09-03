// AndroidDriver.snapshot() が `.appWebView` route で AndroidWebViewDOM.read が nil を返す
// 経路(黙って a11y へ落ちていた)で、警告(WebViewDOMFallback)を実際に呼んでいることを固定する。
// 判定そのものは WebViewDOMFallbackTests が見るが、「呼び出しがサイトから消えている」変異は
// コンパイラでは止まらないのでソースを読んで固定する(AndroidDriverTypeSplitTests の
// testInjectionGoesThroughTheBridgeRefMap と同型)。

import XCTest

final class WebViewDOMFallbackWiringTests: XCTestCase {

    private func androidDriverSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/FTAndroid/AndroidDriver.swift"), encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// DOM が読めなかった(`payload` が nil)の else 節で、`.appWebView` route に限って
    /// once 警告を呼んでいること。**ブラウザ経路(`.browser`)は対象外**であること
    /// (今回の実測はアプリ内 WebView の release/debuggable の組み合わせだけ)
    func testAppWebViewDOMMissReasonIsWarnedOnce() throws {
        let code = try androidDriverSource()
        XCTAssertTrue(code.contains("} else if route == .appWebView {"),
                      "DOM が読めなかったときに appWebView route だけを見分けていない")
        XCTAssertTrue(code.contains("warnWebViewDOMFallbackOnce(package: package)"),
                      "DOM が読めなかった経路が警告を呼んでいない")
    }

    /// 警告関数自身が once ゲートと、判定・文言を WebViewDOMFallback へ委ねていること
    /// (毎 snapshot ごとに adb を叩かない・文言をここに二重に持たない)
    func testWarnFunctionGoesThroughTheOnceGateAndDelegatesJudgement() throws {
        let code = try androidDriverSource()
        XCTAssertTrue(code.contains("WebViewDOMFallback.shouldWarn(serial: serial)"),
                      "once ゲートを通っていない(毎 snapshot 出す危険)")
        XCTAssertTrue(code.contains("WebViewDOMFallback.probeCommand(packageID: package)"),
                      "端末への問い合わせが1往復に畳まれていない")
        XCTAssertTrue(code.contains("WebViewDOMFallback.parseProbe(output)"))
        XCTAssertTrue(code.contains("WebViewDOMFallback.reason(systemDebuggable: system, appDebuggable: app)"))
        XCTAssertTrue(code.contains("WebViewDOMFallback.warning(serial: serial, packageID: package, reason: reason)"),
                      "文言をここで組み立てている(WebViewDOMFallback に無い二重管理)")
    }
}
