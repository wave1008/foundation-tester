// [PoC occlusion-guard] FM を呼ぶ前の安価な事前フィルタ(ピクセルのみ・FM 非依存)。
// 「ツリーはテキスト存在を主張するが、その frame 領域に実際にインク(高周波の濃淡)があるか」を
// 輝度標準偏差で測る。テキストがあれば中〜高、ベタ覆い/空白/減光では低い。
// これで「明らかにインクがある=見えている」assert を FM 抜きで pass させ、低インク(=疑い)だけを
// FM に回す。覆う要素がツリーに載るか否かに依らず効く(生描画レイヤも検知できる)のが利点。

import CoreGraphics
import Foundation
import ImageIO

public enum RegionInk {
    /// frame(pt)領域の輝度標準偏差(0〜約128)。nil = 画像/領域が不正。
    /// screen(pt)からスクショ(px)へのスケールを求めて px 領域を切り出す(Retina 対応)。
    public static func luminanceStdDev(pngData: Data, frame: FTRect, screen: FTRect) -> Double? {
        guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let sx = Double(img.width) / (screen.width == 0 ? Double(img.width) : screen.width)
        let sy = Double(img.height) / (screen.height == 0 ? Double(img.height) : screen.height)
        let rect = CGRect(x: frame.x * sx, y: frame.y * sy,
                          width: frame.width * sx, height: frame.height * sy)
            .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let crop = img.cropping(to: rect.integral) else { return nil }
        let w = crop.width, h = crop.height
        guard w * h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, sumSq = 0.0
        for v in buf { let d = Double(v); sum += d; sumSq += d * d }
        let n = Double(buf.count)
        let mean = sum / n
        return max(0, sumSq / n - mean * mean).squareRoot()
    }
}
