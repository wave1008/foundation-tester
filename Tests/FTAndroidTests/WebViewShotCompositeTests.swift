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

    /// 帯から決めるときは**縦横比がほぼ一致するときだけ**貼る。
    /// 帯は「たまたま単色だっただけの領域」のこともあり、WebView がどこから始まるかも
    /// 分からないため
    func testPastesFromABandOnlyWhenTheShapeMatches() throws {
        let band = CGRect(x: 0, y: 300, width: 1080, height: 1900)
        let rect = try XCTUnwrap(WebViewShotComposite.pasteRect(
            in: band, pageWidth: 1082, pageHeight: 1904, known: false),
            "実測どおりの組(帯 1080x1900・ページ 1082x1904)を弾いている")
        XCTAssertEqual(rect.minY, 300, "帯の上端から貼ること")
        XCTAssertNil(WebViewShotComposite.pasteRect(in: band, pageWidth: 1080, pageHeight: 400,
                                                    known: false),
                     "形の違う画像を帯へ貼ろうとしている")
        XCTAssertNil(WebViewShotComposite.pasteRect(in: band, pageWidth: 0, pageHeight: 0,
                                                    known: false))
    }

    /// **画面全体が1色になる端末**(アプリの chrome ごと写らない)では、帯 = 画面全体になり
    /// ページと縦横比が合わない。**木の webView ノードがあればそちらへ貼る** ——
    /// 受け手の端末で「合成が1枚も発動しない」と報告された形(2026-08-20)。
    /// ここが落ちると、真っ黒なスクリーンショットが救われないまま返る
    func testPastesIntoTheKnownWebViewRectEvenWhenTheWholeScreenIsBlank() throws {
        let fullScreen = CGRect(x: 0, y: 0, width: 1080, height: 2424)
        XCTAssertNil(WebViewShotComposite.pasteRect(in: fullScreen, pageWidth: 1082,
                                                    pageHeight: 1904, known: false),
                     "画面全体の帯へ貼ると chrome の上にページを重ねてしまう")
        let node = CGRect(x: 0, y: 332, width: 1080, height: 1903)
        let rect = try XCTUnwrap(WebViewShotComposite.pasteRect(
            in: node, pageWidth: 1082, pageHeight: 1904, known: true))
        XCTAssertEqual(rect.minY, 332, "webView ノードの位置へ貼ること")
        XCTAssertEqual(rect.height, 1903, accuracy: 20)
        // 木の矩形でも、まるで形の違う画像は貼らない
        XCTAssertNil(WebViewShotComposite.pasteRect(in: node, pageWidth: 1080, pageHeight: 300,
                                                    known: true))
    }

    /// 木の座標 → 画像の座標(スクリーンショットが縮小されている端末のため)
    func testMapsTreeCoordinatesOntoTheImage() throws {
        let rect = try XCTUnwrap(WebViewShotComposite.imageRect(
            frame: (0, 300, 540, 900), screen: (540, 1200), imageWidth: 1080, imageHeight: 2400))
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.minY, 600, "縦の比で拡大されていない")
        XCTAssertEqual(rect.width, 1080)
        XCTAssertEqual(rect.height, 1800)
    }

    /// 補えなかったときは**黙らない**。文言に「何ができなかったか」と「確かめ方」が入っていること
    /// —— 原因(アプリのビルド設定)は利用者側にしか分からないので、そこへ橋渡しできないと
    /// 真っ黒な画像だけが残る
    func testBlankCaptureWarningSaysHowToCheck() {
        let text = WebViewShotComposite.blankCaptureWarning(hasWebViewNode: true)
        XCTAssertTrue(text.contains("the WebView area"), text)
        XCTAssertTrue(text.contains("setWebContentsDebuggingEnabled"), "原因の当たりが無い: \(text)")
        XCTAssertTrue(text.contains("devtools_remote"), "確かめ方が無い: \(text)")
        XCTAssertTrue(WebViewShotComposite.blankCaptureWarning(hasWebViewNode: false)
            .contains("most of the screen"), "木が無い場合の言い分けが無い")
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

    /// 警告の once は serial ごと・プロセス全体(ドライバのインスタンスを跨ぐ)。
    /// serial は同一プロセスの他テストと衝突しないよう一意にする
    func testBlankCaptureWarningFiresOncePerSerialAcrossCalls() {
        let a = "test-serial-\(UUID().uuidString)"
        let b = "test-serial-\(UUID().uuidString)"
        XCTAssertTrue(WebViewShotComposite.shouldWarnBlankCapture(serial: a))
        XCTAssertFalse(WebViewShotComposite.shouldWarnBlankCapture(serial: a))
        XCTAssertFalse(WebViewShotComposite.shouldWarnBlankCapture(serial: a))
        XCTAssertTrue(WebViewShotComposite.shouldWarnBlankCapture(serial: b), "別の台は別に1回言う")
    }
}
