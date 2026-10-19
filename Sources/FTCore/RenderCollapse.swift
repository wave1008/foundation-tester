// RenderCollapse.swift
// **描画崩壊**(木は中身を持つのに、絵に何も描かれていない・文字だけが1つも描かれていない)の判定(純粋関数)。
// 呼び手は StepExecutor.renderCollapseVerdict(Simulator の iOS だけ・文字の検証が届かなかった区間の終わりに1回)。
// 実測(Simulator の Compose / Flutter): アプリのプロセスの描画が壊れると、アプリの領域が一色になる形と、
// 形(ボタン・枠)は描けて文字だけが消える形(Compose だけ)がある。どちらも木は正常に中身を返すので、木だけを見る
// 検証(keyboardIsShown・checkIsON・exist(#id) 等)は緑のまま通る。テキストの可視性検証が届く検証は既に赤にできている。
// **原因は判定しない**(Metal のエラーの有無は描画の壊れと対応しなかった = 正常なプロセスも出す)。
//
// - 一色: アプリの領域(上 = ステータスバーの帯・下 = 下端の帯とキーボードを除く)の格子のセル平均が全部同じ色で、
//   木がその領域に文字の要素を1つ以上報告している
// - 文字が無い: 文字の要素(静的な文字の型だけ = 入力欄は枠線が描けていると文字が無くても構造が出る)を全部切り出し、
//   どれにも構造が無い(`RegionInk` の輝度の標準偏差が閾値未満)。対象が `minimumTextElements` 件以上のときだけ
//   (少ないと、ラベルだけの単色の箱で偶然そろう)

import CoreGraphics
import Foundation
import ImageIO

public enum RenderCollapse {
    public enum Finding: Equatable, Sendable {
        /// アプリの領域が一色。値は木がその領域に報告した文字の要素の数
        case blankAppArea(textElements: Int)
        /// 文字の要素が1つも描かれていない。値は確かめた要素の数
        case noTextDrawn(textElements: Int)
    }

    /// 文字だけを描く型(入力欄・ボタンは枠や背景の構造が残るので数えない)。小文字で比べる
    static let textTypes: Set<String> = ["statictext", "text", "label"]

    /// 上端・下端で除く帯の最小の高さ(画面の高さに対する割合)。`BlankFrameDetector` の 32 分割の 2 行 = 約 6%
    /// (ステータスバー・ホームインジケータが収まる高さ。同じ根拠)
    static let systemBandFraction = Double(BlankFrameDetector.blackFrameIgnoredTopRows)
        / Double(BlankFrameDetector.blackFrameGrid)

    /// 一色を見る格子の目の数(領域の縦横それぞれ)と、一色とみなすセル平均の差の上限(各チャンネル)。
    /// 値は `BlankFrameDetector` の一色の判定と同じ(32 分割・12 段階)
    static let grid = BlankFrameDetector.blackFrameGrid
    static let flatTolerance = Int(BlankFrameDetector.flatCellTolerance)

    /// 判定する。`keyboard` は申告されたキーボードの枠(画面の外なら無いものとして扱う)。
    /// `inkThreshold` はテキストの可視性検証の `occlusionInkThreshold` を渡す(同じ「描かれている」の定義を共有する)
    public static func judge(pngData: Data, elements: [ElementInfo], screen: FTRect, keyboard: FTRect?,
                             inkThreshold: Double, minimumTextElements: Int) -> Finding? {
        guard matchesOrientation(pngData: pngData, screen: screen),
              let area = appArea(elements: elements, screen: screen, keyboard: keyboard) else { return nil }
        let texts = textElements(in: elements, screen: screen, appArea: area)
        guard !texts.isEmpty else { return nil }
        if isUniform(pngData: pngData, region: area, screen: screen) == true {
            return .blankAppArea(textElements: texts.count)
        }
        guard texts.count >= minimumTextElements, inkThreshold > 0 else { return nil }
        let inks = texts.compactMap { RegionInk.luminanceStdDev(pngData: pngData, frame: $0.frame, screen: screen) }
        guard inks.count >= minimumTextElements, inks.allSatisfy({ $0 < inkThreshold }) else { return nil }
        return .noTextDrawn(textElements: inks.count)
    }

    /// アプリの領域。上はいちばん上の要素の上端(ステータスバーより下 = `StepExecutor.blankAppAreaFact` と同じ導き方)と
    /// 帯の最小の高さの大きいほう、下は下端の帯とキーボードの上端の小さいほう
    public static func appArea(elements: [ElementInfo], screen: FTRect, keyboard: FTRect?) -> FTRect? {
        let band = screen.height * systemBandFraction
        let contentTop = elements.map(\.frame.y).filter { $0 > screen.y }.min() ?? screen.y
        let top = max(contentTop, screen.y + band)
        var bottom = screen.y + screen.height - band
        if let keyboard, KeyboardWait.onScreen(keyboard, screen: screen) { bottom = min(bottom, keyboard.y) }
        guard bottom - top >= 1, screen.width >= 1 else { return nil }
        return FTRect(x: screen.x, y: top, width: screen.width, height: bottom - top)
    }

    /// 確かめる文字の要素: 文字の型で、ラベルが描かれる文字を持ち(`OcclusionEligibility`)、アプリの領域の中に収まり、
    /// 木の上で覆われ・はみ出していない(`OcclusionSuspicion.geometric`)、WebView の外の要素
    public static func textElements(in elements: [ElementInfo], screen: FTRect, appArea: FTRect) -> [ElementInfo] {
        elements.filter { element in
            guard textTypes.contains(element.type.lowercased()),
                  let label = element.label, !label.isEmpty,
                  OcclusionEligibility.eligible(type: element.type, label: label, value: element.value,
                                                placeholder: element.placeholder, web: element.web).ok,
                  element.frame.width >= 1, element.frame.height >= 1,
                  contains(appArea, element.frame),
                  BlankFrameDetector.enclosingWebViewFrame(of: element, in: elements) == nil,
                  !OcclusionSuspicion.geometric(element: element, in: elements, screen: screen, looseMatch: false)
            else { return false }
            return true
        }
    }

    /// 絵と木の縦横が同じ向きか(縦横比の差が `orientationTolerance` 以内)。違えば判定しない —— 横向きの画面で
    /// 絵だけ縦のまま来た回は、要素の枠が絵の別の場所を指し、描かれている文字を「無い」と読んだ(失敗レポートの全数当てで実測)
    static func matchesOrientation(pngData: Data, screen: FTRect) -> Bool {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double,
              w > 0, h > 0, screen.width > 0, screen.height > 0 else { return false }
        return abs(w / h - screen.width / screen.height) <= orientationTolerance * (screen.width / screen.height)
    }

    /// 縦横比の許す差(割合)。絵は画面の pt に倍率を掛けた px なので本来一致する。端数の丸めだけを許す
    static let orientationTolerance = 0.02

    /// 文字だけが消える形を言うのに要る文字の要素の数。**根拠**: 失敗レポートの iOS の画面写真 2,453 枚への全数当て
    /// で、崩壊と目で確かめた画面の最小が 2 件、崩壊でない画面で全部そろった最大が 2 件(木と絵が別の瞬間の
    /// 取り違え)。その間に置く。**尽きたときの発話**: これ未満の画面は一色の判定だけで見る(文字だけ消えた形は見逃す)
    public static let minimumTextElements = 3

    /// 領域の格子のセル平均が全部同じ色か。読めなければ nil
    static func isUniform(pngData: Data, region: FTRect, screen: FTRect) -> Bool? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), screen.width > 0, screen.height > 0
        else { return nil }
        let sx = Double(image.width) / screen.width
        let sy = Double(image.height) / screen.height
        let rect = CGRect(x: (region.x - screen.x) * sx, y: (region.y - screen.y) * sy,
                          width: region.width * sx, height: region.height * sy)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect),
              let context = CGContext(data: nil, width: grid, height: grid, bitsPerComponent: 8, bytesPerRow: grid * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: grid, height: grid))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: grid * grid * 4)
        for cell in 0..<(grid * grid) {
            for channel in 0..<3 where abs(Int(pixels[cell * 4 + channel]) - Int(pixels[channel])) > flatTolerance {
                return false
            }
        }
        return true
    }

    private static func contains(_ outer: FTRect, _ inner: FTRect) -> Bool {
        inner.x >= outer.x - 0.5 && inner.y >= outer.y - 0.5
            && inner.x + inner.width <= outer.x + outer.width + 0.5
            && inner.y + inner.height <= outer.y + outer.height + 0.5
    }
}
