// scrollToEdge の端の判定は「描かれていない残骸」を除いた署名で比べる(`StepExecutor.edgeSignature`)。
// 固定データは E2E-iOS のスクロール画面(XCUITest)で採った実物: 一覧の先頭に止まったままスワイプを
// 繰り返すと、容器の縁へ寄せて積まれた行ラベルの顔ぶれが揺れて木が 63 ↔ 64 要素で入れ替わる
// (top-1 / top-2)。moved は1回送った後(先頭が row_08)= 本当に動いた陰性対照。

import XCTest
@testable import FTCore

private func fixture(_ name: String) throws -> SnapshotResponse {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/EdgeSignature/ios-xcuitest-list-\(name).json")
    return try JSONDecoder().decode(SnapshotResponse.self, from: Data(contentsOf: url))
}

/// 素の署名(settledSignature と同じ形 = 型と座標を全要素ぶん)
private func rawSignature(_ snapshot: SnapshotResponse) -> String {
    snapshot.elements.map { "\($0.type)|\($0.frame.x),\($0.frame.y)" }.joined(separator: ",")
}

final class EdgeSignatureTests: XCTestCase {

    /// **本命**: 先頭に止まったままの2枚は、素の署名では別物だが端の署名では同じ
    func testTwoTreesAtTheTopMatchOnceLeftoversAreDropped() throws {
        let a = try fixture("top-1"), b = try fixture("top-2")
        XCTAssertNotEqual(rawSignature(a), rawSignature(b), "固定データが witness になっていない")
        XCTAssertEqual(StepExecutor.edgeSignature(a, contentRegion: nil), StepExecutor.edgeSignature(b, contentRegion: nil))
    }

    /// **陰性対照**: 本当に送った後の木は端の署名でも別物(残骸を除きすぎて「動いていない」と言わない)
    func testATreeThatReallyMovedStillDiffers() throws {
        XCTAssertNotEqual(StepExecutor.edgeSignature(try fixture("top-1"), contentRegion: nil),
                          StepExecutor.edgeSignature(try fixture("moved"), contentRegion: nil))
    }

    /// **witness**: 同じレイアウトの面が同じ位置へスナップする容器(E2EX-CMP の HorizontalPager)。
    /// 型と座標は同じでも id とラベルが違えば「動いた」(型と座標だけだと page=4 → 2 で端と誤認した)
    func testPagesWithTheSameLayoutButDifferentContentDiffer() {
        let pager = FTRect(x: 0, y: 150, width: 400, height: 300)
        func page(_ n: Int) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [
                                ElementInfo(ref: 1, type: "staticText", identifier: "txt_page_\(n)",
                                            label: "ページ \(n)", value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: 16, y: 200, width: 100, height: 24), depth: 1),
                                ElementInfo(ref: 2, type: "button", identifier: "btn_page_\(n)",
                                            label: "ページ \(n) のボタン", value: nil, placeholder: nil,
                                            enabled: true,
                                            frame: FTRect(x: 16, y: 240, width: 180, height: 48), depth: 1),
                             ],
                             truncatedCount: 0)
        }
        XCTAssertNotEqual(StepExecutor.edgeSignature(page(4), contentRegion: pager),
                          StepExecutor.edgeSignature(page(3), contentRegion: pager))
        XCTAssertEqual(StepExecutor.edgeSignature(page(3), contentRegion: pager),
                       StepExecutor.edgeSignature(page(3), contentRegion: pager))
    }

    /// **witness**: 容器の外の表示(引っ張って更新の回数)は送りの副作用で変わる。これで「動いた」と
    /// 数えると端に着いても止まらない(Flutter の RefreshIndicator で scrollToTop が refresh=25)
    func testTextOutsideTheScrolledContainerIsIgnored() {
        func screen(count: Int) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [
                                ElementInfo(ref: 1, type: "staticText", identifier: "txt_refresh_count",
                                            label: "refresh=\(count)", value: nil, placeholder: nil,
                                            enabled: true, frame: FTRect(x: 16, y: 100, width: 100, height: 24),
                                            depth: 1),
                                ElementInfo(ref: 2, type: "staticText", identifier: "row_00", label: "行 00",
                                            value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: 16, y: 200, width: 300, height: 50), depth: 2),
                             ],
                             truncatedCount: 0)
        }
        let list = FTRect(x: 0, y: 150, width: 400, height: 650)
        XCTAssertEqual(StepExecutor.edgeSignature(screen(count: 1), contentRegion: list),
                       StepExecutor.edgeSignature(screen(count: 2), contentRegion: list))
    }

    /// **witness**: 容器が画面全体(CMP の XCUITest)だと回数の表示も容器の中に入る。固有の id を持つ文字表示は
    /// ラベルを比べないので、上端で払うたびに更新が走っても「動いた」に数えない(E2EX-CMP 引っ張って更新で 120 秒)
    func testUniquelyIdentifiedTextInsideAFullScreenContainerIgnoresItsLabel() {
        func screen(count: Int) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                             elements: [
                                ElementInfo(ref: 1, type: "staticText", identifier: "txt_refresh_count",
                                            label: "refresh=\(count)", value: nil, placeholder: nil,
                                            enabled: true, frame: FTRect(x: 16, y: 142, width: 78, height: 24),
                                            depth: 1),
                             ],
                             truncatedCount: 0)
        }
        let whole = FTRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertEqual(StepExecutor.edgeSignature(screen(count: 4), contentRegion: whole),
                       StepExecutor.edgeSignature(screen(count: 5), contentRegion: whole))
    }

    /// 同じ id を使い回す文字表示・id の無い文字表示はラベルで比べたまま(並び直しで中身だけ変わる一覧)
    func testSharedOrMissingIdTextStillComparesLabels() {
        func rows(_ base: Int, id: String?) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                             elements: (0..<2).map { i in
                                ElementInfo(ref: i + 1, type: "staticText", identifier: id,
                                            label: "行 \(base + i)", value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: 16, y: Double(200 + 56 * i), width: 300, height: 24),
                                            depth: 2)
                             },
                             truncatedCount: 0)
        }
        let whole = FTRect(x: 0, y: 0, width: 402, height: 874)
        for id in ["row", nil] as [String?] {
            XCTAssertNotEqual(StepExecutor.edgeSignature(rows(0, id: id), contentRegion: whole),
                              StepExecutor.edgeSignature(rows(10, id: id), contentRegion: whole), "\(id ?? "nil")")
        }
    }

    /// **配線**: 先頭で木が揺れ続けても scrollToTop が上限まで払い切らない
    func testScrollToTopStopsAtTheTopDespiteTheFlickeringTree() async throws {
        let driver = try FlickeringTopDriver()
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "scrollToEdge", direction: "down", maxSwipes: 20))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse((outcome.driverFallback ?? "").contains("stopped at the limit"),
                       outcome.driverFallback ?? "")
        XCTAssertLessThanOrEqual(driver.swipes, 4, "端に着いた後も振り続けた(\(driver.swipes) 回)")
    }
}

/// 1回目のスワイプで先頭に着き、以後はスワイプのたびに top-1 / top-2 を交互に返す
/// (スワイプの間は同じ木 = 整定はする。端の判定だけが揺れる実物の形)。端は申告しない(XCUITest と同じ)
private final class FlickeringTopDriver: AppDriver {
    private let moved: SnapshotResponse
    private let tops: [SnapshotResponse]
    private(set) var swipes = 0

    init() throws {
        moved = try fixture("moved")
        tops = [try fixture("top-1"), try fixture("top-2")]
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipes += 1
    }
    func snapshot() async throws -> SnapshotResponse {
        swipes == 0 ? moved : tops[(swipes - 1) % 2]
    }
}

/// 上端で送るたびに「上端」と「上端 + 更新中の表示」を行き来する一覧(Flutter の RefreshIndicator の形)。
/// 前の状態に戻ったのは進んでいないので、上限まで送り続けない
final class EdgeOscillationTests: XCTestCase {
    func testScrollToTopStopsWhenTheTreeOscillatesAtTheTop() async throws {
        let driver = OscillatingTopDriver()
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "scrollToEdge", direction: "down", maxSwipes: 20))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse((outcome.driverFallback ?? "").contains("stopped at the limit"),
                       outcome.driverFallback ?? "")
        XCTAssertLessThanOrEqual(driver.swipes, 6, "上端で送り続けた(\(driver.swipes) 回)")
    }
}

private final class OscillatingTopDriver: AppDriver {
    private(set) var swipes = 0
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipes += 1
    }
    /// 1回目の送りで上端に着き、以後は送るたびに更新中の表示が出入りする
    func snapshot() async throws -> SnapshotResponse {
        var elements = [ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 100, width: 400, height: 700), depth: 0,
                                    scrollable: true)]
        let topRow = swipes == 0 ? 5 : 0
        for i in 0..<5 {
            elements.append(ElementInfo(ref: 2 + i, type: "button", identifier: "row_\(topRow + i)", label: nil,
                                        value: nil, placeholder: nil, enabled: true,
                                        frame: FTRect(x: 16, y: 150 + Double(i) * 100, width: 368, height: 90),
                                        depth: 1))
        }
        if swipes > 0, swipes % 2 == 1 {
            elements.append(ElementInfo(ref: 20, type: "other", identifier: nil, label: "Refresh", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 180, y: 120, width: 40, height: 40), depth: 1))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: elements, truncatedCount: 0)
    }
}
