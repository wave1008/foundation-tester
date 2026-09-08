// occlusion-guard Tier-2(FM の手前)。期待テキストを Vision OCR で読めるかだけを見る安価な
// 事前判定。FM が反転した crop コーパス 167 枚に対し OCR は 167/167 で同じ結論(読めない)に
// 到達し、所要は FM の 40〜80倍速い(crop で p50 33ms / p90 68ms)。**OcclusionCrop.rect で
// FM と同一の矩形**を切り出すので、両者が食い違わない。
//
// 既定は on: FM の段に届いた実 run の crop 163 枚のうち **97% が OCR で片付き**、残りは FM に回るので
// 誤った赤は増えない(docs/poc-fm-occlusion-guard.md §5.17)。**OCR 単独で判定はしない** ——
// 等倍では 29% が可視なテキストの1文字誤読(`swipe=down`→`swipe=aown`)で、それを反転の根拠に
// すると誤った赤になる。読めなかった回の判定は必ず FM が行う。

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Vision

public enum RegionTextGateMode: String, Sendable {
    case off, on, measure
}

public enum RegionText {
    public struct Reading: Sendable {
        public let lines: [String]
        public let elapsedMs: Double
        /// 何段まで拡大して読んだか(1 = 等倍だけ)
        public var attempts: Int = 1
    }

    /// `FT_OCCLUSION_OCR`: "0"/"off" → 殺しスイッチ(OCR を呼ばず従来どおり FM だけ)/
    /// "measure" → 訊くが必ず FM にも回しコーパスを書く(採取用)/ 未設定・その他 → on(既定)
    public static func mode(environment: [String: String]) -> RegionTextGateMode {
        switch environment["FT_OCCLUSION_OCR"] {
        case "0", "off": return .off
        case "measure": return .measure
        default: return .on
        }
    }

    /// Vision のモデルが載っていないと**プロセスで最初の 1 回だけ 25〜47 秒**かかる(2 回目以降は
    /// 40〜130ms)。ガードが撃たれる前に背景で載せておく。モデルの読み込みはプロセスに1回だけ
    /// 走る(prewarmOnce)。off のときは撃たない(ゲートを切った run に Vision を読ませない)。
    public static func prewarmIfNeeded(mode: RegionTextGateMode) {
        guard mode != .off else { return }
        prewarmLock.lock()
        prewarmRequests += 1
        prewarmLock.unlock()
        _ = prewarmOnce
    }

    /// 配線の確認用(テスト)。実際のモデル読み込み回数ではなく「暖機を頼んだ回数」
    public static var prewarmRequestCount: Int {
        prewarmLock.lock()
        defer { prewarmLock.unlock() }
        return prewarmRequests
    }

    private static let prewarmLock = NSLock()
    private static var prewarmRequests = 0

    private static let prewarmOnce: Void = {
        Task.detached(priority: .utility) {
            // 空の画像では認識器が言語モデルまで読み込まないことがあるので、文字を描いて読ませる
            guard let image = renderedProbe() else { return }
            _ = try? await recognize(image, languages: defaultLanguages)
        }
    }()

    /// 拡大後に許す画素数の上限。**根拠**: コーパスの crop は最大でも約 0.19 MP で、
    /// 画面いっぱいの要素でも 3x 端末で約 3.2 MP。これを超える crop は文字がすでに十分大きく、
    /// 拡大しても読めるようにはならない一方で、確保するビットマップだけが数十 MB になる
    static let maxUpscaledPixels = 4_000_000

    /// crop を整数倍に拡大する(補間は high)。倍率 1 と、上限を超える大きさなら元の画像を返す
    static func enlarged(_ image: CGImage, by factor: Int) -> CGImage {
        guard factor > 1, image.width * image.height * factor * factor <= maxUpscaledPixels
        else { return image }
        let width = image.width * factor, height = image.height * factor
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// 暖機用の小さな画像(白地に黒の1語)。AppKit を使わない(WindowServer に依存させない)
    private static func renderedProbe() -> CGImage? {
        let width = 120, height = 40
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        // 属性キーは CoreText のもの(AppKit/UIKit の .font は FTCore からは見えない)
        let attributed = NSAttributedString(string: "fleetest", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 6, y: 10)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    /// 拡大の段。**読めるまで順に上げ、読めた時点で止める**(実測 163 枚: ×1 で 71% → ×2 まで
    /// 88% → ×3 まで 97%。**×4 は 74% に落ちる**ので上げない。所要は p50 40ms、読めずに FM へ
    /// 回る回で p50 222ms)。拡大は画素を増やすだけで文字を作らないので、読めない crop
    /// (覆い・空白・画面外)は段を上げても読めないまま FM に回る(実測で確認済み)。
    public static let upscaleLadder = [1, 2, 3]

    /// 段を上げながら読み、`expected` が丸ごと読めたらそこで止める。
    /// nil = 画像不正 / crop が作れない(退化 frame・画面外)/ OCR が失敗。
    public static func resolve(expected: String, pngData: Data, frame: FTRect, screen: FTRect,
                               cropPadding: CGFloat = 24,
                               languages: [String]? = nil) async -> (readable: Bool, reading: Reading)? {
        let languages = languages ?? self.languages(for: expected)
        var last: Reading?
        for (index, step) in upscaleLadder.enumerated() {
            guard let reading = await read(pngData: pngData, frame: frame, screen: screen,
                                           cropPadding: cropPadding, languages: languages, upscale: step)
            else { return last.map { (false, $0) } }
            let accumulated = Reading(lines: reading.lines,
                                      elapsedMs: (last?.elapsedMs ?? 0) + reading.elapsedMs,
                                      attempts: index + 1)
            if readable(expected: expected, lines: reading.lines) { return (true, accumulated) }
            // **1行も読めない crop は段を上げない** —— 拡大は画素を増やすだけで文字を作らないので、
            // 覆い・空白・画面外はどこまで上げても読めない(実測: ×1 で無読の 3 枚は ×2/×3 でも 0 枚が
            // 読めた)。ここで止めるのが効くのは、覆いが消えるのを待つ poll 周回 —— 毎周 3 回撃つと
            // 待ちの間じゅう払い続けることになる
            if reading.lines.isEmpty { return (false, accumulated) }
            last = accumulated
        }
        return last.map { (false, $0) }
    }

    /// frame(pt)領域を OcclusionCrop.rect で切り出して Vision で読む。
    /// nil = 画像不正 / crop が作れない(退化 frame・画面外)/ OCR が失敗。
    /// `lines` は各 observation の topCandidates(1) を Vision が返した順に並べたもの。
    ///
    /// **`recognize` を実際に撃った回だけ `OCRUsageLedger` へ記録する**(crop が作れず到達しなかった
    /// 回は数えない。暖機(prewarmOnce)は `read` を経由しないのでここには入らない = 数えない)。
    public static func read(pngData: Data, frame: FTRect, screen: FTRect,
                            cropPadding: CGFloat = 24,
                            languages: [String] = defaultLanguages,
                            upscale: Int = 1) async -> Reading? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard let rect = OcclusionCrop.rect(frame: frame, screen: screen,
                                            imageWidth: full.width, imageHeight: full.height,
                                            cropPadding: cropPadding),
              let cropped = full.cropping(to: rect) else { return nil }
        let crop = enlarged(cropped, by: upscale)
        let start = Date()
        let lines: [String]
        do {
            lines = try await recognize(crop, languages: languages)
        } catch {
            OCRUsageLedger.record(ok: false, ms: Date().timeIntervalSince(start) * 1000)
            return nil
        }
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        OCRUsageLedger.record(ok: true, ms: elapsedMs)
        return Reading(lines: lines, elapsedMs: elapsedMs)
    }

    public static let defaultLanguages = ["ja-JP", "en-US"]

    /// 読ませる言語は**期待文字列から決める**。日本語モデルを載せると 1 回あたり p50 91→208ms
    /// になるので、期待文字列が ASCII だけのときは英語だけにする(実測: ASCII の期待値では
    /// 読み取り結果が両者で完全に一致する)。非 ASCII(かな・漢字など)を含むときだけ日本語を足す。
    public static func languages(for expected: String) -> [String] {
        expected.allSatisfy { $0.isASCII } ? ["en-US"] : defaultLanguages
    }

    /// 版(revision)は指定しない —— **OS が既定に選んだものを使う**。固定すると新しい OS で
    /// 改善された認識器を使えなくなる。版が動いたときの検出は実 crop の固定コーパス
    /// (`Tests/Fixtures/OcclusionCrops/`・段ごとの読み取りを等号で固定)が担う。
    private static func recognize(_ image: CGImage, languages: [String]) async throws -> [String] {
        var request = RecognizeTextRequest()
        // 実測 p50 33ms なので速度のために fast へ落とさない(欠けを取りこぼすほうが高くつく)。
        request.recognitionLevel = .accurate
        // 欠けを推測で埋めさせない(言語補正は「読めた」の意味を弱める)。
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        return try await request.perform(on: image).compactMap { $0.topCandidates(1).first?.string }
    }

    /// 正規化した期待文字列が空なら false。行を返ってきた順に連結した文字列、または各行単体の
    /// いずれかが、正規化した期待文字列を丸ごと含むときだけ true。**先頭一致は採らない**
    /// (部分的に覆われて残りだけ読めた回を「見えている」と通すと、guard の目的である
    /// 誤った緑を作るため)。confidence は判定に使わない(Vision の confidence は 0.3/0.5/1.0 に
    /// 飛び飛びで根拠のある閾値を置けない。読めた文字列そのもので判定する)。
    /// **期待文字列が ASCII のときは語境界を要求する** —— 素の部分一致だと `exist("OK")` が
    /// 覆いの「Cookieの設定」に当たって素通りする(短い期待値ほど当たりやすい)。
    /// 日本語には語境界が無いので CJK を含む期待値は素の含有のまま。
    /// **残る取りこぼし**: 折り返しを繋いだ文字列がたまたま期待値を作る形(`["row_4", "0 件"]`)。
    /// 折り返しの連結は正当な用途なので消さない —— 誤る向きは見逃し(誤った緑)だけ。
    public static func readable(expected: String, lines: [String]) -> Bool {
        let needle = normalize(expected)
        guard !needle.isEmpty else { return false }
        if contains(normalize(lines.joined()), needle) { return true }
        return lines.contains { contains(normalize($0), needle) }
    }

    /// `needle` が ASCII だけなら**前後が英数でない位置**でのみ一致と見なす(語境界)。
    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        guard needle.allSatisfy({ $0.isASCII }) else { return haystack.contains(needle) }
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeIsWord = found.lowerBound > haystack.startIndex
                && isWordCharacter(haystack[haystack.index(before: found.lowerBound)])
            let afterIsWord = found.upperBound < haystack.endIndex
                && isWordCharacter(haystack[found.upperBound])
            if !beforeIsWord && !afterIsWord { return true }
            guard found.lowerBound < haystack.endIndex else { break }
            searchStart = haystack.index(after: found.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// NFKC 互換合成 → 空白(半角・全角・改行・タブ)除去 → 小文字化 → 末尾の省略記号
    /// (`…` / `...`)除去。
    public static func normalize(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
        if t.hasSuffix("...") {
            t.removeLast(3)
        } else if t.hasSuffix("…") {
            t.removeLast()
        }
        return t
    }
}
