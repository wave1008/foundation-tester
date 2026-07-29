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
    func launch(bundleID: String) async throws { calls.append("launch") }
    func terminate() async throws { calls.append("terminate") }
    func tap(ref: Int) async throws { calls.append("tap(\(ref))") }
    func tap(x: Double, y: Double) async throws { calls.append("tap(xy)") }
    func type(ref: Int?, text: String) async throws { calls.append("type") }
    func swipe(_ direction: FTSwipeDirection) async throws { calls.append("swipe") }
    func press(ref: Int, duration: Double) async throws { calls.append("press") }
    func screenshot() async throws -> Data { calls.append("screenshot"); return Data() }
}

private func element(_ ref: Int, _ type: String, x: Double = 0, y: Double = 0,
                     width: Double = 100, height: Double = 100, web: Bool? = nil) -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: nil, label: nil, value: nil, placeholder: nil,
                enabled: true,
                frame: FTRect(x: x, y: y, width: width, height: height), depth: 0, web: web)
}

private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "app",
                     screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                     elements: elements, truncatedCount: 0)
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
}
