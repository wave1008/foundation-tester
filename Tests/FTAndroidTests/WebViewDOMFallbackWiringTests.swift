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

    /// 子プロセスの stderr を中継する ScenarioHost が、ドライバ自身が ⚠️ を付けた行に
    /// もう1つ ⚠️ を重ねないこと(`fleetest run` の出力で `⚠️ ⚠️` になっていた)
    func testChildStderrRelayDoesNotDoubleTheWarningEmoji() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent(
            "Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        XCTAssertTrue(code.contains("emit(.log(line.hasPrefix(\"⚠️\") ? line : \"⚠️ \\(line)\"))"),
                      "中継が ⚠️ を無条件に前置している")
    }

    /// 警告関数自身が診断メモ(出力回数の上限)と、ソケット解決・判定・文言を委ねていること
    /// (毎 snapshot ごとに adb を叩かない・文言をここに二重に持たない・過渡で鳴らない)
    func testWarnFunctionGoesThroughTheDiagnosisMemoAndDelegatesJudgement() throws {
        let code = try androidDriverSource()
        XCTAssertTrue(code.contains("WebViewDOMFallback.needsDiagnosis(serial: serial, package: package)"),
                      "診断メモを通っていない(毎 snapshot 出す危険)")
        XCTAssertTrue(code.contains("AndroidWebViewDOM.appSocketResolution("),
                      "ソケット解決(過渡かどうか)を見ずに警告している")
        XCTAssertTrue(code.contains("WebViewDOMFallback.isConclusive(resolution)"),
                      "結論でないもの(未起動・adb 不能)までメモしてしまう")
        XCTAssertTrue(code.contains("WebViewDOMFallback.markDiagnosed(serial: serial, package: package)"),
                      "結論をメモしていない(同じ台で何度も問い合わせる)")
        XCTAssertTrue(code.contains("if case .noWebView = resolution,"),
                      "debuggable の問い合わせがソケット無しの回に限られていない")
        XCTAssertTrue(code.contains("resolution: resolution, systemDebuggable: system, appDebuggable: app)"),
                      "判定を WebViewDOMFallback.reason に委ねていない")
        XCTAssertTrue(code.contains("WebViewDOMFallback.warning(serial: serial, packageID: package, reason: reason)"),
                      "文言をここで組み立てている(WebViewDOMFallback に無い二重管理)")
    }
}
