// **DSL(TapTargetGeometry.occlusionAdvisory)と MCP(RefGuard.overlapWarning)が
// 同じ判定(TapTargetGeometry.advisoryKind)を経由していること**を固定する。
//
// 文言そのものは意図的に違う(DSL はステップ注記の主語 "the target" / MCP は要素を名指しして
// ft_screenshot・ft_scroll_to という MCP のツール名で逃げ道を書く)ので、ここでは文言の一致では
// なく「同じ kind から生成されているか」を、両者の出力に共通して現れるはずの手掛かり
// (犯人の #id・現象を示すキーワード)で確かめる。8形とも1本ずつ持つことで、
// どれか1形だけ MCP 側の配線を忘れる変異(=このファイルが直そうとしている元の欠陥そのもの)を捕まえる。

import XCTest
import FTCore
@testable import fleetest_mcp

final class TapAdvisoryKindSharedTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)

    private func element(_ ref: Int, _ id: String?, _ type: String,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                         depth: Int = 2, label: String? = nil,
                         scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth,
                    scrollable: scrollable)
    }

    /// zeroFrame: frame の幅か高さが 0
    func testZeroFrameKindDrivesBothWordings() {
        let e = element(1, "z", "button", 100, 100, 0, 40)
        guard case .zeroFrame = TapTargetGeometry.advisoryKind(for: e, in: [e], screen: screen) else {
            return XCTFail("zeroFrame が発火していない")
        }
        let dsl = TapTargetGeometry.occlusionAdvisory(for: e, in: [e], screen: screen)
        XCTAssertTrue(dsl?.contains("zero width/height") == true, dsl ?? "-")
        let mcp = RefGuard.overlapWarning(found: e, in: [e], screen: screen)
        XCTAssertTrue(mcp.contains("zero width/height"), mcp)
        XCTAssertTrue(mcp.contains("#z"), "MCP 側は要素を名指しすること: \(mcp)")
    }

    /// offscreen: 中心が画面の外
    func testOffscreenKindDrivesBothWordings() {
        let smallScreen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let e = element(1, "slot_07", "button", 0, -46, 402, 56)
        guard case .offscreen = TapTargetGeometry.advisoryKind(for: e, in: [e], screen: smallScreen)
        else { return XCTFail("offscreen が発火していない") }
        let dsl = TapTargetGeometry.occlusionAdvisory(for: e, in: [e], screen: smallScreen)
        XCTAssertTrue(dsl?.contains("outside the visible screen") == true, dsl ?? "-")
        let mcp = RefGuard.overlapWarning(found: e, in: [e], screen: smallScreen)
        XCTAssertTrue(mcp.contains("outside the visible screen"), mcp)
        XCTAssertTrue(mcp.contains("ft_scroll_to"), "MCP 側は逃げ道を書くこと: \(mcp)")
    }

    /// scrolledOut: 申告されたスクロール容器の外
    func testScrolledOutKindDrivesBothWordings() {
        let smallScreen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let scroller = element(1, "scroller", "other", 0, 100, 402, 600, depth: 1, scrollable: true)
        let rowA = element(2, "row_a", "clickable", 10, 110, 370, 20, label: "行A")
        let rowB = element(3, "row_b", "clickable", 10, 160, 370, 20, label: "行B")
        let target = element(4, "target", "clickable", 10, 750, 370, 20)
        let elements = [scroller, rowA, rowB, target]
        guard case .scrolledOut(let hit) = TapTargetGeometry.advisoryKind(
            for: target, in: elements, screen: smallScreen) else {
            return XCTFail("scrolledOut が発火していない")
        }
        XCTAssertEqual(hit.ref, scroller.ref)
        let dsl = TapTargetGeometry.occlusionAdvisory(for: target, in: elements, screen: smallScreen)
        XCTAssertTrue(dsl?.contains("leftover from scrolling") == true, dsl ?? "-")
        let mcp = RefGuard.overlapWarning(found: target, in: elements, screen: smallScreen)
        XCTAssertTrue(mcp.contains("leftover from scrolling"), mcp)
        XCTAssertTrue(mcp.contains("#scroller"), "MCP 側は容器を名指しすること: \(mcp)")
    }

    /// overlayCovering: 後に描かれた別要素が中心を覆う
    func testOverlayCoveringKindDrivesBothWordings() {
        let target = element(1, "nav_heal", "clickable", 16, 788, 370, 62)
        let overlay = element(2, "tab_controls", "clickable", 134, 778, 134, 62)
        let elements = [target, overlay]
        guard case .overlayCovering(let hit) = TapTargetGeometry.advisoryKind(
            for: target, in: elements, screen: screen) else {
            return XCTFail("overlayCovering が発火していない")
        }
        XCTAssertEqual(hit.ref, overlay.ref)
        let dsl = TapTargetGeometry.occlusionAdvisory(for: target, in: elements, screen: screen)
        XCTAssertTrue(dsl?.contains("#tab_controls") == true, dsl ?? "-")
        XCTAssertTrue(dsl?.contains("instead") == true, dsl ?? "-")
        let mcp = RefGuard.overlapWarning(found: target, in: elements, screen: screen)
        XCTAssertTrue(mcp.contains("#tab_controls"), mcp)
        XCTAssertTrue(mcp.contains("ft_screenshot"), "MCP 側は逃げ道を書くこと: \(mcp)")
    }

    /// missedContent: 非対話容器の中心がその中身のどれの上にも無い
    func testMissedContentKindDrivesBothWordings() {
        let map = element(1, "map", "clickable", 0, 0, 1080, 2424, depth: 1)
        let wrap = element(2, "layers_fab_button", "other", 0, 442, 1080, 157, depth: 4)
        let inner = element(3, "layers_fab", "image", 928, 457, 152, 142, depth: 5)
        let elements = [map, wrap, inner]
        guard case .missedContent(let hit) = TapTargetGeometry.advisoryKind(
            for: wrap, in: elements, screen: screen) else {
            return XCTFail("missedContent が発火していない")
        }
        XCTAssertEqual(hit.ref, inner.ref)
        let dsl = TapTargetGeometry.occlusionAdvisory(for: wrap, in: elements, screen: screen)
        XCTAssertTrue(dsl?.contains("#layers_fab") == true, dsl ?? "-")
        XCTAssertTrue(dsl?.contains("behind it") == true, dsl ?? "-")
        let mcp = RefGuard.overlapWarning(found: wrap, in: elements, screen: screen)
        XCTAssertTrue(mcp.contains("#layers_fab"), mcp)
        XCTAssertTrue(mcp.contains("behind it"), mcp)
    }

    /// nestedAction: 対話的な親の中で、子孫の小さな帯が中心を横取りする
    func testNestedActionKindDrivesBothWordings() {
        let parent = element(1, "row", "cell", 0, 0, 100, 100)
        let chip = element(2, "chip", "button", 40, 40, 20, 20, depth: 3)
        let elements = [parent, chip]
        guard case .nestedAction(let hit) = TapTargetGeometry.advisoryKind(
            for: parent, in: elements, screen: screen) else {
            return XCTFail("nestedAction が発火していない")
        }
        XCTAssertEqual(hit.ref, chip.ref)
        let dsl = TapTargetGeometry.occlusionAdvisory(for: parent, in: elements, screen: screen)
        XCTAssertTrue(dsl?.contains("#chip") == true, dsl ?? "-")
        XCTAssertTrue(dsl?.contains("instead") == true, dsl ?? "-")
        let mcp = RefGuard.overlapWarning(found: parent, in: elements, screen: screen)
        XCTAssertTrue(mcp.contains("#chip"), mcp)
        XCTAssertTrue(mcp.contains("ft_screenshot"), "MCP 側は逃げ道を書くこと: \(mcp)")
    }

    /// stacked: 同一矩形に3件以上積まれている
    func testStackedKindDrivesBothWordings() {
        func stacked(_ ref: Int, _ label: String) -> ElementInfo {
            element(ref, "poi", "other", 300, 300, 30, 30, depth: 1, label: label)
        }
        let elements = (0..<3).map { stacked($0 + 1, "STACK\($0)") }
        guard case .stacked = TapTargetGeometry.advisoryKind(
            for: elements[0], in: elements, screen: screen) else {
            return XCTFail("stacked が発火していない")
        }
        let dsl = TapTargetGeometry.occlusionAdvisory(for: elements[0], in: elements, screen: screen)
        XCTAssertTrue(dsl?.contains("clamped leftovers") == true, dsl ?? "-")
        let mcp = RefGuard.overlapWarning(found: elements[0], in: elements, screen: screen)
        XCTAssertTrue(mcp.contains("clamped leftovers"), mcp)
        XCTAssertTrue(mcp.contains("ft_scroll_to"), "MCP 側は逃げ道を書くこと: \(mcp)")
    }

    /// sliver: 容器の縁で細帯に切れたラベル付き要素。**この形は 2026-08-15 まで DSL にしか無く、
    /// MCP のタップ時には出ていなかった**(この修正で合流した2形の1つ)
    func testSliverKindDrivesBothWordings() {
        let e = element(1, "tab_sunrise_seto", "tab", 1071, 100, 9, 137, depth: 1,
                        label: "サンライズ瀬戸")
        guard case .sliver = TapTargetGeometry.advisoryKind(for: e, in: [e], screen: screen) else {
            return XCTFail("sliver が発火していない")
        }
        let dsl = TapTargetGeometry.occlusionAdvisory(for: e, in: [e], screen: screen)
        XCTAssertTrue(dsl?.contains("sliver") == true, dsl ?? "-")
        let mcp = RefGuard.overlapWarning(found: e, in: [e], screen: screen)
        XCTAssertTrue(mcp.contains("sliver"), mcp)
        XCTAssertTrue(mcp.contains("#tab_sunrise_seto"), "MCP 側は要素を名指しすること: \(mcp)")
        XCTAssertTrue(mcp.contains("ft_screenshot"), "MCP 側は逃げ道を書くこと: \(mcp)")
    }

    /// clippedByContainer: 縁が容器の縁と一致し、同depth・同型の兄弟が明らかに高い
    /// (shortfall witness ⒜。実測は TapTargetGeometry.clippedAtContainerEdge の doc)
    func testClippedByContainerKindDrivesBothWordings() {
        let container = element(1, "screen_account", "other", 0, 47, 390, 683, depth: 0)
        let tall1 = element(2, nil, "button", 16, 100, 358, 56, depth: 1)
        let tall2 = element(3, nil, "button", 16, 164, 358, 56, depth: 1)
        let logout = element(4, "btn_logout", "button", 16, 687, 358, 43, depth: 1)
        let elements = [container, tall1, tall2, logout]
        guard case .clippedByContainer(let hit) = TapTargetGeometry.advisoryKind(
            for: logout, in: elements, screen: screen) else {
            return XCTFail("clippedByContainer が発火していない")
        }
        XCTAssertEqual(hit.ref, container.ref)
        let dsl = TapTargetGeometry.occlusionAdvisory(for: logout, in: elements, screen: screen)
        XCTAssertTrue(dsl?.contains("cut off") == true, dsl ?? "-")
        let mcp = RefGuard.overlapWarning(found: logout, in: elements, screen: screen)
        XCTAssertTrue(mcp.contains("cut off"), mcp)
        XCTAssertTrue(mcp.contains("#btn_logout"), "MCP 側は要素を名指しすること: \(mcp)")
        XCTAssertTrue(mcp.contains("ft_scroll_to"), "MCP 側は逃げ道を書くこと: \(mcp)")
    }
}
