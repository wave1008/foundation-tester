// 空打ちの第3段(掴んだ要素のクラス名)。フレームワークが不明なときだけ効き、判っていればそちらが勝つ。
// クラス名が無い(旧ランナー・in-app・Android)なら撃たない

import XCTest
@testable import FTCore

final class AccessibilityClassHintTests: XCTestCase {

    private func row(axClass: String?) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "row_40", label: "行 40", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 300, width: 370, height: 56), depth: 3, axClass: axClass)
    }

    // MARK: - 純粋関数

    func testHostedElementMeansCustomDrawnTouches() {
        XCTAssertEqual(AccessibilityClassHint.hostsOwnTouches(row(axClass: "UIAccessibilityElement")), true)
    }

    func testViewBackedClassesDoNot() {
        for cls in ["UIView", "NSObject", "UIButton", "UICollectionViewListCell"] {
            XCTAssertEqual(AccessibilityClassHint.hostsOwnTouches(row(axClass: cls)), false, cls)
        }
    }

    func testMissingClassIsUnknown() {
        XCTAssertNil(AccessibilityClassHint.hostsOwnTouches(row(axClass: nil)))
        XCTAssertNil(AccessibilityClassHint.hostsOwnTouches(row(axClass: "")))
    }

    // MARK: - StepExecutor の配線(探索終端の空打ち)

    private func dragCount(uiFramework: AppUIFramework?, axClass: String?) async -> Int {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], [row(axClass: axClass)]])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true, isAndroid: false,
                                    uiFramework: uiFramework)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2)
        guard case .passed = await executor.execute(step).status else {
            XCTFail("スワイプ後の snapshot で見つかるので pass のはず"); return -1
        }
        return primary.dragCalls.count
    }

    func testUnknownFrameworkDragsOnlyForHostedElements() async {
        let hosted = await dragCount(uiFramework: nil, axClass: "UIAccessibilityElement")
        XCTAssertEqual(hosted, 1, "不明でも UIAccessibilityElement なら空打ちを撃つ")
        for cls in ["UIView", "NSObject", "UIButton"] {
            let n = await dragCount(uiFramework: nil, axClass: cls)
            XCTAssertEqual(n, 0, "\(cls) では撃たない")
        }
        let missing = await dragCount(uiFramework: nil, axClass: nil)
        XCTAssertEqual(missing, 0, "クラス名も無ければ撃たない")
    }

    func testKnownFrameworkWinsOverTheClassName() async {
        // RN(uikit)と判っていれば、要素が UIAccessibilityElement でも撃たない
        let uikit = await dragCount(uiFramework: .uikit, axClass: "UIAccessibilityElement")
        XCTAssertEqual(uikit, 0)
        // Compose と判っていれば、クラス名が無くても撃つ
        let compose = await dragCount(uiFramework: .compose, axClass: nil)
        XCTAssertEqual(compose, 1)
    }

    func testAndroidNeverDrags() async {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], [row(axClass: "UIAccessibilityElement")]])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: false, isAndroid: true, uiFramework: nil)
        _ = await executor.execute(FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2))
        XCTAssertTrue(primary.dragCalls.isEmpty)
    }

    /// ワイヤ: axClass は省略可能(旧ランナーの JSON がそのまま読める)で、あれば運ぶ
    func testAxClassRoundTripsAndIsOptional() throws {
        let data = try JSONEncoder().encode(row(axClass: "UIAccessibilityElement"))
        XCTAssertEqual(try JSONDecoder().decode(ElementInfo.self, from: data).axClass, "UIAccessibilityElement")
        let legacy = Data("""
        {"ref":1,"type":"Button","enabled":true,"frame":{"x":0,"y":0,"width":10,"height":10},"depth":1}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(ElementInfo.self, from: legacy).axClass)
    }
}
