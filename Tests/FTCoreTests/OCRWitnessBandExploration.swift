// [探索用・恒久化前] OCR 段(Tier-2)に届く witness の成立条件を、デバイス無しで測る。
//
// occlusion-guard は段で絞る: Tier-1 のインク足切り(`StepExecutor.occlusionInkThreshold` 既定 12)を
// 通った crop だけが Tier-2(OCR)へ行く。SUT に witness を置くには**両立する帯**が要る:
//   ① 要素矩形の輝度 stdDev < 12   (足切りを通って Tier-2 へ届く)
//   ② OCR が期待文字列を丸ごと読む (FM を呼ばずに素通り = OCR ON/OFF で差が出る)
// ①は「インクが薄い」ほど有利、②は「文字がはっきり大きい」ほど有利で**互いに逆を向く**。
// 帯が存在しなければ SUT をどう作っても witness にならないので、SUT を書く前にここで確かめる。
//
// 注意: 足切り(`RegionInk.luminanceStdDev`)は**要素矩形そのもの**を見るが、OCR/FM の crop は
// `OcclusionCrop.rect` が余白を足した矩形を見る(小要素では余白を要素サイズの 1/3 で頭打ち)。
// 同じ画素を見ていないので、片方だけで見積もると外す。

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import FTCore

final class OCRWitnessBandExploration: XCTestCase {

    /// Tier-1 の既定。**production の定数を参照しない**(変異が素通しするため実測の意味が消える)
    private static let inkThreshold = 12.0

    /// iPhone 17 Pro 相当。pt と px の比が 1 でない状態で測る(換算の取り違えを紛れ込ませない)
    private static let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    private static let scale = 3

    private struct Case {
        let label: String
        let frame: FTRect      // pt
        let fontSize: CGFloat  // pt
        let gray: CGFloat      // 0=黒 255=白
    }

    /// 白地に文字を1行描いた擬似スクショを作る
    private static func render(_ c: Case, text: String) -> Data? {
        let w = Int(screen.width) * scale, h = Int(screen.height) * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let g = c.gray / 255.0
        let font = CTFontCreateWithName("Helvetica" as CFString, c.fontSize * CGFloat(scale), nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: g, green: g, blue: g, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        // 要素矩形の中央へ置く。CGContext は左下原点なので y を反転して合わせる
        let fx = CGFloat(c.frame.x) * CGFloat(scale)
        let fy = CGFloat(c.frame.y) * CGFloat(scale)
        let fw = CGFloat(c.frame.width) * CGFloat(scale)
        let fh = CGFloat(c.frame.height) * CGFloat(scale)
        ctx.textPosition = CGPoint(x: fx + (fw - bounds.width) / 2,
                                   y: CGFloat(h) - (fy + fh / 2) - bounds.height / 4)
        CTLineDraw(line, ctx)

        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }

    /// 帯を掃いて表をファイルへ書く。**判定はしない**(合否を決めるのは人間。ここは観測)。
    /// 通常のスイートでは走らせない —— assert を持たないので「破っても落ちない」= テストとして
    /// 無意味な一方、Vision の初回ロード(25〜47 秒)を毎回払う。`FT_OCR_BAND_SWEEP=<出力先>` で起こす
    /// (`Tests/Fixtures/RealAppSnapshots` の採り直しが `FT_SWEEP_BASELINE=1` なのと同じ流儀)。
    /// **`print` を使わない** —— `--parallel` はテストプロセスを分けるので出力が混ざり帰属が消える
    func testSweepTheBand() async throws {
        guard let outPath = ProcessInfo.processInfo.environment["FT_OCR_BAND_SWEEP"], !outPath.isEmpty
        else { throw XCTSkip("FT_OCR_BAND_SWEEP=<出力先パス> を渡したときだけ走る探索") }
        var report: [String] = []
        let expected = "ocr=readable"
        var cases: [Case] = []
        // ①「大きな枠に小さい文字」= 黒のままインクの占有率を下げる路線
        for side in [120.0, 200.0, 320.0] {
            cases.append(Case(label: "枠\(Int(side))pt/17pt/黒",
                              frame: FTRect(x: 24, y: 300, width: side, height: side),
                              fontSize: 17, gray: 0))
        }
        // ②「薄い文字」= 占有率はそのままコントラストを下げる路線
        for gray in [160.0, 200.0, 220.0, 235.0] {
            cases.append(Case(label: "枠160x44/17pt/gray\(Int(gray))",
                              frame: FTRect(x: 24, y: 300, width: 160, height: 44),
                              fontSize: 17, gray: gray))
        }
        // ③ 両方を少しずつ
        for (side, gray) in [(120.0, 160.0), (160.0, 190.0), (200.0, 140.0)] {
            cases.append(Case(label: "枠\(Int(side))pt/17pt/gray\(Int(gray))",
                              frame: FTRect(x: 24, y: 300, width: side, height: side),
                              fontSize: 17, gray: gray))
        }

        report.append("# OCR witness 帯の探索(期待文字列: \(expected) / 足切り \(Self.inkThreshold))")
        report.append("条件\tstdDev\tTier2へ届く\t読めた\tOCRが読んだ行")
        var candidates = 0
        for c in cases {
            guard let png = Self.render(c, text: expected) else {
                report.append("\(c.label)\t描画に失敗"); continue
            }
            let sd = RegionInk.luminanceStdDev(pngData: png, frame: c.frame, screen: Self.screen)
            let reachesTier2 = (sd ?? 999) < Self.inkThreshold
            let r = await RegionText.resolve(expected: expected, pngData: png,
                                             frame: c.frame, screen: Self.screen)
            let readable = r?.readable ?? false
            if reachesTier2 && readable { candidates += 1 }
            report.append([c.label, String(format: "%.2f", sd ?? -1),
                           reachesTier2 ? "○" : "×", readable ? "○" : "×",
                           (r?.reading.lines ?? []).joined(separator: " | ")].joined(separator: "\t"))
        }
        report.append("# 両方 ○ = witness の候補: \(candidates) 件(0 なら帯が存在しない)")
        try report.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}
