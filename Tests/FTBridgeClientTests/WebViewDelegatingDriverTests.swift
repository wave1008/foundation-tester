// WebView 画面だけを XCUITest へ委譲する切り替えの固定。
// ここが壊れると hybrid(利用者の既定エンジン)で WebView 画面が**要素ゼロ**に見えるか、
// 逆に通常画面まで XCUITest 経由になって全ステップが数百 ms 遅くなる。
// 実機/シミュレータ無しで確かめられるのは「どちらのドライバへ流れたか」だけなので、そこを固める。

import XCTest
@testable import FTBridgeClient
import FTCore

private final class FakeDriver: AppDriver, @unchecked Sendable {
    /// snapshot() が返す列(呼ばれるたびに次へ進み、尽きたら最後を返し続ける)
    var snapshots: [SnapshotResponse]
    /// swipe が投げるエラー(501 フォールバックの検証用)
    var swipeError: Error?
    private(set) var snapshotCount = 0
    private(set) var calls: [String] = []

    init(snapshots: [SnapshotResponse]) {
        self.snapshots = snapshots
    }

    func snapshot() async throws -> SnapshotResponse {
        let index = min(snapshotCount, snapshots.count - 1)
        snapshotCount += 1
        calls.append("snapshot")
        return snapshots[index]
    }

    func status() async throws -> StatusResponse {
        calls.append("status")
        return StatusResponse(ready: true, device: "fake", osVersion: "", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws { calls.append("install") }
    func uninstall(bundleID: String) async throws { calls.append("uninstall") }
    func isAppForeground(bundleID: String) async throws -> Bool {
        calls.append("isAppForeground(\(bundleID))")
        return false
    }
    func foregroundAppID() async throws -> String? { calls.append("foregroundAppID"); return nil }
    func launch(bundleID: String) async throws { calls.append("launch") }
    func terminate() async throws { calls.append("terminate") }
    func tap(ref: Int) async throws { calls.append("tap(\(ref))") }
    func tap(x: Double, y: Double) async throws { calls.append("tap(\(x),\(y))") }
    func type(ref: Int?, text: String) async throws {
        calls.append(ref.map { "type(\($0))" } ?? "type(focused)")
    }
    func swipe(_ direction: FTSwipeDirection) async throws {
        calls.append("swipe")
        if let swipeError { throw swipeError }
    }
    /// 既定実装は swipe(_:) を呼ぶだけなので、用途の行き先を見るには受けて記録する
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
               path: FTSwipePath?) async throws {
        calls.append(intent == .gesture ? "swipe" : "swipe(scroll)")
        if let swipeError { throw swipeError }
    }
    func press(ref: Int, duration: Double) async throws { calls.append("press(\(ref))") }
    func press(x: Double, y: Double, duration: Double) async throws {
        calls.append("press(\(x),\(y))")
    }
    func clearInput(ref: Int?) async throws {
        calls.append(ref.map { "clear(\($0))" } ?? "clear(focused)")
    }
    func screenshot() async throws -> Data { calls.append("screenshot"); return Data() }
}

private func element(_ ref: Int, _ type: String, x: Double = 0, y: Double = 0,
                     width: Double = 100, height: Double = 100, web: Bool? = nil) -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: nil, label: nil, value: nil, placeholder: nil,
                enabled: true,
                frame: FTRect(x: x, y: y, width: width, height: height), depth: 0, web: web)
}

private func snapshot(_ elements: [ElementInfo], webViewPath: String? = nil) -> SnapshotResponse {
    var response = SnapshotResponse(sessionBundleID: "app",
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: elements, truncatedCount: 0)
    response.webViewPath = webViewPath
    return response
}

final class WebViewDelegatingDriverTests: XCTestCase {

    /// 通常画面: in-app の結果をそのまま返し、操作も in-app へ行く(XCUITest を触らない)
    func testNonWebViewScreenStaysOnPrimary() async throws {
        let primary = FakeDriver(snapshots: [snapshot([element(1, "Button")])])
        let delegated = FakeDriver(snapshots: [snapshot([element(1, "Button")])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        try await driver.tap(ref: 1)

        XCTAssertEqual(delegated.calls, [], "通常画面で XCUITest を触ってはいけない")
        XCTAssertEqual(primary.calls, ["snapshot", "tap(1)"])
    }

    /// WebView 画面: snapshot は XCUITest のものを返し、ref を使う操作も XCUITest へ行く。
    /// **返す snapshot と ref の宛先が一致していること**が不変条件(混ざると別要素を叩く)
    func testWebViewScreenDelegatesSnapshotAndTap() async throws {
        // in-app は WKWebView を1要素として出すだけ(中身は原理的に見えない)
        let primary = FakeDriver(snapshots: [snapshot([element(1, "WebView")])])
        let delegatedSnapshot = snapshot([element(1, "WebView"), element(2, "StaticText", y: 10)])
        let delegated = FakeDriver(snapshots: [delegatedSnapshot])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        let result = try await driver.snapshot()
        try await driver.tap(ref: 2)

        XCTAssertEqual(result.elements.count, 2, "XCUITest 側の snapshot が返るはず")
        XCTAssertEqual(delegated.calls, ["snapshot", "tap(2)"])
        XCTAssertEqual(primary.calls, ["snapshot"])
    }

    /// XCUITest 側は Web コンテンツの a11y 活性化が遅れる(実測 約2.3秒)。
    /// 中身が空のうちは取り直す = 最初の1回で「要素ゼロ」を返してしまわない
    func testWaitsForWebContentToAppear() async throws {
        let primary = FakeDriver(snapshots: [snapshot([element(1, "WebView")])])
        let empty = snapshot([element(1, "WebView")])
        let filled = snapshot([element(1, "WebView"), element(2, "StaticText", y: 10)])
        let delegated = FakeDriver(snapshots: [empty, empty, filled])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        let result = try await driver.snapshot()

        XCTAssertEqual(result.elements.count, 2)
        XCTAssertEqual(delegated.snapshotCount, 3, "空のあいだは取り直す")
    }

    /// 一度中身が見えたら待ち直さない(空ページや全要素が画面外の画面で毎ステップ待たされない)
    func testDoesNotWaitAgainAfterContentSeen() async throws {
        let primary = FakeDriver(snapshots: [snapshot([element(1, "WebView")])])
        let filled = snapshot([element(1, "WebView"), element(2, "StaticText", y: 10)])
        let empty = snapshot([element(1, "WebView")])
        let delegated = FakeDriver(snapshots: [filled, empty])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        let second = try await driver.snapshot()

        XCTAssertEqual(second.elements.count, 1, "2回目は待たずにそのまま返す")
        XCTAssertEqual(delegated.snapshotCount, 2)
    }

    /// WebView 画面を離れたら委譲を畳む(離れた後も XCUITest へ行き続けると全ステップが遅くなる)
    func testLeavingWebViewScreenEndsDelegation() async throws {
        let primary = FakeDriver(snapshots: [snapshot([element(1, "WebView")]),
                                             snapshot([element(1, "Button")])])
        let delegated = FakeDriver(snapshots: [snapshot([element(1, "WebView"),
                                                         element(2, "StaticText", y: 10)])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()   // WebView 画面
        _ = try await driver.snapshot()   // 通常画面へ戻る
        try await driver.tap(ref: 1)

        XCTAssertEqual(primary.calls.last, "tap(1)", "委譲は畳まれ in-app へ戻る")
    }

    /// launch は必ず in-app(注入起動)。委譲状態も畳む
    func testLaunchGoesToPrimaryAndResetsDelegation() async throws {
        let primary = FakeDriver(snapshots: [snapshot([element(1, "WebView")])])
        let delegated = FakeDriver(snapshots: [snapshot([element(1, "WebView"),
                                                         element(2, "StaticText", y: 10)])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        try await driver.launch(bundleID: "app")
        try await driver.tap(ref: 1)

        XCTAssertEqual(primary.calls, ["snapshot", "launch", "tap(1)"])
        XCTAssertEqual(delegated.calls, ["snapshot"], "launch 後は in-app へ戻る")
    }

    /// in-app が DOM で中身まで読めていれば委譲しない(委譲すると 1手 3ms → 378ms になる)
    func testDoesNotDelegateWhenInAppReadTheDOM() async throws {
        let primary = FakeDriver(snapshots: [snapshot([element(1, "WebView"),
                                                       element(2, "StaticText", y: 10, web: true)])])
        let delegated = FakeDriver(snapshots: [snapshot([element(1, "WebView")])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        let result = try await driver.snapshot()
        try await driver.tap(ref: 2)

        XCTAssertEqual(delegated.calls, [], "DOM が読めているのに XCUITest を触ってはいけない")
        XCTAssertEqual(primary.calls, ["snapshot", "tap(2)"])
        XCTAssertEqual(result.elements.count, 2)
    }

    /// **幾何では判定しない**: Compose iOS の interop 容器は WebView と同じ矩形を持つため、
    /// 「中に何か居る = 読めている」と誤判定して委譲が止まり、画面が空のまま進む(2026-07-29 実害)
    func testDelegatesWhenOnlyInteropContainerOverlapsWebView() async throws {
        let primary = FakeDriver(snapshots: [snapshot([element(1, "WebView"),
                                                       element(2, "Other")])])   // 同じ矩形・web なし
        let delegated = FakeDriver(snapshots: [snapshot([element(1, "WebView"),
                                                         element(2, "StaticText", y: 10)])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()

        XCTAssertEqual(delegated.calls, ["snapshot"], "読めていないのだから委譲すること")
    }

    /// 委譲中でも**スクロール目的の swipe は in-app を先に試す**(WKWebView 内の WKScrollView は
    /// contentOffset で動く)。ここが委譲先へ行くと 1スクロールが実スワイプ + 委譲 snapshot になり、
    /// Compose/Flutter の WebView シナリオが 3.5 倍遅くなる(2026-08-01 実測)
    func testScrollSwipeTriesPrimaryWhileDelegating() async throws {
        let (driver, primary, delegated) = try await delegatingDriver()
        try await driver.swipe(.up, intent: .search, path: nil)

        XCTAssertEqual(primary.calls, ["snapshot", "swipe(scroll)"])
        XCTAssertEqual(delegated.calls, ["snapshot"], "スクロールで XCUITest を触らない")
    }

    /// in-app が「この画面では無理」(501)と言ったら従来どおり XCUITest へ落とす
    func testScrollSwipeFallsBackToDelegatedOn501() async throws {
        let (driver, primary, delegated) = try await delegatingDriver()
        primary.swipeError = DriverError.badResponse(status: 501, body: "no scroll")

        try await driver.swipe(.up, intent: .search, path: nil)

        XCTAssertEqual(delegated.calls, ["snapshot", "swipe(scroll)"])
    }

    /// 501 以外は握りつぶさない(一時的競合を「非対応」と読むと別画面を触りかねない)
    func testScrollSwipePropagatesNon501() async throws {
        let (driver, primary, delegated) = try await delegatingDriver()
        primary.swipeError = DriverError.badResponse(status: 409, body: "busy")

        do {
            try await driver.swipe(.up, intent: .search, path: nil)
            XCTFail("409 は伝播すること")
        } catch {}
        XCTAssertEqual(delegated.calls, ["snapshot"], "409 で XCUITest へ回さない")
    }

    /// ジェスチャ目的の swipe(DSL の `swipe`)は従来どおり委譲先へ。
    /// in-app は interop のジェスチャを駆動できないので、ここを in-app へ回すと黙って空振りする
    func testGestureSwipeStillGoesToDelegated() async throws {
        let (driver, primary, delegated) = try await delegatingDriver()
        try await driver.swipe(.up, intent: .gesture, path: nil)

        XCTAssertEqual(delegated.calls, ["snapshot", "swipe"])
        XCTAssertEqual(primary.calls, ["snapshot"])
    }

    /// 委譲状態(WebView 画面)に入った driver と、その両側の fake
    private func delegatingDriver() async throws
        -> (WebViewDelegatingDriver, FakeDriver, FakeDriver) {
        let primary = FakeDriver(snapshots: [snapshot([element(1, "WebView")])])
        let delegated = FakeDriver(snapshots: [snapshot([element(1, "WebView"),
                                                         element(2, "StaticText", y: 10)])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)
        _ = try await driver.snapshot()
        return (driver, primary, delegated)
    }

    /// 中身の判定は「webView の矩形の中に webView 以外が居るか」。
    /// 画面外(重ならない)要素だけでは「中身が見えた」とみなさない
    func testHasWebContentIgnoresElementsOutsideWebViewFrame() {
        let outside = snapshot([element(1, "WebView", x: 0, y: 0, width: 100, height: 100),
                                element(2, "StaticText", x: 200, y: 200)])
        XCTAssertFalse(WebViewDelegatingDriver.hasWebContent(outside))

        let inside = snapshot([element(1, "WebView", x: 0, y: 0, width: 100, height: 100),
                               element(2, "StaticText", x: 10, y: 10, width: 20, height: 20)])
        XCTAssertTrue(WebViewDelegatingDriver.hasWebContent(inside))
    }
    // MARK: - domInterop(読みは DOM・触るのは XCUITest の座標)

    /// interop ホスト: snapshot は in-app の DOM をそのまま返す(委譲すると 3ms → 378ms)。
    /// **ref を使う操作は座標へ解決して XCUITest へ**渡り、ref は渡らない(名前空間の不変条件)
    func testDomInteropReadsFromPrimaryAndTapsByCoordinate() async throws {
        let dom = snapshot([element(1, "WebView"), element(2, "Link", x: 20, y: 40, width: 60, height: 20, web: true)],
                           webViewPath: "dom-interop")
        let primary = FakeDriver(snapshots: [dom])
        let delegated = FakeDriver(snapshots: [snapshot([])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        let result = try await driver.snapshot()
        try await driver.tap(ref: 2)

        XCTAssertEqual(result.elements.count, 2, "in-app の DOM snapshot が返るはず")
        // 中心 = (20+60/2, 40+20/2)
        XCTAssertEqual(delegated.calls, ["snapshot", "tap(50.0,50.0)"],
                       "暖機の snapshot 1回のあと、座標で渡すこと(ref を渡さない)")
        XCTAssertEqual(primary.calls, ["snapshot"], "委譲 snapshot を撮らない")
    }

    /// press も座標へ解決する
    func testDomInteropPressResolvesToCoordinate() async throws {
        let dom = snapshot([element(1, "WebView"), element(2, "Button", x: 0, y: 0, width: 10, height: 10, web: true)],
                           webViewPath: "dom-interop")
        let primary = FakeDriver(snapshots: [dom])
        let delegated = FakeDriver(snapshots: [snapshot([])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        try await driver.press(ref: 2, duration: 1)

        XCTAssertEqual(delegated.calls, ["snapshot", "press(5.0,5.0)"])
    }

    /// type は「座標タップでフォーカス → ref なしで入力」の順(DOM への値代入は不採用)
    func testDomInteropTypeFocusesByCoordinateThenTypesWithoutRef() async throws {
        let dom = snapshot([element(1, "WebView"), element(2, "TextField", x: 0, y: 0, width: 40, height: 20, web: true)],
                           webViewPath: "dom-interop")
        let primary = FakeDriver(snapshots: [dom])
        let delegated = FakeDriver(snapshots: [snapshot([])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        try await driver.type(ref: 2, text: "hello")

        XCTAssertEqual(delegated.calls, ["snapshot", "tap(20.0,10.0)", "type(focused)"])
    }

    /// 直近 snapshot に無い ref は座標に解決できない。**黙って別経路へ流さない**
    func testDomInteropUnknownRefFails() async throws {
        let dom = snapshot([element(1, "WebView"), element(2, "Link", web: true)], webViewPath: "dom-interop")
        let primary = FakeDriver(snapshots: [dom])
        let delegated = FakeDriver(snapshots: [snapshot([])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        do {
            try await driver.tap(ref: 99)
            XCTFail("未知の ref は失敗するはず")
        } catch {
            XCTAssertTrue("\(error)".contains("99"), "どの ref か分かる文言であること: \(error)")
        }
        XCTAssertEqual(delegated.calls, ["snapshot"], "暖機以外で XCUITest を触ってはいけない")
    }

    /// WebView 画面を離れたら domInterop も畳む(古い ref/座標を持ち越さない)
    func testDomInteropResetsWhenLeavingTheScreen() async throws {
        let dom = snapshot([element(1, "WebView"), element(2, "Link", web: true)], webViewPath: "dom-interop")
        let plain = snapshot([element(1, "Button")])
        let primary = FakeDriver(snapshots: [dom, plain])
        let delegated = FakeDriver(snapshots: [snapshot([])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        _ = try await driver.snapshot()
        try await driver.tap(ref: 1)

        // 入場時の暖機1回だけが残る。通常画面へ戻った後は一切触らない
        XCTAssertEqual(delegated.calls, ["snapshot"], "通常画面へ戻ったら XCUITest を触らない")
        XCTAssertEqual(primary.calls, ["snapshot", "snapshot", "tap(1)"])
    }

    /// 中心点計算そのものを非キリのいい値で検証する(丸め誤差や x/y 取り違えが
    /// キリのいい値だけでは見えないため)
    func testDomInteropCenterPointMathWithFractionalFrame() async throws {
        let dom = snapshot([element(1, "WebView"),
                            element(2, "Link", x: 15, y: 8, width: 41, height: 23, web: true)],
                           webViewPath: "dom-interop")
        let primary = FakeDriver(snapshots: [dom])
        let delegated = FakeDriver(snapshots: [snapshot([])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        try await driver.tap(ref: 2)

        // 中心 = (15+41/2, 8+23/2) = (35.5, 19.5)
        XCTAssertEqual(delegated.calls, ["snapshot", "tap(35.5,19.5)"])
    }

    /// "dom"(interop でない)は従来どおり primary 一本のまま。"dom-interop" とだけ比較する文字列一致で
    /// 判定しているので、ここが崩れると uikit ホストの WebView まで座標変換に回りかねない
    func testWebViewPathDomExplicitlyStaysNonDomInterop() async throws {
        let dom = snapshot([element(1, "WebView"), element(2, "StaticText", web: true)],
                           webViewPath: "dom")
        let primary = FakeDriver(snapshots: [dom])
        let delegated = FakeDriver(snapshots: [snapshot([])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        try await driver.tap(ref: 2)

        XCTAssertEqual(delegated.calls, [], "\"dom\" は domInterop ではない: XCUITest を触ってはいけない")
        XCTAssertEqual(primary.calls, ["snapshot", "tap(2)"])
    }

    /// **暖機は画面ごとに1回だけ**。毎 snapshot 撃つと委譲と同じコストに戻り、この機能の意味が消える
    func testDomInteropWarmsDelegatedOnlyOncePerScreen() async throws {
        let dom = snapshot([element(1, "WebView"), element(2, "Link", web: true)], webViewPath: "dom-interop")
        let primary = FakeDriver(snapshots: [dom])
        let delegated = FakeDriver(snapshots: [snapshot([])])
        let driver = WebViewDelegatingDriver(primary: primary, delegated: delegated)

        _ = try await driver.snapshot()
        _ = try await driver.snapshot()
        _ = try await driver.snapshot()
        try await driver.tap(ref: 2)

        XCTAssertEqual(delegated.calls.filter { $0 == "snapshot" }.count, 1,
                       "暖機は入場時の1回だけ(毎回撮ると 3ms → 378ms へ逆戻り)")
    }

}
