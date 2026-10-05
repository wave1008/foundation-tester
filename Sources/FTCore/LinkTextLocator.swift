import CoreGraphics
import Foundation

/// `tap(sel, linkText:)`: 要素の**中の一部の文字列**(文中リンク)の位置を決める。
/// 決め方は 木 → OCR の順で、どちらでも見つからなければ呼び手が失敗にする(要素の中心へ黙って落とさない)。
/// OCR の読み取りは `RegionText.locateLink`(2つ目の OCR 実装を作らない)。
public enum LinkTextLocator {
    public enum Source: String, Sendable { case tree, ocr }

    /// OCR の撮影の回数(初回を含む)。**1文字も読めない絵 = 画面の切り替えの途中の撮影**(遅い Emulator で
    /// 文字が描かれる前の白い絵を撮り「OCR read no text」で落ちた。E2EY-CMP の Android・M1Ultra。
    /// 同じ画面の失敗時の絵では読めた)を、切り替えの所要(数百 ms)を越えて撮り直す
    public static let ocrShotAttempts = 3
    /// 撮り直しの間隔(3 回で約 1 秒 = 画面の切り替えのアニメーションより長い)
    public static let ocrReshotInterval: Duration = .milliseconds(500)
    /// 1回の OCR の予算。定常は 1 段 100〜300ms・段は最大 3 で 1 秒未満(コンパイルは先に `awaitModelCompile` で
    /// 済ませる)。これを超えるのは読みが固まった形(E2EY-Android で 120 秒のステップの時間切れまで返らなかった)。
    /// 尽きたら理由を言って失敗する(固まった読みは止めずに放す = `TaskBudget`)
    public static let ocrBudget: Duration = .seconds(10)

    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let source: Source
    }

    /// 木: 要素の子孫のうち label / value が `linkText` に一致する最初のもの(ツリー順)の中心。
    /// Flutter・RN・UITextView のリンクは子ノードとして出るのでこれで済む。
    /// 枠が潰れている(幅か高さが 0 以下)子孫は位置の根拠にならないので飛ばす
    public static func treePoint(linkText: String, element: ElementInfo, in elements: [ElementInfo]) -> Point? {
        let needle = TextNormalization.text.apply(linkText)
        guard !needle.isEmpty else { return nil }
        for child in LocatorResolver.descendants(of: element, in: elements)
        where child.frame.width > 0 && child.frame.height > 0 {
            let matches = [child.label, child.value].contains { $0.map { TextNormalization.text.apply($0) == needle } ?? false }
            if matches { return Point(x: child.frame.centerX, y: child.frame.centerY, source: .tree) }
        }
        return nil
    }

    /// `text` の中で `linkText` が最初に現れる範囲。OCR の候補文字列の添字を返すので、**正規化した文字列では
    /// なく原文で探す**(`boundingBox(for:)` は候補の添字を要る)。大小・全半角の違いは吸う
    public static func range(of linkText: String, in text: String) -> Range<String.Index>? {
        guard !linkText.isEmpty else { return nil }
        return text.range(of: linkText, options: [.caseInsensitive, .widthInsensitive])
    }

    /// クロップ内の正規化矩形(Vision の座標系 = 原点は左下・0...1)の中心を画面座標へ写す純粋関数。
    /// - `crop`: 元スクリーンショット内のクロップ矩形(px・`OcclusionCrop.rect` の戻り値)
    /// - 拡大(`upscale`)は縦横同率なので正規化座標には効かない(引数に取らない)
    /// - 画面座標は snapshot の screen と同じ系(iOS = pt / Android = px)。
    ///   換算は `OcclusionCrop.rect` と同じ(`imageWidth / screen.width`)
    public static func screenPoint(normalizedBox box: CGRect, crop: CGRect,
                                   imageWidth: Int, imageHeight: Int, screen: FTRect) -> (x: Double, y: Double)? {
        guard imageWidth > 0, imageHeight > 0, crop.width > 0, crop.height > 0 else { return nil }
        let scaleX = Double(imageWidth) / (screen.width == 0 ? Double(imageWidth) : screen.width)
        let scaleY = Double(imageHeight) / (screen.height == 0 ? Double(imageHeight) : screen.height)
        let pxX = Double(crop.minX) + Double(box.midX) * Double(crop.width)
        let pxY = Double(crop.minY) + (1 - Double(box.midY)) * Double(crop.height)
        return (pxX / scaleX, pxY / scaleY)
    }
}
