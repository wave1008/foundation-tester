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
