// Android の**ブラウザ本体**を DOM から読む経路の純粋ロジック(`AndroidWebViewDOM`。2026-08-13)。
//
// I/O(adb / CDP)はデバイスが要るのでここでは触らない。守るのは
// **ソケット/タブを取り違えないこと**(別アプリ・別タブの DOM を読まない)。
// 座標の写し・WebView 選択・木への差し込みは `FTCore.WebViewDOM`(iOS と共有)へ移設済みで、
// そちらは `Tests/FTCoreTests/WebViewDOMSnapshotTests.swift` が守る。

import XCTest
import FTCore
@testable import FTAndroid

final class AndroidWebViewDOMTests: XCTestCase {

    // MARK: - ブラウザの判定(既知集合の外はソケット名を持たない = a11y のまま)

    func testKnowsTheChromeSocket() {
        XCTAssertEqual(AndroidWebViewDOM.browserSocketName(packageID: "com.android.chrome"),
                       "chrome_devtools_remote")
    }

    /// 未実測のパッケージには推測で名前を付けない(誤った名前より「対象外」のほうが安全)
    func testUnknownPackageHasNoSocket() {
        XCTAssertNil(AndroidWebViewDOM.browserSocketName(packageID: "com.example.myapp"))
        XCTAssertNil(AndroidWebViewDOM.browserSocketName(packageID: "com.chrome.beta"))
    }

    // MARK: - 能動タブの候補順(**1つに決め打ちしない**。応答で決めるのは read の責務)

    private func target(_ title: String, _ url: String, ws: String, type: String = "page") -> [String: Any] {
        ["type": type, "title": title, "url": url, "webSocketDebuggerUrl": ws]
    }

    /// **実測した罠そのもの**: 同じページを2タブ開くと題名が一致するので、題名だけでは
    /// 背面タブを掴む。アドレス欄と**正規化して一致**するほうを先に試す
    func testPrefersTheTabWhoseUrlMatchesTheAddressBarExactly() {
        let ranked = AndroidWebViewDOM.rankedTabs(
            webViewLabel: "気象庁 | 天気予報", urlBarValue: "jma.go.jp/bosai/forecast/",
            targets: [
                target("Example Domain", "https://example.com/", ws: "ws://ex"),
                target("気象庁 | 天気予報", "https://www.jma.go.jp/bosai/forecast/#area_type=x", ws: "ws://bg"),
                target("気象庁 | 天気予報", "https://www.jma.go.jp/bosai/forecast/", ws: "ws://fg"),
            ])
        XCTAssertEqual(ranked.first, "ws://fg", "フラグメント付きの背面タブを先に試してはいけない")
    }

    /// アドレス欄はスキームと `www.` を隠す(実測)
    func testNormalizesSchemeAndWww() {
        XCTAssertEqual(AndroidWebViewDOM.normalizedURL("https://www.jma.go.jp/a/"), "jma.go.jp/a/")
        XCTAssertEqual(AndroidWebViewDOM.normalizedURL("http://jma.go.jp/a/#b"), "jma.go.jp/a/#b",
                       "フラグメントは残す(2タブを分ける唯一の材料になる)")
    }

    /// アドレス欄が一致しなければ題名を使う(手掛かりは複数)
    func testFallsBackToTheTitle() {
        let ranked = AndroidWebViewDOM.rankedTabs(
            webViewLabel: "Example Domain", urlBarValue: nil,
            targets: [target("Other", "https://o.test/", ws: "ws://o"),
                      target("Example Domain", "https://example.com/", ws: "ws://e")])
        XCTAssertEqual(ranked.first, "ws://e")
    }

    /// **候補は捨てない**(全部返す)。1つ目が背面で応答しないとき次を試すのは read の役目
    func testKeepsEveryCandidateSoTheCallerCanRetry() {
        let ranked = AndroidWebViewDOM.rankedTabs(
            webViewLabel: nil, urlBarValue: "example.com",
            targets: [target("A", "https://a.test/", ws: "ws://a"),
                      target("E", "https://example.com/", ws: "ws://e")])
        XCTAssertEqual(ranked, ["ws://e", "ws://a"])
    }

    /// 手掛かりが無ければ元の並びのまま(順序に意味は無いが、決定的であること)
    func testWithoutHintsTheOriginalOrderIsKept() {
        let ranked = AndroidWebViewDOM.rankedTabs(
            webViewLabel: nil, urlBarValue: nil,
            targets: [target("A", "https://a.test/", ws: "ws://a"),
                      target("B", "https://b.test/", ws: "ws://b")])
        XCTAssertEqual(ranked, ["ws://a", "ws://b"])
    }

    func testAboutBlankIsAValidPage() {
        XCTAssertEqual(AndroidWebViewDOM.rankedTabs(webViewLabel: nil, urlBarValue: nil,
            targets: [target("blank", "about:blank", ws: "ws://x")]), ["ws://x"])
    }

    func testSkipsDevtoolsOwnPagesAndNonPageTargets() {
        XCTAssertTrue(AndroidWebViewDOM.rankedTabs(webViewLabel: nil, urlBarValue: nil, targets: [
            target("devtools", "devtools://devtools/x", ws: "ws://d"),
            ["type": "service_worker", "webSocketDebuggerUrl": "ws://sw"],
            target("no socket", "http://a", ws: ""),
        ]).isEmpty)
    }

    /// **試行回数に上限がある**(外した候補1つにつき締切ぶん待つ)
    func testTabAttemptsAreBounded() {
        XCTAssertLessThanOrEqual(AndroidWebViewDOM.maxTabAttempts, 4)
        XCTAssertGreaterThan(AndroidWebViewDOM.maxTabAttempts, 1, "1つだけだと外したとき諦めてしまう")
    }

    /// 締切が無いと背面タブで snapshot ごと固まる(実測 183 秒)
    func testEvaluateHasADeadline() {
        XCTAssertGreaterThan(AndroidWebViewDOM.evaluateTimeout, 0)
        XCTAssertLessThanOrEqual(AndroidWebViewDOM.evaluateTimeout, 5)
    }

    // MARK: - 座標の写し・WebView 選択・差し込みは `FTCore.WebViewDOM` へ移設
    // (`Tests/FTCoreTests/WebViewDOMSnapshotTests.swift` に集約。ここは Android 固有の
    // density 倍・ソケット選択・url_bar 供給だけを守る)

    /// `#url_bar` の value を拾う(能動タブの手掛かり②の供給源)
    func testReadsTheUrlBarValue() {
        let bar = ElementInfo(ref: 1, type: "textField", identifier: "url_bar", label: nil,
                              value: "example.com", placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        XCTAssertEqual(AndroidWebViewDOM.urlBarValue(in: [bar]), "example.com")
    }

    // MARK: - forward port(pid が無いブラウザ経路の代替。並列 run での host port 衝突回避)

    func testStablePortIsDeterministicForTheSameSeed() {
        XCTAssertEqual(AndroidWebViewDOM.stablePort(seed: "emulator-5554"),
                       AndroidWebViewDOM.stablePort(seed: "emulator-5554"))
    }

    func testStablePortStaysWithinTheReservedRange() {
        let port = AndroidWebViewDOM.stablePort(seed: "192.168.1.23:5555")
        XCTAssertGreaterThanOrEqual(port, 10000)
        XCTAssertLessThan(port, 30000)
    }

    func testStablePortDiffersAcrossSerials() {
        // 決定論の要件を破らない範囲での実用上の確認(衝突しても機能は壊れないが、
        // 分散していないと並列 run での forward 競合が増える)
        XCTAssertNotEqual(AndroidWebViewDOM.stablePort(seed: "emulator-5554"),
                          AndroidWebViewDOM.stablePort(seed: "emulator-5556"))
    }
}
