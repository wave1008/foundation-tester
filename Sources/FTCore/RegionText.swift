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
        /// 最後に読ませた画像の画素数(拡大後)。**遅かった回の説明に要る** —— 所要は画素数で決まる
        public var pixels: Int = 0
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
        // **.utility にしない**: この暖機は「近道を撃ってよいか」(shouldTakeShortcut)の門を
        // 開ける側なので、8 レーンで飽和した協調スレッドプールで後回しにされると、その間ずっと
        // 近道が撃たれず全ステップが FM(p50 3.3 秒)へ落ちる
        Task.detached(priority: .userInitiated) {
            // 空の画像では認識器が言語モデルまで読み込まないことがあるので、文字を描いて読ませる
            guard let image = renderedProbe() else { return }
            let read = try? await recognize(image, languages: defaultLanguages)
            guard warmedUp(probe: read) else { return }
            warmLock.lock(); warm = true; warmLock.unlock()
        }
    }()

    private static let warmLock = NSLock()
    private static var warm = false

    /// Vision のモデルが載って**実際に読めた**か。載っていない間に近道(OCR)を撃つと、
    /// ステップごとに予算(`occlusionBudget`)を丸ごと捨てることになる
    public static var isWarm: Bool {
        if let forced = warmOverrideForTesting { return forced }
        warmLock.lock(); defer { warmLock.unlock() }; return warm
    }

    /// テストから既知の状態にするための差し替え口(production では nil のまま)。
    /// **既定が nil であること自体は `RegionTextWarmDefaultTests` が固定する** ——
    /// 差し替えだけになると「暖機を一度も通らない」変更が緑で通る
    public static var warmOverrideForTesting: Bool?

    /// 暖機の探りの結果から「モデルが載った」と言ってよいか。
    /// **文字を描いた探りが実際に読めたときだけ** —— 呼び出しが成功しても 1 行も返らない状態が
    /// 実在する(2026-09-10: この Mac で Vision が終日 `[]` を返していた)。そこで近道を撃つと
    /// 毎ステップ予算(occlusionBudget)を捨てるだけで、判定は結局 FM が下す。
    /// 探りは `renderedProbe()` = 必ず文字がある画像なので、空 = 読めていない
    public static func warmedUp(probe: [String]?) -> Bool { !(probe ?? []).isEmpty }

    /// OCR の近道を撃ってよいか。純粋関数(呼び出し側の配線は1箇所)。
    /// - **モデルが載るまでは撃たない** —— 載っていない間に撃っても予算を捨てるだけで、判定は
    ///   結局 FM が下す
    /// - **諦めた読みが走っている間は撃たない** —— 実測(2026-09-10 SNB-M1 ジェスチャ S0010):
    ///   最初の実 crop の読みが詰まっている間、ステップごとに新しい読みを積み増して 12 本が
    ///   全部予算切れになり、捌けた瞬間に協調スレッドプールが 6.4 秒止まった。1 本詰まったら
    ///   それが戻るまで FM に任せるほうが、予算を 12 回捨てるより安い
    public static func shouldTakeShortcut(mode: RegionTextGateMode, warm: Bool,
                                          abandonedInFlight: Int) -> Bool {
        mode != .off && warm && abandonedInFlight == 0
    }

    private static let inFlightLock = NSLock()
    private static var abandoned = 0

    /// 予算切れで諦めたが、まだ走っている読みの本数(shouldTakeShortcut の doc)
    public static var abandonedInFlight: Int {
        inFlightLock.lock(); defer { inFlightLock.unlock() }; return abandoned
    }

    private static func noteAbandoned(_ delta: Int) {
        inFlightLock.lock(); abandoned = max(0, abandoned + delta); inFlightLock.unlock()
    }

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
                                      attempts: index + 1, pixels: reading.pixels)
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

    /// **近道が本道より遅くなったら本道へ落ちる**ための予算つき入口。
    ///
    /// OCR 段は FM の照合(実測 1.3〜2.8 秒)を省くためだけの近道なので、それより高くつくなら
    /// 存在意義が無い。**予算は置き換える相手の下限 1.3 秒** —— 調整値ではなく「近道であること」の
    /// 定義。尽きたら `.budgetExhausted` を返し、呼び手は従来の「読めなかった」と同じく FM へ落とす
    /// (判定は変えない。読めなかったことを反転の根拠にしない契約は resolve の doc と同じ)。
    ///
    /// **走っている OCR は止めない** —— Vision のモデルの初回ロードは**プロセスに1回**なので、
    /// ここで止めると次のステップもまた予算を使い切る。放っておけばそのまま暖機として効き、
    /// 2 回目以降は 40〜130ms で返る(実測 2026-09-10: 予算を入れる前は最初にガードへ入った
    /// 1ステップだけが 36〜108 秒を払い、以降は 100〜300ms だった)
    public enum BudgetedReading: Sendable {
        case read(readable: Bool, reading: Reading)
        case unreadable
        case budgetExhausted
    }

    /// FM の照合の実測下限。**この時間を超えたら OCR は近道ではない**(単位: 実時間)。
    /// **`FT_OCR_BUDGET_MS` は保守者の計測用の口** —— 予算を広げて「近道が本当は何ミリ秒
    /// 要るのか」を実負荷で採るために使う(利用者向けのノブではない)
    public static var occlusionBudget: Duration {
        let ms = Int(ProcessInfo.processInfo.environment["FT_OCR_BUDGET_MS"] ?? "") ?? 1300
        return .milliseconds(ms)
    }

    /// **保守者向けの採取口**(`FT_OCR_HANG_SAMPLE=1` のときだけ): 諦めた読みが
    /// `hangSampleAfterSeconds` たっても戻らなければ、自分自身を `/usr/bin/sample` で採って
    /// `~/.fleetest/ocr-hang/<pid>-<時刻>.txt` に落とす。**再現が本番負荷でしか起きない**
    /// (単体・8 並列・シミュレータ稼働中の別プロセスでは全て 100〜160ms)ので、詰まっている
    /// 瞬間のスタックはプロセス自身に採らせるしかない。XPC 待ちなら Vision デーモン側、
    /// ロック待ちなら自プロセス側、と切り分けられる。既定 OFF・利用者には見せない
    public static func hangSamplingEnabled(environment: [String: String]) -> Bool {
        environment["FT_OCR_HANG_SAMPLE"] == "1"
    }
    /// 予算切れの後にさらに待ってから採る長さ。単体の実測は最大 160ms なので、その 20 倍
    /// = 3 秒たってもまだ走っている読みは「遅い」ではなく異常で、**戻る前に**スタックを採れる
    /// (実測 2026-09-10: 諦めた読みは 10 秒以内には戻る = 10 秒待つと採れない)。調整値ではない
    static let hangSampleAfterSeconds: Double = 3

    /// 諦めた読みが戻ったかの旗(late finish が立てる)。採取は戻っていないときだけ
    final class HangWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var returned = false
        func markReturned() { lock.lock(); returned = true; lock.unlock() }
        var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
    }

    static func recordLateFinish(ms: Int, attempts: Int, pixels: Int, readable: Bool, expected: String) {
        guard hangSamplingEnabled(environment: ProcessInfo.processInfo.environment) else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest/ocr-late", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let entry: [String: Any] = ["pid": pid, "ms": ms, "attempts": attempts, "pixels": pixels,
                                    "readable": readable, "expected": expected, "at": stamp]
        if let data = try? JSONSerialization.data(withJSONObject: entry) {
            try? data.write(to: dir.appendingPathComponent("\(pid)-\(stamp).json"))
        }
    }

    static func sampleSelfIfStillHung(_ watch: HangWatch, expected: String) {
        guard hangSamplingEnabled(environment: ProcessInfo.processInfo.environment) else { return }
        // 協調スレッドを塞がないよう専用スレッドで待って採る(sample(1) は 3 秒ブロックする)
        let t = Thread {
            Thread.sleep(forTimeInterval: hangSampleAfterSeconds)
            guard !watch.hasReturned else { return }
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".fleetest/ocr-hang", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let pid = ProcessInfo.processInfo.processIdentifier
            let file = dir.appendingPathComponent("\(pid)-\(stamp).txt")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            p.arguments = ["\(pid)", "3", "-file", file.path]
            try? p.run(); p.waitUntilExit()
            ConsoleOut.err("[fleetest] ocr shortcut still in flight after \(Int(hangSampleAfterSeconds))s;"
                + " sampled to \(file.path) expected=\"\(expected)\"")
        }
        t.name = "fleetest-ocr-hang-sample"
        t.start()
    }

    public static func resolveWithinBudget(expected: String, pngData: Data,
                                           frame: FTRect, screen: FTRect,
                                           cropPadding: CGFloat = 24,
                                           languages: [String]? = nil,
                                           budget: Duration = RegionText.occlusionBudget)
        async -> BudgetedReading {
        let watch = HangWatch()
        // 諦めても走っている読みを止めない理由は TaskBudget の冒頭。
        // **諦めた読みが最終的にどうなったか**は stderr に1行残す —— 予算切れの記録
        // (ocr-budget-exhausted)だけでは「予算が狭い」のか「読みが本当に遅い」のかが分けられない。
        // 所要・段数・画素数が揃えば、はしごを詰めるべきか予算を動かすべきかが決まる
        let outcome = await TaskBudget.run(budget, onLateFinish: { (r: (readable: Bool, reading: Reading)?, elapsed: Duration) in
            watch.markReturned()
            noteAbandoned(-1)
            let ms = Int(elapsed.components.seconds) * 1000
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            // **ファイルにも残す**(FT_OCR_HANG_SAMPLE=1 のとき): stderr の中継は経路によって
            // 落ちうるが、ファイルは落ちない。読み手は ~/.fleetest/ocr-late/ を集計する
            recordLateFinish(ms: ms, attempts: r?.reading.attempts ?? 0, pixels: r?.reading.pixels ?? 0,
                             readable: r?.readable ?? false, expected: expected)
            ConsoleOut.err("[fleetest] ocr shortcut finished late: \(ms)ms"
                + " attempts=\(r?.reading.attempts ?? 0) pixels=\(r?.reading.pixels ?? 0)"
                + " readable=\(r?.readable ?? false) expected=\"\(expected)\"")
        }) {
            await resolve(expected: expected, pngData: pngData, frame: frame, screen: screen,
                          cropPadding: cropPadding, languages: languages)
        }
        switch outcome {
        case .exhausted:
            noteAbandoned(+1)
            sampleSelfIfStillHung(watch, expected: expected)
            return .budgetExhausted
        case .value(nil): return .unreadable
        case .value(let r?): return .read(readable: r.readable, reading: r.reading)
        }
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
        return Reading(lines: lines, elapsedMs: elapsedMs, attempts: 1,
                       pixels: crop.width * crop.height)
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
