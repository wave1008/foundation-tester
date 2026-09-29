import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore

final class BlankFrameDetectorTests: XCTestCase {

    func testUniformWhiteIsBlank() {
        let png = Self.makePNG(width: 64, height: 64) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        XCTAssertTrue(BlankFrameDetector.isUniformBlank(pngData: png))
    }

    func testUniformBlackIsBlank() {
        let png = Self.makePNG(width: 64, height: 64) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        XCTAssertTrue(BlankFrameDetector.isUniformBlank(pngData: png))
    }

    func testCenteredContentRectIsNotBlank() {
        let png = Self.makePNG(width: 64, height: 64) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 24, y: 24, width: 16, height: 16))
        }
        XCTAssertFalse(BlankFrameDetector.isUniformBlank(pngData: png))
    }

    func testSplitColorImageIsNotBlank() {
        let png = Self.makePNG(width: 64, height: 64) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        }
        XCTAssertFalse(BlankFrameDetector.isUniformBlank(pngData: png))
    }

    // MARK: - uniformBlankness(判定不能を nil で返す口)

    func testUniformBlanknessReturnsNilForEmptyData() {
        XCTAssertNil(BlankFrameDetector.uniformBlankness(pngData: Data()))
    }

    func testUniformBlanknessReturnsNilForNonPNGData() {
        XCTAssertNil(BlankFrameDetector.uniformBlankness(pngData: Data("not a png".utf8)))
    }

    func testUniformBlanknessReturnsTrueForUniformWhiteAndFalseForContent() {
        let blank = Self.makePNG(width: 64, height: 64) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        XCTAssertEqual(BlankFrameDetector.uniformBlankness(pngData: blank), true)

        let content = Self.makePNG(width: 64, height: 64) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 24, y: 24, width: 16, height: 16))
        }
        XCTAssertEqual(BlankFrameDetector.uniformBlankness(pngData: content), false)
    }

    /// isUniformBlank は判定不能も false に丸める(他の呼び出し元3箇所が依存する安全側の契約)。
    /// uniformBlankness を足しても isUniformBlank の挙動は変わらないことを固定する
    func testIsUniformBlankStillFoldsUndecodableToFalse() {
        XCTAssertFalse(BlankFrameDetector.isUniformBlank(pngData: Data()))
        XCTAssertFalse(BlankFrameDetector.isUniformBlank(pngData: Data("not a png".utf8)))
    }

    // MARK: - FrozenFrameJudgement(システムアラートの白を凍結の根拠にしない)

    func testBlankWithNoSystemAlertIsFrozen() {
        XCTAssertTrue(FrozenFrameJudgement.shouldMarkFrozen(evidenceBlank: true,
                                                            systemAlertPresent: false))
    }

    /// 白フレームでも、前面にシステムアラートがあると分かっているなら凍結ではない
    func testBlankWithSystemAlertPresentIsNotFrozen() {
        XCTAssertFalse(FrozenFrameJudgement.shouldMarkFrozen(evidenceBlank: true,
                                                             systemAlertPresent: true))
    }

    func testNotBlankIsNeverFrozenRegardlessOfAlert() {
        XCTAssertFalse(FrozenFrameJudgement.shouldMarkFrozen(evidenceBlank: false,
                                                             systemAlertPresent: false))
        XCTAssertFalse(FrozenFrameJudgement.shouldMarkFrozen(evidenceBlank: false,
                                                             systemAlertPresent: true))
    }

    // MARK: - テスト用 PNG 合成

    // MARK: - 下端の帯を除いて黒い絵(occlusion-guard の素通り判定)

    private static let blackFrames = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/BlackFrames")

    /// 実際に出た黒い絵(負荷テスト 2026-09-27)
    func testRealBlackFramesWithABottomBarAreBlack() throws {
        for name in ["android-emulator-black-with-nav-handle.png", "ios-inapp-black-with-home-indicator.png"] {
            let png = try Data(contentsOf: Self.blackFrames.appendingPathComponent(name))
            XCTAssertTrue(BlankFrameDetector.isBlackApartFromBottomStrip(pngData: png), name)
        }
        // Android のナビゲーションハンドルは一様判定を割る(= この判定が要る理由)
        let android = try Data(contentsOf: Self.blackFrames
            .appendingPathComponent("android-emulator-black-with-nav-handle.png"))
        XCTAssertFalse(BlankFrameDetector.isUniformBlank(pngData: android))
        XCTAssertEqual(FrameBlankness.observe(pngData: android),
                       FrameBlankness(uniform: false, blackApartFromBottomStrip: true))
    }

    /// 一部だけ黒い実画面(WebView の下に黒い帯)は黒い絵ではない
    func testRealPartlyBlackScreenIsNotBlack() throws {
        let png = try Data(contentsOf: Self.blackFrames.appendingPathComponent("ios-partly-black-webview.png"))
        XCTAssertFalse(BlankFrameDetector.isBlackApartFromBottomStrip(pngData: png))
    }

    /// 暗い画面に小さな文字が1語だけ = 黒い絵ではない(16x16 だとセル平均に薄まって黒に紛れる大きさ)
    func testDarkScreenWithOneSmallWordIsNotBlack() {
        let png = Self.makePNG(width: 1080, height: 2340) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1080, height: 2340))
            context.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 60, y: 1500, width: 70, height: 30))
        }
        XCTAssertFalse(BlankFrameDetector.isBlackApartFromBottomStrip(pngData: png))
    }

    /// 上端(ステータスバー)に何か描かれていれば黒い絵ではない = 見ないのは下端だけ
    func testContentInTheTopRowIsNotIgnored() {
        let png = Self.makePNG(width: 400, height: 800) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            // CG の原点は左下 = y 780 は画像の上端
            context.fill(CGRect(x: 150, y: 780, width: 100, height: 20))
        }
        XCTAssertFalse(BlankFrameDetector.isBlackApartFromBottomStrip(pngData: png))
    }

    /// 撮れていない絵に**ステータスバーだけ**残った実物(Android Emulator。3 台の Mac の OCR が同じ 2 行だけを読んだ)。
    /// 視覚検証の素通りの判定は黒と言い、凍結の警告の判定は言わない(上端に中身のある暗い画面を凍結と呼ばない)
    func testRealBlackFrameWithAStatusBarIsBlackOnlyForTheVisualCheck() throws {
        let png = try Data(contentsOf: Self.blackFrames
            .appendingPathComponent("android-emulator-black-with-status-bar.png"))
        XCTAssertTrue(BlankFrameDetector.isBlackApartFromSystemBars(pngData: png))
        XCTAssertFalse(BlankFrameDetector.isBlackApartFromBottomStrip(pngData: png))
    }

    /// 視覚検証の判定が見ないのは上端の帯(約 6%)だけ。その下に中身があれば黒い絵ではない
    func testSystemBarsCheckStillSeesContentBelowTheStatusBar() {
        let png = Self.makePNG(width: 400, height: 800) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            // CG の原点は左下 = y 700〜730 は上から 9〜12%(帯の下)
            context.fill(CGRect(x: 150, y: 700, width: 100, height: 30))
        }
        XCTAssertFalse(BlankFrameDetector.isBlackApartFromSystemBars(pngData: png))
    }

    /// 上端の帯(ステータスバー)の中身は視覚検証の判定では見ない
    func testSystemBarsCheckIgnoresTheStatusBar() {
        let png = Self.makePNG(width: 400, height: 800) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 150, y: 780, width: 100, height: 20))
        }
        XCTAssertTrue(BlankFrameDetector.isBlackApartFromSystemBars(pngData: png))
    }

    private static func makePNG(width: Int, height: Int, draw: (CGContext) -> Void) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("テスト用 CGContext 生成に失敗")
        }
        draw(context)
        guard let image = context.makeImage() else {
            fatalError("テスト用 CGImage 生成に失敗")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("テスト用 PNG destination 生成に失敗")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("テスト用 PNG 書き出しに失敗")
        }
        return output as Data
    }
}
