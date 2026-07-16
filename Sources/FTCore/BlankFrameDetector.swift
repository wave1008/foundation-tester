// 画面凍結時の「一様フレーム」(白/黒ベタ)を解像度・縮小に依存せず判定する。
// AndroidHealthProbe.blankScreen(PNG サイズ閾値、adb screencap 全解像度前提)とは別軸の判定:
// こちらはブリッジ縮小スクショ等どんな解像度でも使え、内容のある画面(アイコン・文字・ボタン)は
// サンプル点が割れるため誤検知しない。

import CoreGraphics
import Foundation
import ImageIO

public enum BlankFrameDetector {
    /// pngData を sampleGrid×sampleGrid に縮小描画し、基準ピクセル(先頭サンプル)から全チャンネル
    /// tolerance 以内の点が uniformFraction 以上を占めれば一様フレーム(凍結症状)と判定する。
    /// alpha は無視(白黒どちらのベタも検出対象。白限定にしない)。
    /// デコード・描画に失敗した場合は false(過検知よりプローブ欠測を優先する安全側)。
    public static func isUniformBlank(pngData: Data,
                                      sampleGrid: Int = 16,
                                      tolerance: Int = 8,
                                      uniformFraction: Double = 0.995) -> Bool {
        guard sampleGrid > 0,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return false
        }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * sampleGrid
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * sampleGrid)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let fraction: Double? = buffer.withUnsafeMutableBytes { rawBuffer -> Double? in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(data: baseAddress, width: sampleGrid, height: sampleGrid,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleGrid, height: sampleGrid))

            let total = sampleGrid * sampleGrid
            let baseR = Int(rawBuffer[0]), baseG = Int(rawBuffer[1]), baseB = Int(rawBuffer[2])
            var uniformCount = 0
            for i in 0..<total {
                let offset = i * bytesPerPixel
                let r = Int(rawBuffer[offset]), g = Int(rawBuffer[offset + 1]), b = Int(rawBuffer[offset + 2])
                if abs(r - baseR) <= tolerance, abs(g - baseG) <= tolerance, abs(b - baseB) <= tolerance {
                    uniformCount += 1
                }
            }
            return Double(uniformCount) / Double(total)
        }

        guard let fraction else { return false }
        return fraction >= uniformFraction
    }
}
