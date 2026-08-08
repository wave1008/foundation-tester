import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore

/// ImageDownscale.jpeg の境界。とくに kCGImageSourceThumbnailMaxPixelSize が**長辺**基準という
/// 罠(縦長で maxWidth をそのまま渡すと想定より小さくなる)を、縦長入力で width が
/// maxWidth に近いことまで確認して踏まないようにする(旧 devicepoll 実装のコメント参照)
final class ImageDownscaleTests: XCTestCase {

    /// checkerboard で塗った PNG(単色だと JPEG 圧縮率の差が出ず縮小確認に使えない)
    private func checkerboardPNG(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let tile = 8
        for y in stride(from: 0, to: height, by: tile) {
            for x in stride(from: 0, to: width, by: tile) {
                let on = ((x / tile) + (y / tile)).isMultiple(of: 2)
                context.setFillColor(on ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
                                         : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: tile, height: tile))
            }
        }
        let image = context.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func pixelSize(of jpeg: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    func testLandscapeWidthIsClampedToMaxWidth() {
        let png = checkerboardPNG(width: 1200, height: 600)
        let result = ImageDownscale.jpeg(png: png, maxWidth: 300, quality: 0.6)
        XCTAssertEqual(result?.width, 300)
        XCTAssertEqual(result?.height, 150)
    }

    /// 縦長で長辺(=高さ)基準の罠を踏んでいたら、width は maxWidth よりかなり小さくなる
    /// (1080x2340 で 360 指定 → 166x360 になっていた旧不具合と同型)。ここでは
    /// width が maxWidth に一致することまで見て、罠の再発を検出する
    func testPortraitWidthMatchesMaxWidthNotLongSide() {
        let png = checkerboardPNG(width: 1080, height: 2340)
        let result = ImageDownscale.jpeg(png: png, maxWidth: 360, quality: 0.6)
        XCTAssertEqual(result?.width, 360)
        XCTAssertEqual(result?.height, 780)
    }

    func testMaxWidthLargerThanSourceDoesNotUpscale() {
        let png = checkerboardPNG(width: 200, height: 100)
        let result = ImageDownscale.jpeg(png: png, maxWidth: 800, quality: 0.6)
        XCTAssertEqual(result?.width, 200)
        XCTAssertEqual(result?.height, 100)
    }

    /// 出力が JPEG として復号でき、寸法が保たれること。**バイト数では判定しない** ——
    /// 市松模様のような合成画像は可逆圧縮(PNG)のほうが小さくなり、JPEG 化の成否を表さない
    func testOutputIsValidJPEGOfTheSameSize() throws {
        let png = checkerboardPNG(width: 800, height: 800)
        let result = try XCTUnwrap(ImageDownscale.jpeg(png: png, maxWidth: 800, quality: 0.6))
        let decoded = try XCTUnwrap(pixelSize(of: result.data))
        XCTAssertEqual(decoded.width, 800)
        XCTAssertEqual(decoded.height, 800)
    }

    /// 縮小そのものは**画素数**で判定する(バイト数は画像の中身に左右される)
    func testDownscaleReducesPixelCount() throws {
        let png = checkerboardPNG(width: 1200, height: 900)
        let result = try XCTUnwrap(ImageDownscale.jpeg(png: png, maxWidth: 300, quality: 0.6))
        let decoded = try XCTUnwrap(pixelSize(of: result.data))
        XCTAssertEqual(decoded.width, 300)
        XCTAssertEqual(decoded.height, 225)
    }

    func testCorruptInputReturnsNilWithoutCrashing() {
        XCTAssertNil(ImageDownscale.jpeg(png: Data([0x00, 0x01]), maxWidth: 300, quality: 0.6))
        XCTAssertNil(ImageDownscale.jpeg(png: Data(), maxWidth: 300, quality: 0.6))
    }
}
