import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore

final class RegionTextTests: XCTestCase {

    // MARK: - readable(純関数)

    func testReadableTrueOnFullContainment() {
        XCTAssertTrue(RegionText.readable(expected: "ログイン", lines: ["ログイン"]))
    }

    /// 先頭一致だけ(期待の一部しか読めていない)は false —— 部分的に覆われて残りだけ読めた回を
    /// 「見えている」と通すと、guard の目的である誤った緑を作る
    func testReadableFalseOnPrefixOnlyMatch() {
        XCTAssertFalse(RegionText.readable(expected: "家電・電化製品", lines: ["家電・電化…"]))
    }

    func testReadableNormalizesWhitespaceFullwidthCaseAndEllipsis() {
        XCTAssertTrue(RegionText.readable(expected: "Log In...", lines: [" log　in "]))
    }

    /// 素の部分一致だと短い期待値が覆いの文字列に当たる(`exist("OK")` が「Cookieの設定」で素通り)。
    /// ASCII の期待値は語境界を要求する
    func testReadableRequiresAWordBoundaryForAsciiExpectations() {
        XCTAssertFalse(RegionText.readable(expected: "OK", lines: ["Cookieの設定"]))
        XCTAssertFalse(RegionText.readable(expected: "row", lines: ["arrow_40"]))
        XCTAssertTrue(RegionText.readable(expected: "OK", lines: ["OK!"]))
        XCTAssertTrue(RegionText.readable(expected: "row_40", lines: ["selected=row_40"]))
    }

    /// 日本語には語境界が無いので、CJK を含む期待値は素の含有のまま(折り返しも通る)
    func testReadableKeepsPlainContainmentForJapanese() {
        XCTAssertTrue(RegionText.readable(expected: "ログイン", lines: ["ログインしてください"]))
    }

    /// 拡大は画素の上限を超えたら諦める(読めるようにはならず、ビットマップだけが数十 MB になる)
    func testEnlargeStopsAtThePixelCap() {
        let small = makeCGImage(width: 200, height: 100)
        XCTAssertEqual(RegionText.enlarged(small, by: 3).width, 600)
        let large = makeCGImage(width: 2000, height: 1000)   // ×3 で 18 MP = 上限超え
        XCTAssertEqual(RegionText.enlarged(large, by: 3).width, 2000)
    }

    private func makeCGImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testReadableFalseWhenExpectedIsEmpty() {
        XCTAssertFalse(RegionText.readable(expected: "   ", lines: ["ログイン"]))
    }

    /// 折り返しで2行に分かれて読めても、返ってきた順に連結すれば含有するなら true
    func testReadableJoinsWrappedLines() {
        XCTAssertTrue(RegionText.readable(expected: "ログインしてください", lines: ["ログインして", "ください"]))
    }

    // MARK: - mode(environment:)

    func testModeOnValues() {
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "1"]), .on)
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "on"]), .on)
    }

    func testModeOffValues() {
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "0"]), .off)
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "off"]), .off)
    }

    func testModeMeasureValue() {
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "measure"]), .measure)
    }

    /// 既定はリテラルで固定する(差し替え口でしか値を書かないと、既定を戻す変更が緑のまま通る)
    func testModeDefaultsToOnWhenUnset() {
        XCTAssertEqual(RegionText.mode(environment: [:]), .on)
    }

    func testModeOnOnUnrecognizedValue() {
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "nonsense"]), .on)
    }

    // MARK: - Vision 往復(テストが production の代わりに正規化していないことの担保)

    /// AppKit(WindowServer)に依存しない CoreText 直描画。CGContext は原点左下・y 上向きで、
    /// CTLineDraw もこれをそのまま前提にする(フリップ不要)
    private func makeTextPNG(_ text: String?) -> Data {
        let width = 240, height = 80
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("テスト用 CGContext 生成に失敗")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            // CJK の字形は基準フォントに無くても CoreText のカスケード(自動代替)で描かれる
            let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 10, y: CGFloat(height) / 2 - 10)
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { fatalError("テスト用 CGImage 生成に失敗") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("テスト用 PNG destination 生成に失敗")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("テスト用 PNG 書き出しに失敗") }
        return output as Data
    }

    func testReadRoundTripsThroughVisionForRenderedText() async throws {
        let png = makeTextPNG("ログイン")
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let readingRaw = await RegionText.read(pngData: png, frame: rect, screen: rect)
        let reading = try XCTUnwrap(readingRaw)
        XCTAssertTrue(RegionText.readable(expected: "ログイン", lines: reading.lines),
                     "描いた文字列が読めるはず: \(reading.lines)")
        // 遅かった回の説明に使う画素数(等倍・frame = 画像全体なので画像そのものの画素数)
        XCTAssertEqual(reading.pixels, 240 * 80, "読ませた画像の画素数が記録されていない")
    }

    func testReadFindsNothingOnBlankImage() async throws {
        let png = makeTextPNG(nil)
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let readingRaw = await RegionText.read(pngData: png, frame: rect, screen: rect)
        let reading = try XCTUnwrap(readingRaw)
        XCTAssertFalse(RegionText.readable(expected: "ログイン", lines: reading.lines))
    }

    /// 読ませる言語は期待文字列から決める(日本語モデルの読み込みが所要の6割 —— 実測 p50 91→208ms)
    func testLanguagesFollowTheExpectedText() {
        XCTAssertEqual(RegionText.languages(for: "swipe=down"), ["en-US"])
        XCTAssertEqual(RegionText.languages(for: "ログイン"), ["ja-JP", "en-US"])
        XCTAssertEqual(RegionText.languages(for: "WebView 見出し"), ["ja-JP", "en-US"])
    }

    /// 拡大の段はリテラルで固定する(実測: ×1 で 71% → ×2 まで 88% → ×3 まで 97%・×4 は 74% に落ちる。
    /// docs/poc-fm-occlusion-guard.md §5.17)
    func testUpscaleLadderIsPinned() {
        XCTAssertEqual(RegionText.upscaleLadder, [1, 2, 3])
    }

    func testResolveReadsRenderedText() async throws {
        let png = makeTextPNG("ログイン")
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let resolvedRaw = await RegionText.resolve(expected: "ログイン", pngData: png,
                                                   frame: rect, screen: rect)
        let resolved = try XCTUnwrap(resolvedRaw)
        XCTAssertTrue(resolved.readable, "描いた文字列が読めるはず: \(resolved.reading.lines)")
    }

    /// 段を上げても読めない画像(白紙 = 覆い/空白の代理)は readable=false のまま FM へ回る
    func testResolveStaysUnreadableForBlankImage() async throws {
        let png = makeTextPNG(nil)
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let resolvedRaw = await RegionText.resolve(expected: "ログイン", pngData: png,
                                                   frame: rect, screen: rect)
        let resolved = try XCTUnwrap(resolvedRaw)
        XCTAssertFalse(resolved.readable)
    }

    /// 暖機を頼むのは on / measure のときだけ(off の run に Vision を読ませない)
    func testPrewarmIsRequestedOnlyWhenGateIsActive() {
        let before = RegionText.prewarmRequestCount
        RegionText.prewarmIfNeeded(mode: .off)
        XCTAssertEqual(RegionText.prewarmRequestCount, before, "off では暖機しない")
        RegionText.prewarmIfNeeded(mode: .on)
        RegionText.prewarmIfNeeded(mode: .measure)
        XCTAssertEqual(RegionText.prewarmRequestCount, before + 2)
    }

    /// 暖機は何度呼んでも安全で、そのあとの読み取りを壊さない(背景で走るので待たない)
    func testPrewarmIsIdempotentAndLeavesReadsWorking() async throws {
        RegionText.prewarmIfNeeded(mode: .on)
        RegionText.prewarmIfNeeded(mode: .on)
        let png = makeTextPNG("ログイン")
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let readingRaw = await RegionText.read(pngData: png, frame: rect, screen: rect)
        let reading = try XCTUnwrap(readingRaw)
        XCTAssertTrue(RegionText.readable(expected: "ログイン", lines: reading.lines))
    }
}
