// 「撃つ前に言える危なさ」の共有判定。**MCP と DSL が同じ定義を使う**ことが要点。
// DSL 側は失敗にせずステップ注記へ混ぜる(無効な要素をわざと叩く書き方は正当なため)。

import XCTest
@testable import FTCore

final class TapTargetAdvisoryTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)

    private func element(_ ref: Int, _ id: String, _ type: String,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                         depth: Int = 2, enabled: Bool = true) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    /// 木には `disabled` と印字しているのに、操作経路は `enabled` を一度も見ていなかった
    /// (E2E-CMP の契約上「押しても何も起きない」ボタンで実測)
    func testDisabledTargetIsCalledOut() {
        let off = element(1, "btn_always_disabled", "button", 42, 1544, 309, 126, enabled: false)
        let note = TapTargetGeometry.advisory(for: off, in: [off], screen: screen)
        XCTAssertEqual(note, "the target is disabled, so this almost certainly did nothing")
    }

    /// 有効な要素では黙る(毎回付くと注記が意味を失う)
    func testEnabledPlainTargetIsSilent() {
        let on = element(1, "btn", "button", 0, 0, 100, 40)
        XCTAssertNil(TapTargetGeometry.advisory(for: on, in: [on], screen: screen))
    }

    /// 全幅の非対話コンテナで中身は右端の FAB だけ = 中心は地図の上
    /// (実測: 叩くと海上の座標にピンが落ちて place page が開いた)
    func testContainerWhoseCentreMissesItsContent() {
        let elements = [
            element(1, "map", "clickable", 0, 0, 1080, 2424),
            element(2, "layers_fab_button", "other", 0, 442, 1080, 157, depth: 4),
            element(3, "layers_fab", "image", 928, 457, 152, 142, depth: 5),
        ]
        let note = TapTargetGeometry.advisory(for: elements[1], in: elements, screen: screen)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("#layers_fab") == true, note ?? "")
        XCTAssertTrue(note?.contains("behind it") == true, note ?? "")
    }

    /// **囲っている対話要素がタップを受け止めるなら黙る**(誤検知の抑制)
    func testEnclosingInteractiveAncestorSilencesIt() {
        let elements = [
            element(1, "card", "clickable", 0, 1399, 1080, 1025),
            element(2, "business_place_card", "other", 0, 1399, 1080, 320, depth: 3),
            element(3, "title", "staticText", 42, 1462, 440, 58, depth: 4),
        ]
        XCTAssertNil(TapTargetGeometry.advisory(for: elements[1], in: elements, screen: screen))
    }

    /// **disabled が優先**: 両方に当てはまるときは「そもそも無効」を先に言う
    func testDisabledWinsOverTheGeometricAdvice() {
        let elements = [
            element(1, "map", "clickable", 0, 0, 1080, 2424),
            element(2, "wrap", "other", 0, 442, 1080, 157, depth: 4, enabled: false),
            element(3, "inner", "image", 928, 457, 152, 142, depth: 5),
        ]
        XCTAssertEqual(TapTargetGeometry.advisory(for: elements[1], in: elements, screen: screen),
                       "the target is disabled, so this almost certainly did nothing")
    }
}

/// **配線のテスト**: 判定関数を単体で確かめるだけでは「DSL の tap がそれを通っているか」を
/// 検証できない(2026-08-07 に掃討ハーネスで同じ穴を踏んだ)。実際に `StepExecutor` の
/// tap を実行して、ステップ注記に載ることを固定する。
private final class AdvisoryProbeDriver: AppDriver {
    let disabled: Bool
    private(set) var taps = 0
    init(disabled: Bool) { self.disabled = disabled }

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
    func tap(ref: Int) async throws { taps += 1 }
    func tap(x: Double, y: Double) async throws { taps += 1 }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}

    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [
                ElementInfo(ref: 1, type: "clickable", identifier: "target", label: "対象",
                            value: nil, placeholder: nil, enabled: !disabled,
                            frame: FTRect(x: 16, y: 410, width: 370, height: 56), depth: 2),
            ],
            truncatedCount: 0)
    }
}

final class TapAdvisoryWiringTests: XCTestCase {

    /// 無効な要素を叩いたら**ステップ注記に出る**(失敗にはしない)
    func testDisabledTargetSurfacesInTheStepNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))

        XCTAssertEqual(driver.taps, 1, "注記は出すが撃つのはやめない(拒否ではない)")
        if case .passed = outcome.status {} else { XCTFail("失敗にしてはいけない: \(outcome.status)") }
        XCTAssertTrue(outcome.driverFallback?.contains("disabled") == true,
                      "注記が出ていない: \(outcome.driverFallback ?? "nil")")
    }

    /// 有効な要素では注記を足さない
    func testEnabledTargetAddsNoNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        XCTAssertEqual(driver.taps, 1)
        XCTAssertNil(outcome.driverFallback, "余計な注記が付いた: \(outcome.driverFallback ?? "")")
    }
}
