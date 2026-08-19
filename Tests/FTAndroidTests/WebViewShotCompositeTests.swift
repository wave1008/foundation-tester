// Android のスクリーンショットに WebView が写らないときの補完(WebViewShotComposite)の判定を固定する。
// 実機/エミュレータ依存の部分(CDP・adb)は外し、**貼るかどうかを決める2つの純粋判定**だけを見る。

import XCTest
import CoreGraphics
@testable import FTAndroid

final class WebViewShotCompositeTests: XCTestCase {

    /// 上から `bandStart` まで模様、以降は単色の画像を作る(高さ 1000)
    private func image(bandStart: Int, width: Int = 200, height: Int = 1000) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext の原点は左下。画像の上側(= y が小さい側)に模様を置く。
        // **全幅の帯にはしない**: 行全体が同色だと「1色の行」になり、模様のある領域まで
        // 帯として数えてしまう(実画面の文字は行の一部しか占めない)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        for y in stride(from: height - bandStart, to: height, by: 40) {
            context.fill(CGRect(x: 0, y: y, width: width / 2, height: 16))
        }
        return context.makeImage()!
    }

    /// 画面の過半が1色 = 写っていない疑い。**帯の位置と高さ**を返すこと(貼る位置になる)
    func testFindsTheDominantUniformBand() throws {
        let band = try XCTUnwrap(WebViewShotComposite.largestUniformBand(image(bandStart: 300)),
                                "画面の 70% が単色なのに帯を見つけていない")
        XCTAssertEqual(band.minY, 300, accuracy: 8, "帯の開始位置がずれている")
        XCTAssertEqual(band.height, 700, accuracy: 8)
        XCTAssertEqual(band.width, 200, "帯は全幅であること")
    }

    /// **余白が下半分に少しあるだけの普通の画面では発動しない** —— ここが緩いと、
    /// 貼らないと分かるまでに CDP へ問い合わせて数秒払う(2026-08-20 実測 3.4s)
    func testIgnoresOrdinaryTrailingWhitespace() {
        XCTAssertNil(WebViewShotComposite.largestUniformBand(image(bandStart: 700)),
                     "余白 30% で発動している(通常画面が毎回 CDP を叩く)")
    }

    /// 縦横比が合うときだけ貼る。**帯は「たまたま単色だった領域」のこともある**ので、
    /// 無関係な画像を貼らないための最後の門
    func testPastesOnlyWhenThePageMatchesTheBandShape() {
        let band = CGRect(x: 0, y: 300, width: 1080, height: 1900)
        XCTAssertTrue(WebViewShotComposite.fits(band: band, pageWidth: 1082, pageHeight: 1904),
                      "実測どおりの組(帯 1080x1900・ページ 1082x1904)を弾いている")
        XCTAssertFalse(WebViewShotComposite.fits(band: band, pageWidth: 1080, pageHeight: 400),
                       "形の違う画像を貼ろうとしている")
        XCTAssertFalse(WebViewShotComposite.fits(band: band, pageWidth: 0, pageHeight: 0),
                       "壊れた画像を貼ろうとしている")
    }

    /// 合成そのもの: 出力は base と同じ大きさで、**帯の位置の色が overlay のものに変わる**
    func testCompositeReplacesTheBandArea() throws {
        let base = image(bandStart: 300)
        let overlayContext = CGContext(data: nil, width: 200, height: 700, bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        overlayContext.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        overlayContext.fill(CGRect(x: 0, y: 0, width: 200, height: 700))
        // **中身のある画像**にする(単色を貼ると「まだ写っていない」と区別できない)
        overlayContext.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        for y in stride(from: 0, to: 700, by: 40) {
            overlayContext.fill(CGRect(x: 0, y: y, width: 100, height: 16))
        }
        let overlay = overlayContext.makeImage()!

        let png = try XCTUnwrap(WebViewShotComposite.composite(
            base: base, overlay: overlay, rect: CGRect(x: 0, y: 300, width: 200, height: 700)))
        let composed = try XCTUnwrap(WebViewShotComposite.cgImage(fromPNG: png))
        XCTAssertEqual(composed.width, base.width)
        XCTAssertEqual(composed.height, base.height)
        // 貼った領域が単色でなくなった(= 帯がもう「写っていない疑い」ではない)ことを、
        // 同じ判定器で確かめる
        XCTAssertNil(WebViewShotComposite.largestUniformBand(composed),
                     "貼った後も単色の帯が残っている(貼れていない)")
    }
}
