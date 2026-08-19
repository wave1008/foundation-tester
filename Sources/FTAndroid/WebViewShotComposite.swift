// Android のスクリーンショットに **WebView の中身が写らない**ときに、CDP から撮ったページ画像を
// その矩形へ貼って1枚に合成する。
//
// **端末側のキャプチャ経路の選び方の問題ではない**(2026-08-20 に E2E-Android の WebView 画面で
// 実測): ブリッジの `UiAutomation.takeScreenshot` / `adb exec-out screencap` /
// エミュレータの gRPC スクリーンショットの**3経路とも同じ空白**を返し、木には WebView の全要素が
// 実座標で載っていて、CDP の `Page.captureScreenshot` だけが中身を返した。つまりデバイスの
// フレームバッファにその層が居ない。**撮り方を替えても直らないので、外から補う**。
//
// 合成したかどうかは呼び出し側が「貼った/貼っていない」で分かる(この型は判定と描画だけを持つ)。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WebViewShotComposite {

    /// 合成を試すかどうかの**安い門**であり、**貼る位置の候補**でもある:
    /// 画面の高さの `minBandRatio` 以上を占める、全幅にわたって1色の帯。
    /// 帯が無い画面(通常のアプリ画面)は数ミリ秒で nil を返す。
    ///
    /// **既定 0.45 = 「画面の過半に近い部分が1色」**。写らなかった WebView は画面のほとんどを
    /// 占めるので、これで取り逃さない。下げると普通の画面(下半分が余白のリスト等)でも
    /// CDP を叩きに行き、**貼らないと分かるまでに 3 秒**払うことになる
    /// (2026-08-20 実測: 余白が高さの約 3 割ある一覧画面で 3.4s。0.45 なら門で終わって 0.3s)。
    ///
    /// **a11y の webView ノードを当てにしない**: Android は WebView の a11y サブツリーを
    /// 出したり出さなかったりする(2026-08-20 に同じ画面で「木に居る/居ない」の両方を実測)。
    /// ノードがあればそちらの矩形の方が正確なので、呼び出し側は木を優先し、無ければこの帯を使う
    static func largestUniformBand(_ image: CGImage, minBandRatio: Double = 0.45) -> CGRect? {
        guard let pixels = Pixels(image) else { return nil }
        var runStart = 0
        var run = 0
        var best: (start: Int, height: Int) = (0, 0)
        for y in stride(from: 0, to: pixels.height, by: rowStride) {
            if pixels.rowIsUniform(y: y) {
                if run == 0 { runStart = y }
                run += rowStride
                if run > best.height { best = (runStart, run) }
            } else {
                run = 0
            }
        }
        guard Double(best.height) >= Double(pixels.height) * minBandRatio else { return nil }
        return CGRect(x: 0, y: Double(best.start),
                      width: Double(pixels.width), height: Double(best.height))
    }

    /// どこへ貼るか。**領域の幅にページを合わせ、上端から貼る**。貼れないときは nil。
    ///
    /// 領域の出どころで許容が違う:
    /// - `known: true`(木の `webView` ノードの矩形) … そこが WebView だと**分かっている**ので、
    ///   高さのずれは広めに許す(スクロール位置やアドレスバーの分だけページ画像と食い違う)
    /// - `known: false`(画像から拾った1色の帯) … 帯は「たまたま1色だった領域」のこともあり、
    ///   **WebView がどこから始まるかも分からない**ので、縦横比がほぼ一致するときだけ貼る。
    ///   画面全体が真っ黒(= アプリの chrome ごと写っていない)ときはここで弾かれる ——
    ///   上端から貼るとナビゲーションバーの上にページを重ねてしまうため
    static func pasteRect(in region: CGRect, pageWidth: Int, pageHeight: Int,
                          known: Bool) -> CGRect? {
        guard pageWidth > 0, pageHeight > 0, region.width > 0, region.height > 0 else { return nil }
        let height = region.width * Double(pageHeight) / Double(pageWidth)
        let tolerance = known ? 0.35 : 0.1
        guard abs(height - region.height) <= region.height * tolerance else { return nil }
        return CGRect(x: region.minX, y: region.minY, width: region.width, height: height)
    }

    /// 木の座標(px)を画像の座標へ移す。**スクリーンショットが縮小されている端末**では
    /// 木の screen と画像の大きさが一致しないので、必ず比で合わせる
    static func imageRect(frame: (x: Double, y: Double, width: Double, height: Double),
                          screen: (width: Double, height: Double),
                          imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard screen.width > 0, screen.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        let sx = Double(imageWidth) / screen.width
        let sy = Double(imageHeight) / screen.height
        return CGRect(x: frame.x * sx, y: frame.y * sy,
                      width: frame.width * sx, height: frame.height * sy)
    }

    /// `overlay` を `rect`(画像の座標系・原点は左上)へ引き伸ばして `base` の上に描く
    static func composite(base: CGImage, overlay: CGImage, rect: CGRect) -> Data? {
        let width = base.width, height = base.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext の原点は左下。呼び出し側は木の座標(原点は左上)で渡すので反転する
        let flipped = CGRect(x: rect.minX, y: Double(height) - rect.maxY,
                             width: rect.width, height: rect.height)
        context.interpolationQuality = .high
        context.draw(overlay, in: flipped)
        guard let composed = context.makeImage() else { return nil }
        return png(from: composed)
    }

    /// 補えなかったときに出す説明。**黙って空白の画像を返さない**ためのもので、
    /// 読み手には理由が見えない(画像は真っ白/真っ黒なだけ)。最頻の原因は
    /// **アプリ側で WebView のデバッグが有効になっていない**こと ——
    /// `setWebContentsDebuggingEnabled(true)` が無いビルドには devtools のソケットが無く、
    /// ページを撮る手段が存在しない。**確かめ方まで書く**(原因の切り分けが利用者側にしかできない)
    static func blankCaptureWarning(hasWebViewNode: Bool) -> String {
        let area = hasWebViewNode ? "the WebView area" : "most of the screen"
        return "⚠️ the screen capture is blank across \(area), and the page could not be read"
            + " back over CDP. On Android the device capture can miss the WebView layer; ftester"
            + " fills it in from the page itself, which needs WebView debugging enabled in the app"
            + " under test (WebView.setWebContentsDebuggingEnabled(true), usually debug builds"
            + " only). Check with: adb -s <serial> shell cat /proc/net/unix | grep devtools_remote"
    }

    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func png(from image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// 走査の間引き幅(px)。**文字より小さくしない**(見落とすため)。実測の WebView 本文は
    /// 60px 以上あるので 8px なら十分細かい
    private static let rowStride = 8
    private static let columnStride = 8
    /// 1色とみなす色差(0〜255)。アンチエイリアスの揺れを拾わないための余裕
    private static let tolerance = 2

    /// 画素の読み出し。CGImage から一度だけ RGBA バッファを作る
    private struct Pixels {
        let width: Int
        let height: Int
        private let buffer: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            guard width > 0, height > 0 else { return nil }
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let drawn: Bool = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return nil }
            buffer = data
        }

        private func matches(_ a: Int, _ b: Int) -> Bool {
            for channel in 0..<3 where abs(Int(buffer[a + channel]) - Int(buffer[b + channel]))
                > WebViewShotComposite.tolerance { return false }
            return true
        }

        func rowIsUniform(y: Int) -> Bool {
            guard y >= 0, y < height else { return false }
            let base = y * width * 4
            for x in stride(from: columnStride, to: width, by: columnStride)
            where !matches(base, base + x * 4) { return false }
            return true
        }

    }
}
