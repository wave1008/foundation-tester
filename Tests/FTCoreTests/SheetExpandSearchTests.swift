// 半開きシートの中で探索が1度も動かずに止まったら、scrollFrame の中で1回だけ広げるドラッグを撃って探し直す
// (StepExecutor.sheetExpandDrag)。E2EY-CMP のシート S0020(XCUITest)で、探索の短く遅い送りがシートの
// しきい値に届かず戻り、「nothing moved at all」で赤だった
import XCTest
@testable import FTCore

/// drag を受けたらシートが全開になる(探索の swipe では何も変わらない)フェイク
private final class SheetDriver: AppDriver {
    private(set) var drags: [(fromY: Double, toY: Double)] = []
    private var expanded = false
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func row(_ i: Int, y: Double) -> ElementInfo {
        ElementInfo(ref: 10 + i, type: "button", identifier: String(format: "queue_row_%02d", i),
                    label: String(format: "キュー %02d", i), value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 402, height: 56), depth: 3)
    }

    private var elements: [ElementInfo] {
        let result = ElementInfo(ref: 1, type: "staticText", identifier: "txt_player_result", label: "player=none",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 16, y: 160, width: 99, height: 24), depth: 2)
        let list = expanded ? FTRect(x: 0, y: 382, width: 402, height: 458) : FTRect(x: 0, y: 659, width: 402, height: 215)
        let container = ElementInfo(ref: 2, type: "other", identifier: "list_queue", label: nil, value: nil,
                                    placeholder: nil, enabled: true, frame: list, depth: 2, scrollable: true)
        let rows = expanded ? [row(20, y: 382), row(21, y: 438), row(22, y: 494)]
                            : [row(0, y: 659), row(1, y: 715), row(2, y: 771)]
        return [result, container] + rows
    }

    func status() async throws -> StatusResponse { StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil) }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0,
                         keyboardShown: nil, keyboardFrame: nil, overlayWindowFrames: nil)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        drags.append((fromY, toY))
        expanded = true
    }
}

final class SheetExpandSearchTests: XCTestCase {

    private func searchStep() -> FlowStep {
        var step = FlowStep(action: "tap", locator: FlowLocator(id: "queue_row_21"))
        step.direction = FTSwipeDirection.up.rawValue
        step.maxSwipes = 6
        step.scrollFrame = FlowLocator(id: "list_queue")
        return step
    }

    func testExpandsAHalfOpenSheetOnceAndFindsTheRow() async {
        let driver = SheetDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())

        let outcome = await executor.execute(searchStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.drags.count, 1, "広げるドラッグは1回だけ")
        let drag = driver.drags[0]
        XCTAssertGreaterThanOrEqual(drag.fromY - drag.toY, StepExecutor.minSheetExpandDistance,
                                    "容器の高さぶん上へ払う")
        XCTAssertLessThan(drag.fromY, 874 - StepExecutor.bottomUncoveredBand, "画面下端の空白帯から始めない")
        XCTAssertTrue((outcome.driverFallback ?? "").contains("the sheet was expanded"), outcome.driverFallback ?? "")

        // 次の段(探索しない)に、前の段の探索の注記を持ち越さない
        let next = await executor.execute(FlowStep(action: "select", locator: FlowLocator(id: "txt_player_result")))
        XCTAssertFalse((next.driverFallback ?? "").contains("the sheet was expanded"), next.driverFallback ?? "")
    }

    /// scrollFrame を指していなければ広げない(当てずっぽうに画面を動かさない)
    func testDoesNotDragWithoutAScrollFrame() async {
        let driver = SheetDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        var step = searchStep()
        step.scrollFrame = nil

        _ = await executor.execute(step)

        // 広げるドラッグの形 = 容器の下端(画面下端の空白帯の手前 825)→ 容器の上端(660)。逆走査のドラッグとは別
        XCTAssertFalse(driver.drags.contains { $0.fromY == 825 && $0.toY == 660 },
                       "scrollFrame 無しで広げるドラッグを撃たない: \(driver.drags)")
    }
}
