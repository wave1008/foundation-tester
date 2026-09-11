// **ghost 救済の後の空打ちが画面を変えたら、古い ref のまま撃たない**ことを固定する。
//
// 空打ち(容器の1タッチを肩代わりする横抜けドラッグ)は、UI フレームワークが不明なとき(物理 iPhone を
// MCP で操作する等)に SwiftUI の行を発火させることがある。発火して画面が変わると掴み直しが外れ、
// 旧実装は空打ち前の要素(= 古い ref)を残して `tap(ref:)` を撃っていた。ランナーは最新の木で ref を
// 振り直すので**別の要素を押して ok**になる(2026-09-11 物理 iPhone 13 で実測: 空打ちで診断画面へ
// 遷移 → 古い ref が #tab_home を押してホームへ戻り、ステップは緑)。

import XCTest
@testable import FTCore

/// 最初は対象が容器の外(ghost)・1回送ると容器の中・空打ちのドラッグの後は別の画面を返す。
/// 別の画面では**同じ ref 番号 4 が別の要素**(#tab_home)を指す
private final class EmptyDragFiresRowDriver: AppDriver {
    /// 内容を送った回数(スワイプ + 縦のドラッグ = ghost の救済が撃つ送り)
    private(set) var moves = 0
    /// 空打ち = 横に抜けるドラッグ(fromY == toY。StepExecutor.emptyDrag)
    private(set) var emptyDrags = 0
    private(set) var tappedRefs: [Int] = []
    private(set) var coordinateTaps = 0
    /// true = 空打ちで画面が変わる / false = 変わらない(対照)
    let dragChangesScreen: Bool

    init(dragChangesScreen: Bool) { self.dragChangesScreen = dragChangesScreen }

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
    func tap(ref: Int) async throws { tappedRefs.append(ref) }
    func tap(x: Double, y: Double) async throws { coordinateTaps += 1 }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { moves += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        moves += 1
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        if fromY == toY { emptyDrags += 1 } else { moves += 1 }
    }

    func snapshot() async throws -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        if dragChangesScreen, emptyDrags > 0 {
            return SnapshotResponse(
                sessionBundleID: nil, screen: screen,
                elements: [
                    ElementInfo(ref: 1, type: "staticText", identifier: "txt_title", label: "診断",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 16, y: 60, width: 200, height: 40), depth: 1),
                    ElementInfo(ref: 4, type: "button", identifier: "tab_home", label: "ホーム",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 800, width: 130, height: 74), depth: 1),
                ],
                truncatedCount: 0)
        }
        // 容器 y 400..560。ghost は容器の**完全に外**(y=100)、1回送った後は容器の中(y=500)
        let targetY: Double = moves == 0 ? 100 : 500
        return SnapshotResponse(
            sessionBundleID: nil, screen: screen,
            elements: [
                ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: 400, width: 370, height: 160), depth: 1),
                ElementInfo(ref: 2, type: "clickable", identifier: "row_01", label: "行 01",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: 410, width: 370, height: 56), depth: 2),
                ElementInfo(ref: 3, type: "clickable", identifier: "row_02", label: "行 02",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: 470, width: 370, height: 56), depth: 2),
                ElementInfo(ref: 4, type: "clickable", identifier: "target", label: "対象",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: targetY, width: 370, height: 56), depth: 2),
            ],
            truncatedCount: 0)
    }
}

final class EmptyDragStaleRefTests: XCTestCase {

    /// 空打ちで対象が木から消えたら**何も撃たずに失敗**する。古い ref を残す形へ戻すと
    /// `tap(ref: 4)`(= 新しい木の #tab_home)が撃たれてここが落ちる
    func testNothingIsTappedWhenTheReliefDragChangesTheScreen() async throws {
        let driver = EmptyDragFiresRowDriver(dragChangesScreen: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"))

        let result = await StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false,
                                    uiFramework: "compose")
            .execute(step)

        XCTAssertGreaterThan(driver.moves, 0, "ghost の掴み直しが発火していない = この経路を通っていない")
        XCTAssertEqual(driver.emptyDrags, 1, "空打ちが撃たれていない = この経路を通っていない")
        XCTAssertEqual(driver.tappedRefs, [], "画面が変わった後に古い ref を撃った")
        XCTAssertEqual(driver.coordinateTaps, 0, "画面が変わった後に座標で撃った")
        guard case .failed(let message) = result.status else {
            return XCTFail("失敗になっていない: \(result.status)")
        }
        XCTAssertTrue(message.contains("changed the screen"), message)
        XCTAssertTrue(message.contains("Nothing was tapped"), message)
    }

    /// 対照: 空打ちで画面が変わらなければ、取り直した要素を従来どおり撃つ
    func testTheTargetIsStillTappedWhenTheReliefDragChangesNothing() async throws {
        let driver = EmptyDragFiresRowDriver(dragChangesScreen: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"))

        let result = await StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false,
                                    uiFramework: "compose")
            .execute(step)

        XCTAssertEqual(driver.emptyDrags, 1, "空打ちが撃たれていない = この経路を通っていない")
        XCTAssertEqual(driver.tappedRefs, [4], "取り直した対象を撃っていない")
        XCTAssertTrue(StepExecutor.isSuccess(result.status), "\(result.status)")
    }
}
