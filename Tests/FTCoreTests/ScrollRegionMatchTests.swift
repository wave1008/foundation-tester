// 自前描画(Compose / Flutter)の in-app で、scrollFrame の領域をスクロール容器と突き合わせる判定。
// 固定ヘッダ(スクロール容器ではない)を指定したら一致させない = XCUITest へ回す、を守る。

import XCTest
@testable import FTCore

final class ScrollRegionMatchTests: XCTestCase {

    private func el(_ ref: Int, _ frame: FTRect, scrollable: Bool?) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: nil, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: 1, scrollable: scrollable)
    }

    private let list = FTRect(x: 16, y: 180, width: 370, height: 600)
    private let header = FTRect(x: 16, y: 134, width: 370, height: 40)
    private let carousel = FTRect(x: 16, y: 800, width: 370, height: 56)

    func testRegionMatchesTheScrollContainerWithTheSameFrame() {
        let elements = [el(1, list, scrollable: true), el(2, carousel, scrollable: true), el(3, header, scrollable: nil)]
        XCTAssertEqual(ScrollRegionMatch.candidates(in: elements, region: carousel), [2])
        XCTAssertEqual(ScrollRegionMatch.candidates(in: elements, region: list), [1])
    }

    /// 固定ヘッダはスクロール容器ではない → 一致しない(ホストは XCUITest へ回す)。
    /// 旧実装はこの形でリストを動かした(E2E-Flutter scene 11 / E2E-CMP scene 9 が witness)
    func testFixedHeaderMatchesNothing() {
        let elements = [el(1, list, scrollable: true), el(3, header, scrollable: nil)]
        XCTAssertEqual(ScrollRegionMatch.candidates(in: elements, region: header), [])
    }

    /// 固定ヘッダを**覆う**スクロール容器(画面全体を受け持つ容器)があっても一致させない ——
    /// 旧実装はこの容器が scroll を受理してリストが動いた。重なりは面積比で判定する
    func testContainerThatMerelyCoversTheHeaderDoesNotMatch() {
        let screenScroll = FTRect(x: 0, y: 0, width: 402, height: 874)
        let elements = [el(1, screenScroll, scrollable: true), el(2, list, scrollable: true),
                        el(3, header, scrollable: nil)]
        XCTAssertEqual(ScrollRegionMatch.candidates(in: elements, region: header), [])
    }

    /// 同じ枠でもスクロール容器でなければ一致しない(id 付きの包みなど)
    func testNonScrollableElementWithTheSameFrameDoesNotMatch() {
        XCTAssertEqual(ScrollRegionMatch.candidates(in: [el(4, carousel, scrollable: nil)], region: carousel), [])
        XCTAssertEqual(ScrollRegionMatch.candidates(in: [el(4, carousel, scrollable: false)], region: carousel), [])
    }

    /// 同じ枠で入れ子になった容器は内側(木の後ろ)から試す
    func testNestedContainersAreTriedInnermostFirst() {
        let elements = [el(1, carousel, scrollable: true), el(2, carousel, scrollable: true)]
        XCTAssertEqual(ScrollRegionMatch.candidates(in: elements, region: carousel), [2, 1])
    }

    /// 送るまでの小さなずれは許し、別の容器(重なりが小さい)は許さない
    func testOverlapThreshold() {
        let shifted = FTRect(x: carousel.x, y: carousel.y + 2, width: carousel.width, height: carousel.height)
        XCTAssertGreaterThanOrEqual(ScrollRegionMatch.overlap(shifted, carousel), ScrollRegionMatch.minimumOverlap)
        XCTAssertLessThan(ScrollRegionMatch.overlap(header, list), ScrollRegionMatch.minimumOverlap)
        XCTAssertEqual(ScrollRegionMatch.overlap(carousel, carousel), 1, accuracy: 1e-9)
        XCTAssertEqual(ScrollRegionMatch.overlap(header, FTRect(x: 0, y: 0, width: 0, height: 0)), 0)
    }

    /// in-app の dylib は swift test でリンクされないので、配線はソース走査で守る:
    /// 領域指定の経路が、ホストと同じ走査(InAppSnapshot)の枠をこの判定に通していること
    func testInAppBridgeScrollsOnlyTheMatchedRegion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        guard let start = bridge.range(of: "private static func scrollRegion("),
              let end = bridge.range(of: "\n    }\n", range: start.upperBound..<bridge.endIndex) else {
            return XCTFail("scrollRegion が見つかりません")
        }
        let body = bridge[start.lowerBound..<end.upperBound]
        XCTAssertTrue(body.contains("InAppSnapshot.capture(window: window)"), "枠はスナップショットと同じ走査で出す")
        XCTAssertTrue(body.contains("ScrollRegionMatch.candidates(in: snapshot.elements, region: region)"),
                      "一致の判定を ScrollRegionMatch に通していない")
        XCTAssertTrue(body.contains("scrollWalk(node, direction"),
                      "一致した容器を根に走査する(Compose の容器自身は scroll を断る)")
        XCTAssertFalse(body.contains("scrollWalk(window") || body.contains("scrollViaAccessibility("),
                       "根を画面全体にすると別の領域が動く(固定ヘッダを指定してリストが動いた形)")
        XCTAssertTrue(bridge.contains("outcome = Self.scrollRegion(region, in: window, finger: req.direction)"),
                      "自前描画の領域指定が scrollRegion を通っていない")
    }

    /// UIKit / SwiftUI / RN の in-app: 指を置く点(領域の始点・無ければ画面中央)を含むスクロールビューだけを選び、
    /// 画面のどこかの「余地のある最大の容器」へ落とさない(落とすと指定と違う領域が動く。E2E-RN でカルーセルが
    /// 動いた・scrollFrame 無しでも画面下のカルーセルが動いた)
    func testUIKitTargetUsesOnlyThePointOfContact() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        guard let start = bridge.range(of: "private static func target("),
              let end = bridge.range(of: "\n    }\n", range: start.upperBound..<bridge.endIndex) else {
            return XCTFail("target が見つかりません")
        }
        let body = String(bridge[start.lowerBound..<end.upperBound])
        XCTAssertFalse(bridge.contains("largestWithRoom("), "面積最大への落とし先を戻さない")
        XCTAssertTrue(body.contains("?? centre"), "領域指定が無いときは画面中央を使う")
        XCTAssertTrue(bridge.contains("centre: CGPoint(x: window.bounds.midX, y: window.bounds.midY)"),
                      "呼び出し側が画面中央を渡していない")
    }

    /// 自前描画の AX 走査(scrollFrame 無し)は、画面中央に触れうる要素だけを見る
    func testSelfRenderedWalkWithoutRegionIsConfinedToTheCentre() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        XCTAssertTrue(bridge.contains("return scrollWalk(root, accessibilityDirection(finger: finger), reaching: centre,"),
                      "scrollFrame 無しの AX 走査が画面中央を渡していない")
        XCTAssertTrue(bridge.contains("ScrollPointReach.mayReach(frame: frame, x: Double(point.x), y: Double(point.y))"),
                      "走査が枠で刈っていない")
    }

    func testPointReach() {
        let list = FTRect(x: 16, y: 230, width: 370, height: 462)
        let carousel = FTRect(x: 16, y: 692, width: 370, height: 60)
        XCTAssertTrue(ScrollPointReach.mayReach(frame: list, x: 201, y: 437))
        XCTAssertFalse(ScrollPointReach.mayReach(frame: carousel, x: 201, y: 437), "画面下のカルーセルは中央に触れない")
        XCTAssertTrue(ScrollPointReach.mayReach(frame: FTRect(x: 0, y: 0, width: 0, height: 0), x: 201, y: 437),
                      "枠を申告しない入れ物は通す(刈るとその下の容器に届かない)")
    }

    /// スクロール用の経路だけが region を運ぶ(pan / flick はジェスチャそのものが目的なので運ばない)
    func testOnlyScrollPathsCarryTheRegion() {
        let viewport = FTRect(x: 0, y: 0, width: 402, height: 874)
        let path = ScrollGeometry.path(container: carousel, viewport: viewport, direction: .right,
                                       startMarginRatio: 0.2, endMarginRatio: 0.2)
        XCTAssertEqual(path?.region, carousel)
        XCTAssertNotNil(path)
        let pan = ScrollGeometry.panPath(container: list, viewport: viewport, dxRatio: 0.3, dyRatio: 0)
        XCTAssertNotNil(pan)
        XCTAssertNil(pan?.region, "pan はジェスチャが目的 = AX のスクロールで代行させない")
        let flick = ScrollGeometry.flickPath(container: list, viewport: viewport, kind: .bottomToTop,
                                             startMarginRatio: 0.1)
        XCTAssertNotNil(flick)
        XCTAssertNil(flick?.region, "flick はジェスチャが目的 = AX のスクロールで代行させない")
    }
}
