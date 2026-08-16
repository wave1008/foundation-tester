import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageDownscale {
    /// PNG → 幅 maxWidth 以内へ縮小 → JPEG。ImageIO のサムネイル生成を使う(自前の描画より速い)。
    /// maxWidth は「幅」の上限。kCGImageSourceThumbnailMaxPixelSize は**長辺**の上限なので、
    /// 縦長画像ではそのまま渡すと幅が指定より大幅に小さくなる(1080x2340 で 360 指定 → 166x360)。
    /// 長辺換算に直してから渡す。失敗(壊れた PNG 等)は nil
    public static func jpeg(png: Data, maxWidth: Int, quality: Double) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? maxWidth
        let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? maxWidth
        let longSide: Int = {
            guard sourceWidth > 0, maxWidth < sourceWidth else { return max(sourceWidth, sourceHeight) }
            let scale = Double(maxWidth) / Double(sourceWidth)
            return Int((Double(max(sourceWidth, sourceHeight)) * scale).rounded())
        }()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(longSide, 1),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, image.width, image.height)
    }
}
