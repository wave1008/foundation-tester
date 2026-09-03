// Android アプリ自身の WebView の DOM 読みが取れず a11y へ黙って落ちる経路に足した警告
// (WebViewDOMFallback)の判定を固定する。実機/エミュレータ依存の部分(adb)は外し、
// 純粋な判定・文言・once ゲートだけを見る(WebViewShotCompositeTests と同型)。

import XCTest
@testable import FTAndroid

final class WebViewDOMFallbackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        WebViewDOMFallback.resetDiagnosisMemoForTesting()
    }

    // MARK: - 判定(端末の事実で決まるときだけ言う。過渡では黙る)

    func testNoSocketWithBothNonDebuggableIsStructurallyClosed() {
        XCTAssertEqual(WebViewDOMFallback.reason(resolution: .noWebView,
                                                 systemDebuggable: false, appDebuggable: false),
                       .structurallyClosed)
    }

    /// 片方でも debuggable なら「WebView がまだ生成されていない」が普通 = 過渡なので黙る
    func testNoSocketWithEitherDebuggableIsSilent() {
        XCTAssertNil(WebViewDOMFallback.reason(resolution: .noWebView, systemDebuggable: true, appDebuggable: false))
        XCTAssertNil(WebViewDOMFallback.reason(resolution: .noWebView, systemDebuggable: false, appDebuggable: true))
        XCTAssertNil(WebViewDOMFallback.reason(resolution: .noWebView, systemDebuggable: true, appDebuggable: true))
    }

    /// 不明(読めなかった)を false と混ぜない —— 構造的に閉じていると断定できるのは両方が確実に false のときだけ
    func testNoSocketWithUnknownFactsIsSilent() {
        XCTAssertNil(WebViewDOMFallback.reason(resolution: .noWebView, systemDebuggable: nil, appDebuggable: false))
        XCTAssertNil(WebViewDOMFallback.reason(resolution: .noWebView, systemDebuggable: false, appDebuggable: nil))
        XCTAssertNil(WebViewDOMFallback.reason(resolution: .noWebView, systemDebuggable: nil, appDebuggable: nil))
    }

    /// ソケットがあるのに読めなかった = タブ未選択等の過渡。事実が非 debuggable でも構造的とは言わない
    func testSocketPresentIsSilentEvenWhenBothNonDebuggable() {
        XCTAssertNil(WebViewDOMFallback.reason(resolution: .socket("webview_devtools_remote_1"),
                                               systemDebuggable: false, appDebuggable: false))
    }

    func testAppNotRunningAndUnavailableAreSilent() {
        XCTAssertNil(WebViewDOMFallback.reason(resolution: .appNotRunning, systemDebuggable: false, appDebuggable: false))
        XCTAssertNil(WebViewDOMFallback.reason(resolution: .unavailable, systemDebuggable: false, appDebuggable: false))
    }

    func testAmbiguousSocketsAreReportedAsAFact() {
        XCTAssertEqual(WebViewDOMFallback.reason(resolution: .ambiguous(["a", "b"]),
                                                 systemDebuggable: true, appDebuggable: nil),
                       .ambiguousSockets(["a", "b"]))
    }

    /// 結論(メモしてよい)はソケットの有無と曖昧だけ。未起動・adb 不能は次の miss で引き直す
    func testOnlyDeviceFactsAreConclusive() {
        XCTAssertTrue(WebViewDOMFallback.isConclusive(.socket("s")))
        XCTAssertTrue(WebViewDOMFallback.isConclusive(.noWebView))
        XCTAssertTrue(WebViewDOMFallback.isConclusive(.ambiguous(["a", "b"])))
        XCTAssertFalse(WebViewDOMFallback.isConclusive(.appNotRunning))
        XCTAssertFalse(WebViewDOMFallback.isConclusive(.unavailable))
    }

    // MARK: - 端末への問い合わせ(素のシェル文字列に埋めるので綴りを検める)

    func testProbeAsksForBothSystemAndAppDebuggableInOneRoundTrip() throws {
        let command = try XCTUnwrap(WebViewDOMFallback.probeCommand(packageID: "com.ftester.e2e"))
        let script = command.joined(separator: " ")
        XCTAssertTrue(script.contains("getprop ro.debuggable"))
        XCTAssertTrue(script.contains(WebViewDOMFallback.probeMarker), "system とアプリの切れ目が無い")
        XCTAssertTrue(script.contains("dumpsys package com.ftester.e2e"))
        XCTAssertTrue(script.contains("grep flags="))
    }

    /// **端末上で別コマンドにならないこと**(パッケージ名は素で埋めている)
    func testProbeRefusesShellMetacharacters() {
        XCTAssertNil(WebViewDOMFallback.probeCommand(packageID: "com.x; rm -rf /"))
        XCTAssertNil(WebViewDOMFallback.probeCommand(packageID: "com.x`id`"))
        XCTAssertNil(WebViewDOMFallback.probeCommand(packageID: "com.x $(id)"))
        XCTAssertNil(WebViewDOMFallback.probeCommand(packageID: ""))
    }

    // MARK: - adb 出力の解析

    func testParseProbeReadsBothFacts() {
        let output = "1\n\(WebViewDOMFallback.probeMarker)\n    flags=0x2\n"
        let (system, app) = WebViewDOMFallback.parseProbe(output)
        XCTAssertEqual(system, true)
        XCTAssertEqual(app, true, "0x2 = FLAG_DEBUGGABLE")
    }

    /// **実測どおりの組**(2026-09-03): system=0, app の flags=0x0(release ビルド)
    func testParseProbeReadsTheObservedNonDebuggableCombination() {
        let output = "0\n\(WebViewDOMFallback.probeMarker)\n    flags=0x0\n"
        let (system, app) = WebViewDOMFallback.parseProbe(output)
        XCTAssertEqual(system, false)
        XCTAssertEqual(app, false)
    }

    func testParseProbeHandlesEmptyOutput() {
        let (system, app) = WebViewDOMFallback.parseProbe("")
        XCTAssertNil(system)
        XCTAssertNil(app)
    }

    /// マーカーが無い(adb が丸ごと失敗して別の文字列が来た等)は両方不明
    func testParseProbeHandlesMissingMarker() {
        let (system, app) = WebViewDOMFallback.parseProbe("adb: no devices/emulators found")
        XCTAssertNil(system)
        XCTAssertNil(app)
    }

    /// **行頭がちょうど `flags=0x` の行だけ**を採る(部分一致ではない)。実際の dumpsys の
    /// `privateFlags=` は大文字の `F` で始まり大小文字の違いだけで弾かれるが、それとは別に
    /// **行内のどこかに `flags=0x` が現れるだけでは採らない**設計であることを固定する
    /// (先頭以外での一致まで拾うと、値を含む別のキーを FLAG_DEBUGGABLE と誤読しかねない)
    func testAppDebuggableFlagRequiresTheMatchAtLineStart() {
        XCTAssertNil(WebViewDOMFallback.appDebuggableFlag(inDumpsysFlags: "    privateFlags=0x2\n"))
        XCTAssertNil(WebViewDOMFallback.appDebuggableFlag(inDumpsysFlags: "    xflags=0x2\n"),
                     "行頭でない一致まで拾っている")
    }

    /// 版によっては16進でなくテキスト羅列(`flags=[ HAS_CODE ... ]`)で来る。読めない形は nil
    func testAppDebuggableFlagReturnsNilForUnrecognizedFormat() {
        XCTAssertNil(WebViewDOMFallback.appDebuggableFlag(
            inDumpsysFlags: "    flags=[ HAS_CODE ALLOW_BACKUP ]\n"))
        XCTAssertNil(WebViewDOMFallback.appDebuggableFlag(inDumpsysFlags: ""))
    }

    /// `flags=0x` の直後に16進数字が1つも無い行(壊れた/切れた出力)は 0 に丸めず nil
    func testAppDebuggableFlagRejectsMissingHexDigits() {
        XCTAssertNil(WebViewDOMFallback.appDebuggableFlag(inDumpsysFlags: "    flags=0x\n"))
    }

    /// 複数行 grep されたときは**最初に見つかった `flags=0x` の行**を採る
    func testAppDebuggableFlagTakesTheFirstMatchingLine() {
        let text = "    flags=0x0\n    flags=0x2\n"
        XCTAssertEqual(WebViewDOMFallback.appDebuggableFlag(inDumpsysFlags: text), false)
    }

    // MARK: - 文言(黙らない。何が起きたか・なぜか・どう直すか)

    func testStructurallyClosedWarningExplainsWhyAndHowToFix() {
        let text = WebViewDOMFallback.warning(
            serial: "emulator-5554", packageID: "com.ftester.e2e", reason: .structurallyClosed)
        XCTAssertTrue(text.contains("[emulator-5554]"), "どの台か分からない: \(text)")
        XCTAssertTrue(text.contains("com.ftester.e2e"), "どのアプリか分からない: \(text)")
        XCTAssertTrue(text.contains("accessibility tree"), "何にフォールバックしたか無い: \(text)")
        XCTAssertTrue(text.contains("ro.debuggable=0"), "観測した事実が無い: \(text)")
        XCTAssertTrue(text.contains("FLAG_DEBUGGABLE"), "アプリ側の事実が無い: \(text)")
        XCTAssertTrue(text.contains("userdebug"), "直し方が無い: \(text)")
        XCTAssertTrue(text.contains("Play Store"), "受け手が選ぶ言葉(Play Store イメージ)で言っていない: \(text)")
        // **「この2つが false なら必ず開かない」と断定しない** —— アプリ自身が
        // setWebContentsDebuggingEnabled(true) を呼べばフラグに関わらず開く。3つ目の口を
        // 落とすと、その呼び出しがあるアプリの受け手に誤った直し方を指す
        XCTAssertTrue(text.contains("setWebContentsDebuggingEnabled(true)"),
                      "アプリ自身が開ける口に触れていない: \(text)")
        XCTAssertFalse(text.contains("at least one of those is true"),
                       "2つのフラグだけで開閉が決まると断定している: \(text)")
        XCTAssertTrue(text.contains("adb -s emulator-5554 shell getprop ro.debuggable"),
                      "確かめ方に実 serial が無い: \(text)")
    }

    func testAmbiguousWarningNamesTheSocketsAndRefusesToGuess() {
        let text = WebViewDOMFallback.warning(
            serial: "x", packageID: "com.foo",
            reason: .ambiguousSockets(["webview_devtools_remote_10", "webview_devtools_remote_11"]))
        XCTAssertTrue(text.contains("webview_devtools_remote_10, webview_devtools_remote_11"), text)
        XCTAssertTrue(text.contains("refuses to guess"), "推測しないことを言っていない: \(text)")
        XCTAssertFalse(text.contains("ro.debuggable=0"), "曖昧の回に構造的な理由を流用している: \(text)")
    }

    // MARK: - 診断メモ(出力回数の上限 = (serial, package) ごとに1回)

    func testDiagnosisIsNeededOnlyUntilMarked() {
        XCTAssertTrue(WebViewDOMFallback.needsDiagnosis(serial: "s1", package: "p"))
        WebViewDOMFallback.markDiagnosed(serial: "s1", package: "p")
        XCTAssertFalse(WebViewDOMFallback.needsDiagnosis(serial: "s1", package: "p"),
                       "結論が出たあとも問い合わせ・警告を繰り返す")
    }

    /// 台が違えば別に診断する(同じ台で package が違っても別)
    func testDiagnosisMemoIsKeyedBySerialAndPackage() {
        WebViewDOMFallback.markDiagnosed(serial: "s1", package: "p")
        XCTAssertTrue(WebViewDOMFallback.needsDiagnosis(serial: "s2", package: "p"))
        XCTAssertTrue(WebViewDOMFallback.needsDiagnosis(serial: "s1", package: "q"))
    }
}
