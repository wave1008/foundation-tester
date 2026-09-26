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
import CoreML
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

    /// `FT_OCCLUSION_OCR`: "0"/"off" → 殺しスイッチ(OCR を呼ばず FM だけ呼ぶ)/
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

    /// 探りの撃ち直しに使ってよい合計時間の上限。**根拠**(実測、`FT_OCR_HANG_SAMPLE=1`
    /// 採取): 探り 1 回の所要は 130〜235ms(空で返る回のほうが速い)。手元のフリート実行 26 プロセス中
    /// 15 本が探り1回だけで空を引いて warm にならず、その run は OCR 使用率 0%(FM が死んでいれば
    /// 視覚検証が丸ごと素通りする)。置き換える相手(FM 段)の実測下限は 1.3 秒/回で、ガードは
    /// 1 シナリオに数十回入るので、この上限を使い切っても最大 FM 1〜2 回分のコストで済む。
    /// **尽きても挙動は変わらない**(warm にならず `ocr-shortcut-not-warm` の注記で FM へ)
    public static let prewarmRetryBudget: Duration = .seconds(2)

    /// 撃ち直しの間隔。**根拠**: 探り自体が 130〜235ms かかるので、間隔を空けずに連打すると
    /// `prewarmRetryBudget` を読みの所要だけでほぼ使い切り、撃ち直しの機会が実質 1 回で終わる。
    /// 50ms は探りの所要の下限より短く、2 秒の予算内で複数回の撃ち直しを確保する
    public static let prewarmRetryInterval: Duration = .milliseconds(50)

    /// 暖機の探りが使う認識器。**テストは `recognizeOverrideForTesting` で差し替え、Vision を
    /// 実際に叩かない**。探りは常に `renderedProbe()` の ASCII 文字列("fleetest")なので、
    /// `languages(for:)` の言語判定は通さず `defaultLanguages` 固定でよい
    static func recognizeForPrewarm(_ image: CGImage) async throws -> [String] {
        if let override = recognizeOverrideForTesting { return try await override(image) }
        return try await recognize(image, languages: defaultLanguages)
    }

    /// テストが Vision を実際に叩かずに探りの結果を制御するための差し替え口(production では nil)。
    /// **既定が nil であること自体は `RegionTextRecognizeOverrideDefaultTests` が固定する**
    /// (`warmOverrideForTesting` と同じ規律)
    public static var recognizeOverrideForTesting: (@Sendable (CGImage) async throws -> [String])?

    /// 探りを撃ち、空(またはエラー)なら `interval` だけ待って `budget` を使い切るまで撃ち直す。
    /// **少なくとも 1 回は撃つ**(budget が 0 でも最初の 1 回は必ず走る)。読めた時点で即終了。
    /// テストが直接 await できるよう async 関数として独立させてある —— production の呼び手
    /// (`prewarmOnce`)は専用スレッドから DispatchSemaphore でこの完了を待つだけ
    static func probeWithRetry(image: CGImage, budget: Duration = RegionText.prewarmRetryBudget,
                               interval: Duration = RegionText.prewarmRetryInterval)
        async -> (lines: [String]?, error: String?, attempts: Int) {
        let clock = ContinuousClock()
        let deadline = clock.now + budget
        var attempts = 0
        var lastLines: [String]?
        var lastError: String?
        while true {
            attempts += 1
            do {
                let lines = try await recognizeForPrewarm(image)
                lastLines = lines
                lastError = nil
                if warmedUp(probe: lines) { return (lines, nil, attempts) }
            } catch {
                lastLines = nil
                lastError = "\(error)"
            }
            guard clock.now < deadline else { return (lastLines, lastError, attempts) }
            try? await Task.sleep(for: interval)
        }
    }

    private static let prewarmOnce: Void = {
        // **専用スレッド**(協調スレッドプールに載せない): 下の flock はブロックする。
        // 別の暖機(`warm-ocr`)がコンパイル中ならその完了を待ってから読む —— 待たずに自分でも
        // コンパイルすると 8 レーンぶんが同じモデルを同時に焼いて CPU を奪い合い、自分の分は
        // プロセスが先に死んでコミットされない(OCRWarmupLock の冒頭)
        let thread = Thread {
            // **「終わった」を必ず立てる**(読めた/読めない/画像不正のどの return 経路でも)。
            // `awaitPrewarm` の待ち手はこれが立つまで戻らない。lock の close より先に宣言する
            // (defer は LIFO なので、待ち手が起きる時点で flock は既に閉じている)
            defer { prewarmFinishSignal.markFinished() }
            let lock = OCRWarmupLock.acquire(processName: ProcessInfo.processInfo.processName)
            defer { try? lock?.close() }
            // 空の画像では認識器が言語モデルまで読み込まないことがあるので、文字を描いて読ませる
            guard let image = renderedProbe() else {
                recordPrewarmOutcome(lines: nil, error: "no probe image", attempts: 0)
                return
            }
            let started = Date()
            let done = DispatchSemaphore(value: 0)
            let box = ProbeBox()
            Task.detached(priority: .userInitiated) {
                let (lines, error, attempts) = await probeWithRetry(image: image)
                box.set(lines, error, attempts: attempts)
                done.signal()
            }
            done.wait()
            let (read, failure, attempts) = box.get()
            recordPrewarmOutcome(lines: read, error: failure,
                                 ms: Int(Date().timeIntervalSince(started) * 1000), attempts: attempts)
            guard warmedUp(probe: read) else { return }
            markWarm()
        }
        thread.name = "fleetest-ocr-prewarm"
        thread.qualityOfService = .userInitiated
        thread.start()
    }()

    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String]?
        private var error: String?
        private var attempts: Int = 0
        func set(_ l: [String]?, _ e: String?, attempts a: Int) {
            lock.lock(); lines = l; error = e; attempts = a; lock.unlock()
        }
        func get() -> ([String]?, String?, Int) {
            lock.lock(); defer { lock.unlock() }; return (lines, error, attempts)
        }
    }

    private static let warmLock = NSLock()
    private static var warm = false
    /// 同期関数に閉じ込める(async 文脈で lock/unlock を直に書くと Swift 6 で診断が出る)
    private static func markWarm() { warmLock.lock(); warm = true; warmLock.unlock() }

    /// 暖機が「終わった」(成否を問わない)ことを async の待ち手へ知らせる信号。**待ち手は複数
    /// 許す**(occlusionFlip が並行に複数走っても壊れないため)。同期関数に閉じ込める
    /// (markWarm と同じ理由 — async 文脈で lock を直に触らない)
    private final class PrewarmFinishSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markFinished() {
            lock.lock()
            finished = true
            let toResume = waiters
            waiters = []
            lock.unlock()
            for continuation in toResume { continuation.resume() }
        }

        /// 既に終わっていれば即 resume。**継続を2回 resume しない**(finished かどうかの判定と
        /// waiters への追加を同じロックの中で行う)
        /// 暖機が(読めたか否かに関わらず)もう終わっているか。終わっていれば待つ必要が無い
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

        func waitUntilFinished() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private static let prewarmFinishSignal = PrewarmFinishSignal()

    /// `awaitPrewarm` が待つ本体をテストが差し替えるための口(production では nil)。設定されて
    /// いれば実際の `prewarmFinishSignal` を待たず、この関数の完了をそのまま待ち対象にする ——
    /// 実 Vision を積む本物の暖機は「進行中」を狙った時刻に作れないため。**既定が nil であること
    /// 自体は `RegionTextAwaitPrewarmTests` が固定する**(`warmOverrideForTesting` と同じ規律)
    public static var prewarmFinishOverrideForTesting: (@Sendable () async -> Void)?

    /// `awaitPrewarm` の戻り値。呼び手(occlusionFlip)は `waited` を締め切りの計上に使う
    public enum WarmWaitOutcome: Sendable, Equatable {
        /// 呼んだ時点で既に暖まっていた(待っていない)
        case alreadyWarm
        /// 待って暖まった
        case warmed(waited: Duration)
        /// 待ったが暖機が終わっても読めなかった(Vision が劣化している状態。RegionText.warmedUp の doc)
        case finishedCold(waited: Duration)
        /// `cap` を使い切っても終わらなかった
        case capped(waited: Duration)
    }

    /// `awaitPrewarm` の待ちの上限。**根拠**: 暖機が正当にかかった実測の最大 108 秒
    /// (建て直し直後の Espresso コンパイル)に余裕 1 割。これを超えて戻らないのは
    /// ANE のコンパイルがハングした形(過去に 352〜1080 秒の実測 = fm-flap-ane-load-failure)。
    /// **尽きたら待つのをやめて FM に回す**(occlusionFlip の既存の見送り経路。止めない)
    public static let prewarmWaitCap: Duration = .seconds(120)

    /// occlusion-guard の OCR 近道を実際に撃つ直前に呼ぶ。**暖機が終わるまで待つ**
    /// (ユーザー決定: run の開始時には待たない・近道を呼ぶ時点でだけ待つ)。
    /// 既に暖まっていれば待たない(`.alreadyWarm`)。まだ始まっていなければここで始める
    /// (`prewarmIfNeeded`)。**mode が off のときは呼ばない**(呼び手の責任。off の run に
    /// Vision を読ませない契約は prewarmIfNeeded と同じ)。待った時間は
    /// `DeadlineExclusion` へ計上する(締め切りの計算からこの待ちを差し引くため)
    public static func awaitPrewarm(mode: RegionTextGateMode,
                                    cap: Duration = prewarmWaitCap) async -> WarmWaitOutcome {
        if isWarm { return .alreadyWarm }
        // 暖機が終わったのに読めない(Vision が空を返す)状態では、ガードのたびに差し引きの窓を開けない
        // (待つものが無いのに子→親の deadlineExclusion を毎ステップ 2 行ずつ流すことになる)
        if prewarmFinishOverrideForTesting == nil, prewarmFinishSignal.isFinished { return .finishedCold(waited: .zero) }
        prewarmIfNeeded(mode: mode)
        let clock = ContinuousClock()
        let start = clock.now
        let token = DeadlineExclusion.begin(cap: cap)
        let waitBody = prewarmFinishOverrideForTesting ?? { await prewarmFinishSignal.waitUntilFinished() }
        let outcome = await TaskBudget.run(cap) { await waitBody() }
        DeadlineExclusion.end(token)
        let waited = clock.now - start
        switch outcome {
        case .exhausted: return .capped(waited: waited)
        case .value: return isWarm ? .warmed(waited: waited) : .finishedCold(waited: waited)
        }
    }

    /// **コンパイル結果をキャッシュへコミットさせる**ための暖機(待つ版)。
    ///
    /// Espresso(Vision の認識器の実体)のコンパイルキャッシュは**プロセス名ごと**
    /// (`~/Library/Caches/<プロセス名>/com.apple.e5rt.e5bundlecache`)で、コンパイル
    /// (コールドで 20〜45 秒)が**そのプロセスの生存中に終わったときだけ**コミットされる。
    /// シナリオ実行プロセス(1シナリオ=1プロセス・20〜60 秒)は終わる前に死んで `.tmp` を残すだけで、
    /// 次のプロセスがまたゼロから払っていた(実測: E2E-CMP で完了 1 / 放置 53)。
    /// 鍵は**プロセス名とバイナリの素性の両方**(別名にコピーしてもコールド・作り直してもコールド。
    /// 同一ソースの再ビルドは決定的で同じバイナリになるため、そこでは暖まったままに見える)。
    /// つまり保守者はコミットのたびに SUT ごと 1 回払い直す(背景・供給と並行)。受け手は導入ごとに 1 回。
    /// だから **同じプロセス名の、待てるプロセス**(`fleetest-scenarios-<project> warm-ocr`)で
    /// 1回撃ち切る。以後そのプロセス名の初回読みは 160〜290ms になる。
    /// 読ませる言語集合は `languages(for:)` が返しうる2つ(モデルが別で、別々にコンパイルされる)
    public static let warmupLanguageSets: [[String]] = [["en-US"], defaultLanguages]

    public struct WarmupResult: Sendable {
        public let languages: [String]
        public let ms: Int
        public let lines: [String]
        public let error: String?
    }

    public static func commitCompileCache() async -> [WarmupResult] {
        guard let image = renderedProbe() else { return [] }
        var results: [WarmupResult] = []
        for languages in warmupLanguageSets {
            let started = Date()
            do {
                let lines = try await recognize(image, languages: languages)
                results.append(WarmupResult(languages: languages, ms: Int(Date().timeIntervalSince(started) * 1000),
                                            lines: lines, error: nil))
            } catch {
                results.append(WarmupResult(languages: languages, ms: Int(Date().timeIntervalSince(started) * 1000),
                                            lines: [], error: "\(error)"))
            }
        }
        return results
    }

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
    /// 実在する(この Mac で Vision が終日 `[]` を返していた実測がある)。そこで近道を撃つと
    /// 毎ステップ予算(occlusionBudget)を捨てるだけで、判定は結局 FM が下す。
    /// 探りは `renderedProbe()` = 必ず文字がある画像なので、空 = 読めていない
    public static func warmedUp(probe: [String]?) -> Bool { !(probe ?? []).isEmpty }

    /// OCR の近道を撃ってよいか。純粋関数(呼び出し側の配線は1箇所)。
    /// - **モデルが載るまでは撃たない** —— 載っていない間に撃っても予算を捨てるだけで、判定は
    ///   結局 FM が下す
    /// - **諦めた読みが走っている間は撃たない** —— 実測(SNB-M1 ジェスチャ S0010):
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
    public static func enlarged(_ image: CGImage, by factor: Int) -> CGImage {
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
    /// 定義。尽きたら `.budgetExhausted` を返し、呼び手は「読めなかった」と同じく FM へ落とす
    /// (判定は変えない。読めなかったことを反転の根拠にしない契約は resolve の doc と同じ)。
    ///
    /// **走っている OCR は止めない** —— Vision のモデルの初回ロードは**プロセスに1回**なので、
    /// ここで止めると次のステップもまた予算を使い切る。放っておけばそのまま暖機として効き、
    /// 2 回目以降は 40〜130ms で返る(実測: 予算を入れる前は最初にガードへ入った
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
    /// (実測: 諦めた読みは 10 秒以内には戻る = 10 秒待つと採れない)。調整値ではない
    static let hangSampleAfterSeconds: Double = 3

    /// 諦めた読みが戻ったかの旗(late finish が立てる)。採取は戻っていないときだけ
    final class HangWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var returned = false
        func markReturned() { lock.lock(); returned = true; lock.unlock() }
        var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
    }

    /// 暖機の探りの顛末(FT_OCR_HANG_SAMPLE=1 のとき)。**warm にならない理由**はここにしか出ない。
    /// `attempts` = 撃った回数(撃ち直し込み。画像不正で 1 回も撃てなければ 0)
    static func recordPrewarmOutcome(lines: [String]?, error: String?, ms: Int = 0, attempts: Int = 1) {
        guard hangSamplingEnabled(environment: ProcessInfo.processInfo.environment) else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest/ocr-late", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let entry: [String: Any] = ["pid": pid, "prewarm": true, "ms": ms, "attempts": attempts,
                                    "lines": lines ?? [], "error": error ?? "", "warm": warmedUp(probe: lines)]
        if let data = try? JSONSerialization.data(withJSONObject: entry) {
            try? data.write(to: dir.appendingPathComponent("prewarm-\(pid).json"))
        }
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

    /// 諦めた読みが戻り、`abandonedInFlight` を引いた**直後**に呼ぶ(テスト用。本番では nil)。
    /// 「戻ったら減る」を壁時計の上限なしに確かめるため —— 読みの所要は負荷で数秒に伸びる
    /// (全件並列の swift test で 5 秒の待ちを越えて落ちた)(`warmOverrideForTesting` と同じ規律)
    nonisolated(unsafe) public static var lateFinishObserverForTesting: (@Sendable () -> Void)?

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
            lateFinishObserverForTesting?()
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
    /// **`recognize` を実際に撃った回だけ `VisionUsageLedger` へ記録する**(crop が作れず到達しなかった
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
            VisionUsageLedger.record(ok: false, ms: Date().timeIntervalSince(start) * 1000)
            return nil
        }
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        VisionUsageLedger.record(ok: true, ms: elapsedMs)
        return Reading(lines: lines, elapsedMs: elapsedMs, attempts: 1,
                       pixels: crop.width * crop.height)
    }

    public static let defaultLanguages = ["ja-JP", "en-US"]

    /// 言語補正を掛けるのは**日本語モデルを載せる集合だけ**。
    /// - ASCII(en-US だけ)では切る: 欠けを推測で埋めさせない(補正は「丸ごと読めた」の意味を弱める。
    ///   固定コーパスの `swipe=down` / `selected=row_40` は補正なしで等倍から読める)
    /// - 日本語では入れる(実測): en ロケールのシミュレータは「単」(U+5358)を中国語フォントの
    ///   字形で描き、補正なしだと Vision も FM も「单」(U+5355)と読んで 3 文字の placeholder「単一行」が
    ///   誤った赤になった。補正ありなら「単一行」と読む。合成コーパス(ja 79 要素)で補正ありは
    ///   見えている 76→78/79 が読め、空白・全面の覆い・別の文字で読めた回は 0 のまま
    ///   (= 覆われた語を補完しない)。`キーポード`→`キーボード`・`Appleseea`→`Appleseed` も直る
    public static func usesLanguageCorrection(for languages: [String]) -> Bool {
        languages.contains("ja-JP")
    }

    /// 読ませる言語は**期待文字列から決める**。日本語モデルを載せると 1 回あたり p50 91→208ms
    /// になるので、期待文字列が ASCII だけのときは英語だけにする(実測: ASCII の期待値では
    /// 読み取り結果が両者で完全に一致する)。非 ASCII(かな・漢字など)を含むときだけ日本語を足す。
    public static func languages(for expected: String) -> [String] {
        expected.allSatisfy { $0.isASCII } ? ["en-US"] : defaultLanguages
    }

    /// 版(revision)は指定しない —— **OS が既定に選んだものを使う**。固定すると新しい OS で
    /// 改善された認識器を使えなくなる。版が動いたときの検出は実 crop の固定コーパス
    /// (`Tests/Fixtures/OcclusionCrops/`・段ごとの読み取りを等号で固定)が担う。
    /// 認識器を載せる計算装置。**既定は ANE を避ける**(CPU 優先・次に GPU)。
    ///
    /// **これは初回 20〜45 秒の原因ではない** —— あれは Espresso のコンパイルキャッシュがプロセス名
    /// ごとで、シナリオ実行プロセスがコミットする前に死んでいたため(`commitCompileCache` の doc。
    /// 装置を CPU にしてもコンパイルは同じだけ走る = 3 秒時点のスタックで確認)。
    /// ANE を避ける理由は実行時のほう: 定常の所要は CPU/GPU/ANE で同じ(実測 100〜160ms)で、
    /// ANE は FM フラップ(fm-flap)と同じ部品なので、判定の近道をそこに依存させない。
    /// 装置を変えると読みが変わる(固定コーパス: selected-row40 の ja+en ×3 は ANE では読めて CPU では
    /// 読めない。production の言語規則の経路は両装置で同じ)。
    /// `FT_OCR_COMPUTE=default` は Vision の既定(ANE 込み)へ戻す**計測用の口**
    public enum ComputeChoice: Equatable { case avoidNeuralEngine, visionDefault }

    public static func computeChoice(environment: [String: String]) -> ComputeChoice {
        environment["FT_OCR_COMPUTE"] == "default" ? .visionDefault : .avoidNeuralEngine
    }

    /// 候補から ANE 以外を選ぶ(CPU 優先・次に GPU)。無ければ nil = Vision の既定に任せる。純粋関数
    static func pickNonNeuralEngine(_ candidates: [MLComputeDevice]) -> MLComputeDevice? {
        if let cpu = candidates.first(where: { if case .cpu = $0 { return true } else { return false } }) { return cpu }
        return candidates.first(where: { if case .gpu = $0 { return true } else { return false } })
    }

    private static func recognize(_ image: CGImage, languages: [String]) async throws -> [String] {
        var request = RecognizeTextRequest()
        // 実測 p50 33ms なので速度のために fast へ落とさない(欠けを取りこぼすほうが高くつく)。
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection(for: languages)
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        if computeChoice(environment: ProcessInfo.processInfo.environment) == .avoidNeuralEngine {
            for (stage, candidates) in request.supportedComputeStageDevices {
                if let device = pickNonNeuralEngine(candidates) {
                    request.setComputeDevice(device, for: stage)
                }
            }
        }
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

    /// 省略記号として読まれる点の類(NFKC 後の字で持つ。`…` は NFKC で `...`、`‥` は `..`、
    /// `･` は `・`、`：` は `:` になる)。日本語フォント(ヒラギノ)の `…` は点が字の中央の高さに
    /// 並ぶ字形で、OCR は `…` と読まず `•••`・`・・・`・`⋯・`・`:・・` のような点の列として読む
    /// (合成実測: 列として受けないと先頭 5 文字以上の省略でも ja の約 9 割が「別の文字」で赤)
    private static let ellipsisDots: Set<Character> = [".", "•", "・", "·", "*", ":", "⋯"]

    /// NFKC・空白除去済みの文字列の末尾にある省略記号の長さ(無ければ 0)。点の類が **2 つ以上
    /// 続くか `⋯` を含む**ときだけ省略と見る —— 1 つだけの `.`・`:` は文末や「Inc.」「名前:」に
    /// 普通に現れる。`。` は日本語の文末なので点の類に入れない
    static func ellipsisTailLength(_ t: String) -> Int {
        let tail = t.reversed().prefix { ellipsisDots.contains($0) }
        return tail.count >= 2 || tail.contains("⋯") ? tail.count : 0
    }

    /// 末尾に省略記号があるか(正規化の前の生の文字列で判定する)。**`normalize` はこれと同じ
    /// `ellipsisTailLength` で除去する** —— 片方だけ変えると「normalize が削った」と
    /// 「TranscriptMatch が省略と見た」が食い違う
    public static func endsWithEllipsis(_ s: String) -> Bool {
        ellipsisTailLength(s.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()) > 0
    }

    /// 全角引用符 → 半角(NFKC では揃わない)。実例(iOS 設定「"リサーチ"の…」「"カレンダー"の新機能」):
    /// 木(期待値)は全角の“…”だが OCR/FM の読みは半角の "…" になり、畳まないと誤った赤になっていた
    private static let quoteFoldMap: [Character: Character] = [
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
    ]

    private static func foldQuotes(_ s: String) -> String {
        String(s.map { quoteFoldMap[$0] ?? $0 })
    }

    /// NFKC 互換合成 → 引用符の半角化 → 空白(半角・全角・改行・タブ)除去 → 末尾の省略記号
    /// (`ellipsisTailLength`)除去 → 小文字化。
    public static func normalize(_ s: String) -> String {
        var t = foldQuotes(s.precomposedStringWithCompatibilityMapping)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        t.removeLast(ellipsisTailLength(t))
        return t.lowercased()
    }
}
