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
        XCTAssertEqual(StepExecutor.edgeSignature(a), StepExecutor.edgeSignature(b))
    }

    /// **陰性対照**: 本当に送った後の木は端の署名でも別物(残骸を除きすぎて「動いていない」と言わない)
    func testATreeThatReallyMovedStillDiffers() throws {
        XCTAssertNotEqual(StepExecutor.edgeSignature(try fixture("top-1")),
                          StepExecutor.edgeSignature(try fixture("moved")))
    }

    /// **配線**: 先頭で木が揺れ続けても scrollToTop が上限まで払い切らない
    func testScrollToTopStopsAtTheTopDespiteTheFlickeringTree() async throws {
        let driver = try FlickeringTopDriver()
        let outcome = await StepExecutor(driver: driver, isAndroid: false)
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
