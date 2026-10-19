import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore

/// 描画崩壊の判定(`RenderCollapse`)と、実行機の義務の貯め方・区切りでの確かめ(`StepExecutor+RenderCollapse`)
final class RenderCollapseTests: XCTestCase {

    // 画面 400x800 pt・絵 400x800 px(倍率 1)
    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
    private let keyboard = FTRect(x: 0, y: 500, width: 400, height: 300)
    private let texts = [FTRect(x: 20, y: 100, width: 200, height: 30), FTRect(x: 20, y: 200, width: 200, height: 30),
                         FTRect(x: 20, y: 300, width: 200, height: 30)]
    private let button = FTRect(x: 20, y: 400, width: 360, height: 50)

    private func elements(textFrames: [FTRect]? = nil) -> [ElementInfo] {
        let frames = textFrames ?? texts
        return frames.enumerated().map { i, f in
            ElementInfo(ref: i + 1, type: "staticText", identifier: nil, label: "見出し\(i)", value: nil, placeholder: nil,
                        enabled: true, frame: f, depth: 1)
        } + [ElementInfo(ref: 99, type: "button", identifier: "btn", label: "送信", value: nil, placeholder: nil,
                         enabled: true, frame: button, depth: 1)]
    }

    /// 白地に、`shapes` を紫で塗り、`inked` の枠に縞(文字の代わりの構造)を描いた絵
    static func png(width: Int = 400, height: Int = 800, shapes: [FTRect] = [], inked: [FTRect] = [],
                    keys: FTRect? = nil) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func flip(_ r: FTRect) -> CGRect { CGRect(x: r.x, y: Double(height) - r.y - r.height, width: r.width, height: r.height) }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.6, alpha: 1))
        for s in shapes { context.fill(flip(s)) }
        for r in inked + (keys.map { [$0] } ?? []) {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            var x = r.x
            while x < r.x + r.width {
                context.fill(flip(FTRect(x: x, y: r.y, width: 2, height: r.height)))
                x += 4
            }
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func judge(_ png: Data, elements: [ElementInfo]? = nil, keyboard: FTRect? = nil) -> RenderCollapse.Finding? {
        RenderCollapse.judge(pngData: png, elements: elements ?? self.elements(), screen: screen, keyboard: keyboard,
                             inkThreshold: 12, minimumTextElements: RenderCollapse.minimumTextElements)
    }

    // MARK: - 判定

    func testWholeAppAreaInOneColourWithTextInTheTreeIsBlank() {
        XCTAssertEqual(judge(Self.png()), .blankAppArea(textElements: 3))
    }

    /// キーボード以外が真っ白(キーボードの範囲は除いて見る)
    func testBlankAboveTheKeyboardIsBlank() {
        let png = Self.png(keys: keyboard)
        XCTAssertEqual(judge(png, keyboard: keyboard), .blankAppArea(textElements: 3))
    }

    /// 形は描けているが文字が1つも無い(Compose の崩壊の形)
    func testShapesWithoutAnyTextIsNoTextDrawn() {
        XCTAssertEqual(judge(Self.png(shapes: [button])), .noTextDrawn(textElements: 3))
    }

    func testOneDrawnTextMeansNotCollapsed() {
        XCTAssertNil(judge(Self.png(shapes: [button], inked: [texts[1]])))
    }

    func testAllTextsDrawnIsNotCollapsed() {
        XCTAssertNil(judge(Self.png(shapes: [button], inked: texts)))
    }

    /// 文字の要素が閾値未満なら、文字が無いだけでは言わない(ラベルだけの単色の箱で偶然そろう)
    func testTooFewTextElementsAreNotJudgedForMissingText() {
        XCTAssertNil(judge(Self.png(shapes: [button]), elements: elements(textFrames: Array(texts.prefix(2)))))
    }

    /// 木に文字が無ければ一色でも言わない(白い画面そのものが正常かもしれない)
    func testBlankWithoutTextInTheTreeIsNotJudged() {
        XCTAssertNil(judge(Self.png(), elements: elements(textFrames: [])))
    }

    /// 絵と木の縦横が違う(横向きで絵だけ縦)なら判定しない
    func testOrientationMismatchIsNotJudged() {
        XCTAssertNil(judge(Self.png(width: 800, height: 400)))
    }

    /// キーボードの下の文字の要素は数えない(下にあって見えないのは崩壊ではない)
    func testTextUnderTheKeyboardIsNotCounted() {
        let under = texts + [FTRect(x: 20, y: 600, width: 200, height: 30)]
        let found = RenderCollapse.textElements(
            in: elements(textFrames: under), screen: screen,
            appArea: RenderCollapse.appArea(elements: elements(textFrames: under), screen: screen, keyboard: keyboard)!)
        XCTAssertEqual(found.count, 3)
    }

    /// Simulator の iOS の自前描画と、フレームワークが分からないときだけ確かめる
    func testOnlySelfRenderedOrUnknownFrameworksOnIOSSimulatorsAreChecked() {
        XCTAssertTrue(StepExecutor.checksRenderCollapse(platform: "ios", physical: false, framework: .compose))
        XCTAssertTrue(StepExecutor.checksRenderCollapse(platform: "ios", physical: false, framework: .flutter))
        XCTAssertTrue(StepExecutor.checksRenderCollapse(platform: "ios", physical: false, framework: nil))
        for framework in [AppUIFramework.swiftUI, .uikit, .reactNative] {
            XCTAssertFalse(StepExecutor.checksRenderCollapse(platform: "ios", physical: false, framework: framework),
                           "\(framework)")
        }
        XCTAssertFalse(StepExecutor.checksRenderCollapse(platform: "ios", physical: true, framework: .compose))
        XCTAssertFalse(StepExecutor.checksRenderCollapse(platform: "android", physical: false, framework: .compose))
    }

    func testDefaultsArePinned() {
        XCTAssertEqual(RenderCollapse.minimumTextElements, 3)
        XCTAssertEqual(RenderCollapse.orientationTolerance, 0.02)
        XCTAssertEqual(StepExecutor.renderCollapseRetakeSeconds, 1.0)
    }

    // MARK: - 実行機

    private func executor(screenshots: [Data], enabled: Bool = true) -> (StepExecutor, FakeAppDriver) {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [elements()])
        driver.screenshots = screenshots
        let executor = StepExecutor(driver: driver, occlusionGuardEnabled: false, isAndroid: false, tunables: RunTunables())
        executor.renderCollapseCheckEnabled = enabled
        return (executor, driver)
    }

    /// 画素を見ずに緑になった検証の後、区切りで崩壊を言う(失敗文に検証を名指しする)
    func testUnverifiedAssertionThenCollapsedScreenIsReported() async throws {
        let (executor, _) = executor(screenshots: [Self.png(shapes: [button])])
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn")))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        let verdict = await executor.renderCollapseVerdict()
        let message = try XCTUnwrap(verdict)
        XCTAssertTrue(message.contains("the screen is not rendered"), message)
        XCTAssertTrue(message.contains("none of the 3 text element(s)"), message)
        XCTAssertTrue(message.contains("exists"), message)
        let again = await executor.renderCollapseVerdict()
        XCTAssertNil(again, "義務は1回の確かめで下りる")
    }

    func testHealthyScreenIsNotReported() async {
        let (executor, _) = executor(screenshots: [Self.png(shapes: [button], inked: texts)])
        _ = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn")))
        let verdict = await executor.renderCollapseVerdict()
        XCTAssertNil(verdict)
    }

    /// 1枚目だけ崩れて見えた(遷移の一瞬)なら言わない
    func testCollapseSeenOnlyOnceIsNotReported() async {
        let (executor, driver) = executor(screenshots: [Self.png(), Self.png(shapes: [button], inked: texts)])
        _ = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn")))
        let verdict = await executor.renderCollapseVerdict()
        XCTAssertNil(verdict)
        XCTAssertEqual(driver.screenshotCallCount, 2, "撮り直して確かめるはず")
    }

    /// 検証が無ければ撮らない(費用は文字の検証が届かなかった区間だけ)
    func testNoPendingAssertionTakesNoScreenshot() async {
        let (executor, driver) = executor(screenshots: [Self.png()])
        let verdict = await executor.renderCollapseVerdict()
        XCTAssertNil(verdict)
        XCTAssertEqual(driver.screenshotCallCount, 0)
    }

    /// 画素で文字を確かめた検証は義務を下ろす
    func testPixelProofClearsTheDuty() async {
        let (executor, driver) = executor(screenshots: [Self.png()])
        executor.noteAssertionForRenderCollapse("exists", step: FlowStep(assert: "exists", locator: FlowLocator(id: "a")),
                                                status: .passed)
        executor.pixelsShowedTextThisStep = true
        executor.noteAssertionForRenderCollapse("textEquals", step: FlowStep(assert: "textEquals"), status: .passed)
        let verdict = await executor.renderCollapseVerdict()
        XCTAssertNil(verdict)
        XCTAssertEqual(driver.screenshotCallCount, 0)
    }

    /// 無効(実機・Android)なら貯めず撮らない
    func testDisabledDoesNothing() async {
        let (executor, driver) = executor(screenshots: [Self.png()], enabled: false)
        _ = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn")))
        let verdict = await executor.renderCollapseVerdict()
        XCTAssertNil(verdict)
        XCTAssertEqual(driver.screenshotCallCount, 0)
    }

    /// 計測の切り替え: 緑の検証のたびに確かめて、崩壊ならその検証を赤にする
    func testEveryAssertionModeTurnsThePassingCheckRed() async {
        let (executor, _) = executor(screenshots: [Self.png()])
        executor.renderCollapseEveryAssertion = true
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn")))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("the app's area of the screenshot is a single colour"), message)
    }

    /// 陽性対照の注入は判定の答えだけを差し替える
    func testInjectionReportsCollapseOnAHealthyScreen() async {
        let (executor, _) = executor(screenshots: [Self.png(shapes: [button], inked: texts)])
        executor.renderCollapseInjected = true
        _ = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn")))
        let verdict = await executor.renderCollapseVerdict()
        XCTAssertNotNil(verdict)
    }
}
