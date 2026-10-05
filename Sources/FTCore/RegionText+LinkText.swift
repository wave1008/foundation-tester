import CoreGraphics
import Foundation
import ImageIO
import Vision

extension RegionText {
    public struct LinkLocation: Sendable {
        /// 見つかった位置(画面座標)。nil = どの段でも見つからなかった
        public let point: (x: Double, y: Double)?
        /// 読めた行(失敗文言に添える)。最後に読んだ段のもの
        public let lines: [String]
        public let attempts: Int
    }

    /// `frame`(画面座標)を切り出して OCR で読み、`linkText` が描かれている位置を返す。
    /// 拡大段(`upscaleLadder`)は `resolve` と同じ規則: 読めるまで上げ、**1行も読めなければ止める**。
    /// nil = 画像不正 / crop が作れない / OCR が失敗
    public static func locateLink(linkText: String, pngData: Data, frame: FTRect, screen: FTRect,
                                  cropPadding: CGFloat = 0) async -> LinkLocation? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let rect = OcclusionCrop.rect(frame: frame, screen: screen,
                                            imageWidth: full.width, imageHeight: full.height,
                                            cropPadding: cropPadding),
              let cropped = full.cropping(to: rect) else { return nil }
        let languages = languages(for: linkText)
        var lastLines: [String] = []
        var attempts = 0
        for step in upscaleLadder {
            attempts += 1
            let crop = enlarged(cropped, by: step)
            let start = Date()
            let observations: [RecognizedTextObservation]
            do {
                observations = try await recognizeObservations(crop, languages: languages)
            } catch {
                VisionUsageLedger.record(ok: false, ms: Date().timeIntervalSince(start) * 1000)
                return nil
            }
            VisionUsageLedger.record(ok: true, ms: Date().timeIntervalSince(start) * 1000)
            var lines: [String] = []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                lines.append(candidate.string)
                guard let range = LinkTextLocator.range(of: linkText, in: candidate.string),
                      let box = candidate.boundingBox(for: range),
                      let point = LinkTextLocator.screenPoint(
                        normalizedBox: box.boundingBox.cgRect, crop: rect,
                        imageWidth: full.width, imageHeight: full.height, screen: screen)
                else { continue }
                return LinkLocation(point: point, lines: lines, attempts: attempts)
            }
            lastLines = lines
            if lines.isEmpty { break }
        }
        return LinkLocation(point: nil, lines: lastLines, attempts: attempts)
    }
}
