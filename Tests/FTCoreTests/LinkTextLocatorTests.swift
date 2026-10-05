import CoreGraphics
import CoreText
import XCTest
@testable import FTCore

final class LinkTextLocatorTests: XCTestCase {

    private func element(ref: Int, depth: Int, label: String?, frame: FTRect,
                         value: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: nil, label: label, value: value,
                    placeholder: nil, enabled: true, frame: frame, depth: depth)
    }

    // MARK: - 木

    func testTreePointPicksTheMatchingDescendantCentre() throws {
        let paragraph = element(ref: 1, depth: 1, label: "同意する 利用規約 と",
                                frame: FTRect(x: 0, y: 100, width: 300, height: 40))
        let link = element(ref: 2, depth: 2, label: "利用規約", frame: FTRect(x: 100, y: 100, width: 60, height: 20))
        let point = try XCTUnwrap(LinkTextLocator.treePoint(linkText: "利用規約", element: paragraph,
                                                            in: [paragraph, link]))
        XCTAssertEqual(point.x, 130)
        XCTAssertEqual(point.y, 110)
        XCTAssertEqual(point.source, .tree)
    }

    func testTreePointIgnoresNonDescendantsAndTheElementItself() {
        let paragraph = element(ref: 1, depth: 1, label: "利用規約", frame: FTRect(x: 0, y: 0, width: 300, height: 40))
        // 兄弟(depth が同じ)は子孫ではない
        let sibling = element(ref: 2, depth: 1, label: "利用規約", frame: FTRect(x: 0, y: 50, width: 60, height: 20))
        XCTAssertNil(LinkTextLocator.treePoint(linkText: "利用規約", element: paragraph, in: [paragraph, sibling]))
    }

    func testTreePointSkipsCollapsedFramesAndPrefersTreeOrder() throws {
        let parent = element(ref: 1, depth: 1, label: nil, frame: FTRect(x: 0, y: 0, width: 300, height: 40))
        let collapsed = element(ref: 2, depth: 2, label: "規約", frame: FTRect(x: 0, y: 0, width: 0, height: 0))
        let real = element(ref: 3, depth: 2, label: nil, frame: FTRect(x: 10, y: 10, width: 20, height: 10), value: "規約")
        let point = try XCTUnwrap(LinkTextLocator.treePoint(linkText: "規約", element: parent,
                                                            in: [parent, collapsed, real]))
        XCTAssertEqual(point.x, 20)
        XCTAssertEqual(point.y, 15)
    }

    func testTreePointRequiresAWholeLabelMatch() {
        let parent = element(ref: 1, depth: 1, label: nil, frame: FTRect(x: 0, y: 0, width: 300, height: 40))
        let child = element(ref: 2, depth: 2, label: "利用規約に同意", frame: FTRect(x: 0, y: 0, width: 50, height: 20))
        XCTAssertNil(LinkTextLocator.treePoint(linkText: "利用規約", element: parent, in: [parent, child]))
    }

    // MARK: - 位置の写像(純粋関数)

    /// Vision は原点が左下。クロップ (100,200,200x100) px の右上 1/4 の中心 → 画像 px (250, 225) → 3x 端末で /3
    func testScreenPointMapsACropNormalizedBoxToScreenPoints() throws {
        let p = try XCTUnwrap(LinkTextLocator.screenPoint(
            normalizedBox: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            crop: CGRect(x: 100, y: 200, width: 200, height: 100),
            imageWidth: 1200, imageHeight: 2400, screen: FTRect(x: 0, y: 0, width: 400, height: 800)))
        XCTAssertEqual(p.x, 250.0 / 3, accuracy: 0.001)
        XCTAssertEqual(p.y, 225.0 / 3, accuracy: 0.001)
    }

    /// Android は screen が px = 画像と同じ系なので倍率 1
    func testScreenPointIsIdentityScaleWhenScreenIsInPixels() throws {
        let p = try XCTUnwrap(LinkTextLocator.screenPoint(
            normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            crop: CGRect(x: 10, y: 20, width: 100, height: 40),
            imageWidth: 1080, imageHeight: 2400, screen: FTRect(x: 0, y: 0, width: 1080, height: 2400)))
        XCTAssertEqual(p.x, 60, accuracy: 0.001)
        XCTAssertEqual(p.y, 40, accuracy: 0.001)
    }

    func testScreenPointRejectsDegenerateInput() {
        XCTAssertNil(LinkTextLocator.screenPoint(normalizedBox: .zero, crop: .zero,
                                                 imageWidth: 100, imageHeight: 100,
                                                 screen: FTRect(x: 0, y: 0, width: 100, height: 100)))
    }

    func testRangeFindsTheLinkInOriginalText() throws {
        let text = "Please accept the Terms of Service today"
        let range = try XCTUnwrap(LinkTextLocator.range(of: "terms of service", in: text))
        XCTAssertEqual(String(text[range]), "Terms of Service")
        XCTAssertNil(LinkTextLocator.range(of: "Privacy", in: text))
        XCTAssertNil(LinkTextLocator.range(of: "", in: text))
    }

    // MARK: - OCR(実際の Vision。描いた文字の位置へ当たること)

    private func renderedLine(_ text: String, width: Int, height: Int) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 10, y: 20)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testLocateLinkFindsTheRightWordInARenderedLine() async throws {
        let png = try renderedLine("Please accept the Terms of Service today", width: 640, height: 60)
        let screen = FTRect(x: 0, y: 0, width: 640, height: 60)
        let located = await RegionText.locateLink(linkText: "Terms of Service", pngData: png,
                                                  frame: screen, screen: screen)
        let result = try XCTUnwrap(located)
        let point = try XCTUnwrap(result.point, "OCR read: \(result.lines)")
        // 「Terms of Service」は行のほぼ中央(Helvetica 28pt で x = 約 230..400)
        XCTAssertGreaterThan(point.x, 220)
        XCTAssertLessThan(point.x, 420)
        XCTAssertGreaterThan(point.y, 10)
        XCTAssertLessThan(point.y, 50)
        // 行頭の語はもっと左 = 位置が語ごとに違う(要素の中心へ落ちていない)
        let head = await RegionText.locateLink(linkText: "Please", pngData: png, frame: screen, screen: screen)
        let headPoint = try XCTUnwrap(head?.point)
        XCTAssertLessThan(headPoint.x, 100)
    }

    func testLocateLinkReportsWhatItReadWhenTheTextIsAbsent() async throws {
        let png = try renderedLine("Please accept the Terms of Service today", width: 640, height: 60)
        let screen = FTRect(x: 0, y: 0, width: 640, height: 60)
        let located = await RegionText.locateLink(linkText: "Privacy Policy", pngData: png,
                                                  frame: screen, screen: screen)
        let result = try XCTUnwrap(located)
        XCTAssertNil(result.point)
        XCTAssertFalse(result.lines.isEmpty)
    }

    // MARK: - linkText が nil なら従来どおり

    func testFlowStepWithoutLinkTextKeepsCodeGenUnchanged() {
        let step = FlowStep(action: "tap", locator: FTSelector.parse("#a").primary)
        XCTAssertNil(step.linkText)
        XCTAssertEqual(ScenarioCodeGen.command(for: step), "tap(\"#a\")")
        var withLink = step
        withLink.linkText = "利用規約"
        XCTAssertEqual(ScenarioCodeGen.command(for: withLink), "tap(\"#a\", linkText: \"利用規約\")")
    }
}
