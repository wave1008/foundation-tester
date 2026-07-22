import CoreGraphics
import XCTest
import FTCore
@testable import FTAgent

final class OcclusionCropRectTests: XCTestCase {

    private func fraction(_ rect: CGRect, elementWpx: CGFloat, elementHpx: CGFloat) -> (w: CGFloat, h: CGFloat) {
        (elementWpx / rect.width, elementHpx / rect.height)
    }

    /// 小要素(16x16pt, scale 1): 固定 24px 余白だとクロップの 25% しか占めず FM が近傍を見て誤反転する。
    /// 適応余白で対象が概ね 55% 以上を占めること(= 誤反転の主因を除去)。
    func testSmallElementStaysDominant() throws {
        let frame = FTRect(x: 200, y: 400, width: 16, height: 16)
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let rect = try XCTUnwrap(OcclusionVerifier.cropRect(
            frame: frame, screen: screen, imageWidth: 400, imageHeight: 800, cropPadding: 24))
        let f = fraction(rect, elementWpx: 16, elementHpx: 16)
        XCTAssertGreaterThanOrEqual(f.w, 0.55, "対象が横方向でクロップの過半を占めない")
        XCTAssertGreaterThanOrEqual(f.h, 0.55, "対象が縦方向でクロップの過半を占めない")
        // 旧固定余白(16/(16+48)=0.25)より明確に改善していること。
        XCTAssertGreaterThan(f.w, 0.25)
    }

    /// Retina(scale 3)でも同様に対象が支配的であること(pt→px 換算が余白比に効く)。
    func testSmallElementRetinaStaysDominant() throws {
        let frame = FTRect(x: 100, y: 100, width: 16, height: 16)   // px: 48x48
        let screen = FTRect(x: 0, y: 0, width: 390, height: 844)
        let rect = try XCTUnwrap(OcclusionVerifier.cropRect(
            frame: frame, screen: screen, imageWidth: 1170, imageHeight: 2532, cropPadding: 24))
        let f = fraction(rect, elementWpx: 48, elementHpx: 48)
        XCTAssertGreaterThanOrEqual(f.w, 0.55)
        XCTAssertGreaterThanOrEqual(f.h, 0.55)
    }

    /// 大要素(横 300px)では従来どおり cropPadding(24px)が余白になる(適応縮小が過剰に効かない)。
    func testLargeElementKeepsFullPadding() throws {
        let frame = FTRect(x: 40, y: 500, width: 300, height: 200)
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let rect = try XCTUnwrap(OcclusionVerifier.cropRect(
            frame: frame, screen: screen, imageWidth: 400, imageHeight: 800, cropPadding: 24))
        // クランプが無い位置なので crop 幅 = 300 + 24*2、高さ = 200 + 24*2。
        XCTAssertEqual(rect.width, 300 + 48, accuracy: 0.5)
        XCTAssertEqual(rect.height, 200 + 48, accuracy: 0.5)
    }

    /// 退化 frame(幅 0)はクロップ不能で nil(FM に無意味な領域を渡さない)。
    func testDegenerateFrameReturnsNil() {
        let frame = FTRect(x: 10, y: 10, width: 0, height: 20)
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertNil(OcclusionVerifier.cropRect(
            frame: frame, screen: screen, imageWidth: 400, imageHeight: 800, cropPadding: 24))
    }

    /// 画面端の要素は画像境界にクランプされ、負座標や画像外へはみ出さない。
    func testEdgeElementClampsToImageBounds() throws {
        let frame = FTRect(x: 0, y: 0, width: 30, height: 30)
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let rect = try XCTUnwrap(OcclusionVerifier.cropRect(
            frame: frame, screen: screen, imageWidth: 400, imageHeight: 800, cropPadding: 24))
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 400)
        XCTAssertLessThanOrEqual(rect.maxY, 800)
    }
}
