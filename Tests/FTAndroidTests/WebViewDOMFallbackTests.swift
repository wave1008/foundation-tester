// Android アプリ自身の WebView の DOM 読みが取れず a11y へ黙って落ちる経路に足した警告
// (WebViewDOMFallback)の判定を固定する。実機/エミュレータ依存の部分(adb)は外し、
// 純粋な判定・文言・once ゲートだけを見る(WebViewShotCompositeTests と同型)。

import XCTest
@testable import FTAndroid

final class WebViewDOMFallbackTests: XCTestCase {

    // MARK: - 理由の判定(観測した2つの事実 → Reason)

    /// **両方が確実に非 debuggable のときだけ**構造的に閉じていると言う
    /// (2026-09-03 の実測: M1Max/M1Ultra が ro.debuggable=0 かつ release ビルドで決定的に赤)
    func testBothNonDebuggableIsStructurallyClosed() {
        XCTAssertEqual(WebViewDOMFallback.reason(systemDebuggable: false, appDebuggable: false),
                       .structurallyClosed(systemDebuggable: false, appDebuggable: false))
    }

    /// システム・アプリのどちらかが debuggable ならソケットは開くはずなので、
    /// 読めなかった理由は「それ以外」(断定しない)
    func testEitherDebuggableIsOther() {
        XCTAssertEqual(WebViewDOMFallback.reason(systemDebuggable: true, appDebuggable: false),
                       .other(systemDebuggable: true, appDebuggable: false))
        XCTAssertEqual(WebViewDOMFallback.reason(systemDebuggable: false, appDebuggable: true),
                       .other(systemDebuggable: false, appDebuggable: true))
        XCTAssertEqual(WebViewDOMFallback.reason(systemDebuggable: true, appDebuggable: true),
                       .other(systemDebuggable: true, appDebuggable: true))
    }

    /// 判定できなかった側(nil)は false と混ぜない —— 「開くはず」の可能性を残したまま
    /// 「構造的に閉じている」と言い切らない
    func testUnknownFactsAreNotTreatedAsFalse() {
        XCTAssertEqual(WebViewDOMFallback.reason(systemDebuggable: nil, appDebuggable: false),
                       .other(systemDebuggable: nil, appDebuggable: false))
        XCTAssertEqual(WebViewDOMFallback.reason(systemDebuggable: false, appDebuggable: nil),
                       .other(systemDebuggable: false, appDebuggable: nil))
        XCTAssertEqual(WebViewDOMFallback.reason(systemDebuggable: nil, appDebuggable: nil),
                       .other(systemDebuggable: nil, appDebuggable: nil))
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
            serial: "emulator-5554", packageID: "com.ftester.e2e",
            reason: .structurallyClosed(systemDebuggable: false, appDebuggable: false))
        XCTAssertTrue(text.contains("[emulator-5554]"), "どの台か分からない: \(text)")
        XCTAssertTrue(text.contains("com.ftester.e2e"), "どのアプリか分からない: \(text)")
        XCTAssertTrue(text.contains("accessibility tree"), "何にフォールバックしたか無い: \(text)")
        XCTAssertTrue(text.contains("ro.debuggable=0"), "観測した事実が無い: \(text)")
        XCTAssertTrue(text.contains("FLAG_DEBUGGABLE"), "アプリ側の事実が無い: \(text)")
        XCTAssertTrue(text.contains("userdebug"), "直し方が無い: \(text)")
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

    /// `.other` は断定しない —— 「構造的に閉じている」の言い回しを流用しない
    func testOtherWarningDoesNotClaimStructurallyClosed() {
        let text = WebViewDOMFallback.warning(
            serial: "x", packageID: "com.foo", reason: .other(systemDebuggable: true, appDebuggable: nil))
        XCTAssertFalse(text.contains("is not open here"), "断定していないはずなのに断定文言が出ている: \(text)")
        XCTAssertFalse(text.contains("FLAG_DEBUGGABLE"), "観測していない事実を断定している: \(text)")
        XCTAssertTrue(text.contains("Could not determine why"), text)
        XCTAssertTrue(text.contains("ro.debuggable=1"), "観測できた事実が反映されていない: \(text)")
        XCTAssertTrue(text.contains("app debuggable flag=unknown"), "不明を隠している: \(text)")
    }

    // MARK: - once ゲート

    func testShouldWarnFiresOncePerSerialAcrossCalls() {
        let a = "test-serial-\(UUID().uuidString)"
        let b = "test-serial-\(UUID().uuidString)"
        XCTAssertTrue(WebViewDOMFallback.shouldWarn(serial: a))
        XCTAssertFalse(WebViewDOMFallback.shouldWarn(serial: a))
        XCTAssertFalse(WebViewDOMFallback.shouldWarn(serial: a))
        XCTAssertTrue(WebViewDOMFallback.shouldWarn(serial: b), "別の台は別に1回言う")
    }
}
