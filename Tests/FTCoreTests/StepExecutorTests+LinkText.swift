import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore

/// `tap(sel, linkText:)` の OCR の撮り直し(LinkTextLocator.ocrShotAttempts)を StepExecutor ごと通す。
/// witness: E2EY-CMP の Android(M1Ultra)で、画面の切り替えの途中の白い絵を撮って「OCR read no text」で落ちた
final class StepExecutorLinkTextTests: XCTestCase {
    /// FakeAppDriver の木の画面と同じ寸法(400x800)の白い絵。text が nil なら文字を描かない
    private func shot(_ text: String?) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 400, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
        if let text {
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            // CG は左下原点: y=410 の基線 = 上からおよそ 370〜400 の帯(要素の枠の中)
            ctx.textPosition = CGPoint(x: 10, y: 410)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func paragraph() -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: "terms", label: "Please accept the Terms of Service",
                    value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 360, width: 400, height: 60), depth: 1)
    }

    private func run(screenshots: [Data], linkText: String) async -> (StepOutcome, FakeAppDriver) {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[paragraph()]],
                                   screenshots: screenshots)
        let executor = StepExecutor(driver: driver, occlusionOCRMode: .off, isAndroid: true, tunables: RunTunables())
        var step = FlowStep(action: "tap", locator: FlowLocator(id: "terms"))
        step.linkText = linkText
        return (await executor.execute(step), driver)
    }

    func testRetakesWhenTheFirstShotHasNoText() async throws {
        let (outcome, driver) = await run(screenshots: [try shot(nil), try shot("Please accept the Terms of Service")],
                                          linkText: "Terms of Service")
        guard case .passed = outcome.status else { XCTFail("実際は \(outcome.status)"); return }
        XCTAssertTrue((outcome.driverFallback ?? "").contains("located by ocr"), outcome.driverFallback ?? "nil")
        XCTAssertEqual(driver.screenshotCallCount, 2, "1枚目(文字の無い絵)で諦めず、撮り直した2枚目で決める")
    }

    func testDoesNotRetakeOnceTextWasRead() async throws {
        let (outcome, driver) = await run(screenshots: [try shot("Please accept the house rules")],
                                          linkText: "Terms of Service")
        guard case .failed = outcome.status else { XCTFail("実際は \(outcome.status)"); return }
        XCTAssertEqual(driver.screenshotCallCount, 1, "文字が読めた絵にリンクの語が無いなら、撮り直しても変わらない")
    }

    func testGivesUpAfterTheShotBudgetWhenNothingIsEverRead() async throws {
        let (outcome, driver) = await run(screenshots: [try shot(nil)], linkText: "Terms of Service")
        guard case .failed(let message) = outcome.status else { XCTFail("実際は \(outcome.status)"); return }
        XCTAssertTrue(message.contains("OCR read no text"), message)
        XCTAssertEqual(driver.screenshotCallCount, 3)
    }

    func testOCRShotDefaultsArePinned() {
        XCTAssertEqual(LinkTextLocator.ocrShotAttempts, 3)
        XCTAssertEqual(LinkTextLocator.ocrReshotInterval, .milliseconds(500))
        XCTAssertEqual(LinkTextLocator.ocrBudget, .seconds(10))
    }
}
