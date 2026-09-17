import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore

final class RegionTextTests: XCTestCase {

    // MARK: - readable(純関数)

    func testReadableTrueOnFullContainment() {
        XCTAssertTrue(RegionText.readable(expected: "ログイン", lines: ["ログイン"]))
    }

    /// 先頭一致だけ(期待の一部しか読めていない)は false —— 部分的に覆われて残りだけ読めた回を
    /// 「見えている」と通すと、guard の目的である誤った緑を作る
    func testReadableFalseOnPrefixOnlyMatch() {
        XCTAssertFalse(RegionText.readable(expected: "家電・電化製品", lines: ["家電・電化…"]))
    }

    func testReadableNormalizesWhitespaceFullwidthCaseAndEllipsis() {
        XCTAssertTrue(RegionText.readable(expected: "Log In...", lines: [" log　in "]))
    }

    /// 素の部分一致だと短い期待値が覆いの文字列に当たる(`exist("OK")` が「Cookieの設定」で素通り)。
    /// ASCII の期待値は語境界を要求する
    func testReadableRequiresAWordBoundaryForAsciiExpectations() {
        XCTAssertFalse(RegionText.readable(expected: "OK", lines: ["Cookieの設定"]))
        XCTAssertFalse(RegionText.readable(expected: "row", lines: ["arrow_40"]))
        XCTAssertTrue(RegionText.readable(expected: "OK", lines: ["OK!"]))
        XCTAssertTrue(RegionText.readable(expected: "row_40", lines: ["selected=row_40"]))
    }

    /// 日本語には語境界が無いので、CJK を含む期待値は素の含有のまま(折り返しも通る)
    func testReadableKeepsPlainContainmentForJapanese() {
        XCTAssertTrue(RegionText.readable(expected: "ログイン", lines: ["ログインしてください"]))
    }

    /// 拡大は画素の上限を超えたら諦める(読めるようにはならず、ビットマップだけが数十 MB になる)
    func testEnlargeStopsAtThePixelCap() {
        let small = makeCGImage(width: 200, height: 100)
        XCTAssertEqual(RegionText.enlarged(small, by: 3).width, 600)
        let large = makeCGImage(width: 2000, height: 1000)   // ×3 で 18 MP = 上限超え
        XCTAssertEqual(RegionText.enlarged(large, by: 3).width, 2000)
    }

    private func makeCGImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testReadableFalseWhenExpectedIsEmpty() {
        XCTAssertFalse(RegionText.readable(expected: "   ", lines: ["ログイン"]))
    }

    /// 折り返しで2行に分かれて読めても、返ってきた順に連結すれば含有するなら true
    func testReadableJoinsWrappedLines() {
        XCTAssertTrue(RegionText.readable(expected: "ログインしてください", lines: ["ログインして", "ください"]))
    }

    // MARK: - mode(environment:)

    func testModeOnValues() {
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "1"]), .on)
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "on"]), .on)
    }

    func testModeOffValues() {
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "0"]), .off)
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "off"]), .off)
    }

    func testModeMeasureValue() {
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "measure"]), .measure)
    }

    /// 既定はリテラルで固定する(差し替え口でしか値を書かないと、既定を戻す変更が緑のまま通る)
    func testModeDefaultsToOnWhenUnset() {
        XCTAssertEqual(RegionText.mode(environment: [:]), .on)
    }

    func testModeOnOnUnrecognizedValue() {
        XCTAssertEqual(RegionText.mode(environment: ["FT_OCCLUSION_OCR": "nonsense"]), .on)
    }

    // MARK: - Vision 往復(テストが production の代わりに正規化していないことの担保)

    /// AppKit(WindowServer)に依存しない CoreText 直描画。CGContext は原点左下・y 上向きで、
    /// CTLineDraw もこれをそのまま前提にする(フリップ不要)
    private func makeTextPNG(_ text: String?) -> Data {
        let width = 240, height = 80
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("テスト用 CGContext 生成に失敗")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            // CJK の字形は基準フォントに無くても CoreText のカスケード(自動代替)で描かれる
            let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 10, y: CGFloat(height) / 2 - 10)
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { fatalError("テスト用 CGImage 生成に失敗") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("テスト用 PNG destination 生成に失敗")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("テスト用 PNG 書き出しに失敗") }
        return output as Data
    }

    func testReadRoundTripsThroughVisionForRenderedText() async throws {
        let png = makeTextPNG("ログイン")
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let readingRaw = await RegionText.read(pngData: png, frame: rect, screen: rect)
        let reading = try XCTUnwrap(readingRaw)
        XCTAssertTrue(RegionText.readable(expected: "ログイン", lines: reading.lines),
                     "描いた文字列が読めるはず: \(reading.lines)")
        // 遅かった回の説明に使う画素数(等倍・frame = 画像全体なので画像そのものの画素数)
        XCTAssertEqual(reading.pixels, 240 * 80, "読ませた画像の画素数が記録されていない")
    }

    func testReadFindsNothingOnBlankImage() async throws {
        let png = makeTextPNG(nil)
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let readingRaw = await RegionText.read(pngData: png, frame: rect, screen: rect)
        let reading = try XCTUnwrap(readingRaw)
        XCTAssertFalse(RegionText.readable(expected: "ログイン", lines: reading.lines))
    }

    /// 読ませる言語は期待文字列から決める(日本語モデルの読み込みが所要の6割 —— 実測 p50 91→208ms)
    func testLanguagesFollowTheExpectedText() {
        XCTAssertEqual(RegionText.languages(for: "swipe=down"), ["en-US"])
        XCTAssertEqual(RegionText.languages(for: "ログイン"), ["ja-JP", "en-US"])
        XCTAssertEqual(RegionText.languages(for: "WebView 見出し"), ["ja-JP", "en-US"])
    }

    /// 拡大の段はリテラルで固定する(実測: ×1 で 71% → ×2 まで 88% → ×3 まで 97%・×4 は 74% に落ちる。
    /// docs/poc-fm-occlusion-guard.md §5.17)
    func testUpscaleLadderIsPinned() {
        XCTAssertEqual(RegionText.upscaleLadder, [1, 2, 3])
    }

    func testResolveReadsRenderedText() async throws {
        let png = makeTextPNG("ログイン")
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let resolvedRaw = await RegionText.resolve(expected: "ログイン", pngData: png,
                                                   frame: rect, screen: rect)
        let resolved = try XCTUnwrap(resolvedRaw)
        XCTAssertTrue(resolved.readable, "描いた文字列が読めるはず: \(resolved.reading.lines)")
    }

    /// 段を上げても読めない画像(白紙 = 覆い/空白の代理)は readable=false のまま FM へ回る
    func testResolveStaysUnreadableForBlankImage() async throws {
        let png = makeTextPNG(nil)
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let resolvedRaw = await RegionText.resolve(expected: "ログイン", pngData: png,
                                                   frame: rect, screen: rect)
        let resolved = try XCTUnwrap(resolvedRaw)
        XCTAssertFalse(resolved.readable)
    }

    /// 暖機を頼むのは on / measure のときだけ(off の run に Vision を読ませない)
    func testPrewarmIsRequestedOnlyWhenGateIsActive() {
        let before = RegionText.prewarmRequestCount
        RegionText.prewarmIfNeeded(mode: .off)
        XCTAssertEqual(RegionText.prewarmRequestCount, before, "off では暖機しない")
        RegionText.prewarmIfNeeded(mode: .on)
        RegionText.prewarmIfNeeded(mode: .measure)
        XCTAssertEqual(RegionText.prewarmRequestCount, before + 2)
    }

    /// 暖機は何度呼んでも安全で、そのあとの読み取りを壊さない(背景で走るので待たない)
    func testPrewarmIsIdempotentAndLeavesReadsWorking() async throws {
        RegionText.prewarmIfNeeded(mode: .on)
        RegionText.prewarmIfNeeded(mode: .on)
        let png = makeTextPNG("ログイン")
        let rect = FTRect(x: 0, y: 0, width: 240, height: 80)
        let readingRaw = await RegionText.read(pngData: png, frame: rect, screen: rect)
        let reading = try XCTUnwrap(readingRaw)
        XCTAssertTrue(RegionText.readable(expected: "ログイン", lines: reading.lines))
    }
}

// 言語補正は日本語モデルを載せる集合でだけ掛ける(字形の取り違え「単」→「单」を直す。
// ASCII では切ったまま = 欠けを推測で埋めさせない)。理由は RegionText.usesLanguageCorrection の doc
final class RegionTextLanguageCorrectionTests: XCTestCase {
    func testCorrectionFollowsTheLanguageSet() {
        XCTAssertTrue(RegionText.usesLanguageCorrection(for: ["ja-JP", "en-US"]))
        XCTAssertTrue(RegionText.usesLanguageCorrection(for: ["ja-JP"]))
        XCTAssertFalse(RegionText.usesLanguageCorrection(for: ["en-US"]))
        XCTAssertFalse(RegionText.usesLanguageCorrection(for: []))
        // 本番の 2 つの集合(languages(for:))と対応していること
        XCTAssertFalse(RegionText.usesLanguageCorrection(for: RegionText.languages(for: "swipe=down")))
        XCTAssertTrue(RegionText.usesLanguageCorrection(for: RegionText.languages(for: "単一行")))
    }
}

/// 差し替え口(`prewarmFinishOverrideForTesting`)だけになると「暖機の待ちを一度も通らない」
/// 変更が緑のまま通るので、**production の既定**をここで固定する(warmOverrideForTesting と同じ規律)
final class RegionTextAwaitPrewarmOverrideDefaultTests: XCTestCase {
    func testOverrideIsNotSetInProduction() {
        XCTAssertNil(RegionText.prewarmFinishOverrideForTesting,
                     "差し替え口が残っている(テストが後始末していない)")
    }
}

/// `RegionText.awaitPrewarm` — 暖機の完了を async から待つ。実 Vision の所要は制御できないので、
/// `prewarmFinishOverrideForTesting` で「進行中の時間」を作って測る(warmOverrideForTesting と
/// 組み合わせて warmed/finishedCold を作り分ける)
final class RegionTextAwaitPrewarmTests: XCTestCase {

    override func tearDown() {
        RegionText.warmOverrideForTesting = nil
        RegionText.prewarmFinishOverrideForTesting = nil
        super.tearDown()
    }

    func testAlreadyWarmReturnsImmediatelyWithoutWaiting() async {
        RegionText.warmOverrideForTesting = true
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await RegionText.awaitPrewarm(mode: .on, cap: .seconds(5))
        let elapsed = clock.now - start
        XCTAssertEqual(outcome, .alreadyWarm)
        XCTAssertLessThan(elapsed, .milliseconds(50), "既に暖まっているのに待っている(所要 \(elapsed))")
    }

    func testWaitsForAnInProgressWarmupThenReportsWarmed() async {
        RegionText.warmOverrideForTesting = false
        RegionText.prewarmFinishOverrideForTesting = {
            try? await Task.sleep(for: .milliseconds(150))
            RegionText.warmOverrideForTesting = true  // 暖機が成功して読めた体
        }
        let outcome = await RegionText.awaitPrewarm(mode: .on, cap: .seconds(5))
        guard case .warmed(let waited) = outcome else { return XCTFail("warmed を返していない: \(outcome)") }
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(130),
                                    "進行中の完了を待たずに返っている(所要 \(waited))")
    }

    func testWaitsForAnInProgressWarmupThenReportsFinishedColdWhenStillNotReadable() async {
        RegionText.warmOverrideForTesting = false
        RegionText.prewarmFinishOverrideForTesting = {
            try? await Task.sleep(for: .milliseconds(150))
            // warmOverrideForTesting は false のまま = 終わったが読めなかった(Vision 劣化)体
        }
        let outcome = await RegionText.awaitPrewarm(mode: .on, cap: .seconds(5))
        guard case .finishedCold(let waited) = outcome else { return XCTFail("finishedCold を返していない: \(outcome)") }
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(130))
    }

    /// **所要を直接測る**(戻り値の内訳を信じず、実際にかかった壁時計時間で確かめる)。
    /// cap を短く渡し、戻るまでの時間が cap 付近であること
    func testCapsTheWaitAtTheLimit() async {
        RegionText.warmOverrideForTesting = false
        RegionText.prewarmFinishOverrideForTesting = {
            try? await Task.sleep(for: .seconds(5))  // cap より十分長い(TaskBudget は仕事を止めない)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await RegionText.awaitPrewarm(mode: .on, cap: .milliseconds(150))
        let elapsed = clock.now - start
        guard case .capped = outcome else { return XCTFail("capped を返していない: \(outcome)") }
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(150), "上限より早く諦めている(所要 \(elapsed))")
        XCTAssertLessThan(elapsed, .seconds(2), "上限を大きく超えて待っている(所要 \(elapsed))")
    }
}

/// 差し替え口(`recognizeOverrideForTesting`)だけになると「探りの撃ち直しを一度も通らない」
/// 変更が緑のまま通るので、production の既定をここで固定する(warmOverrideForTesting と同じ規律)
final class RegionTextRecognizeOverrideDefaultTests: XCTestCase {
    func testOverrideIsNotSetInProduction() {
        XCTAssertNil(RegionText.recognizeOverrideForTesting,
                     "差し替え口が残っている(テストが後始末していない)")
    }
}

private enum RegionTextProbeTestError: Error { case boom }

/// テストからスレッドセーフに呼び出し回数を数えるだけの最小ヘルパー
private final class LockedCallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    @discardableResult
    func incrementAndGet() -> Int { lock.lock(); n += 1; defer { lock.unlock() }; return n }
}

/// `RegionText.probeWithRetry` — 暖機の探りが空(またはエラー)を返しても撃ち直すことの担保。
/// 実測(2026-09-16、`FT_OCR_HANG_SAMPLE=1` 採取): 手元のフリート実行 26 プロセス中 15 本が
/// 探り 1 回だけで空を引いて warm にならず、その run は OCR 使用率 0% になった。
/// Vision を実際に叩かず `recognizeOverrideForTesting` で結果を制御する
final class RegionTextProbeWithRetryTests: XCTestCase {

    override func tearDown() {
        RegionText.recognizeOverrideForTesting = nil
        super.tearDown()
    }

    private func dummyImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// 1 回目が空・2 回目で読める → warm になる(= 撃ち直しが効いている)
    func testRetriesUntilReadable() async {
        let callCount = LockedCallCount()
        RegionText.recognizeOverrideForTesting = { _ in
            callCount.incrementAndGet() == 1 ? [] : ["fleetest"]
        }
        let (lines, error, attempts) = await RegionText.probeWithRetry(
            image: dummyImage(), budget: .milliseconds(500), interval: .milliseconds(20))
        XCTAssertEqual(lines, ["fleetest"])
        XCTAssertNil(error)
        XCTAssertEqual(attempts, 2, "撃ち直した回数が記録されていない")
        XCTAssertEqual(callCount.value, 2)
        XCTAssertTrue(RegionText.warmedUp(probe: lines))
    }

    /// 常に空 → 予算内で止まる(無限ループしない)・warm にならない。
    /// 所要は戻り値でなく**実測(経過時間)**で確かめる
    func testStopsWithinBudgetWhenAlwaysEmpty() async {
        RegionText.recognizeOverrideForTesting = { _ in [] }
        let clock = ContinuousClock()
        let start = clock.now
        let (lines, _, attempts) = await RegionText.probeWithRetry(
            image: dummyImage(), budget: .milliseconds(300), interval: .milliseconds(50))
        let elapsed = clock.now - start
        XCTAssertFalse(RegionText.warmedUp(probe: lines))
        XCTAssertGreaterThan(attempts, 1, "撃ち直していない")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300), "予算より早く諦めている(所要 \(elapsed))")
        XCTAssertLessThan(elapsed, .milliseconds(600), "予算を大きく超えて撃ち続けている(所要 \(elapsed))")
    }

    /// 1 回目で読める → 撃ち直さない(呼び出し回数と所要の両方で確かめる)
    func testDoesNotRetryWhenFirstAttemptReads() async {
        let callCount = LockedCallCount()
        RegionText.recognizeOverrideForTesting = { _ in
            callCount.incrementAndGet()
            return ["fleetest"]
        }
        let clock = ContinuousClock()
        let start = clock.now
        let (lines, _, attempts) = await RegionText.probeWithRetry(
            image: dummyImage(), budget: .seconds(5), interval: .milliseconds(500))
        let elapsed = clock.now - start
        XCTAssertEqual(lines, ["fleetest"])
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(callCount.value, 1)
        XCTAssertLessThan(elapsed, .milliseconds(200), "撃ち直している(所要 \(elapsed))")
    }

    /// **既定値(production が実際に使う値)をリテラルで固定する**。他のテストが budget/interval を
    /// 明示して呼ぶので、これが無いと既定を 0 に落とす変更(= 撃ち直しが production で1度も
    /// 起きない)が緑のまま通る(2026-09-16 の変異チェックで実際に生き残った)
    func testDefaultRetryBudgetAndIntervalArePinned() {
        XCTAssertEqual(RegionText.prewarmRetryBudget, .seconds(2))
        XCTAssertEqual(RegionText.prewarmRetryInterval, .milliseconds(50))
    }

    /// **引数を省いた呼び出し(= production と同じ形)でも撃ち直す**。既定値の固定と対で、
    /// 「既定は残っているが引数の既定が使われていない」型の変更も落とす
    func testRetriesWithTheProductionDefaults() async {
        let callCount = LockedCallCount()
        RegionText.recognizeOverrideForTesting = { _ in
            callCount.incrementAndGet() == 1 ? [] : ["fleetest"]
        }
        let (lines, _, attempts) = await RegionText.probeWithRetry(image: dummyImage())
        XCTAssertEqual(lines, ["fleetest"])
        XCTAssertEqual(attempts, 2, "既定の予算で撃ち直していない")
    }

    /// エラーで返っても空と同じく撃ち直す
    func testRetriesAfterAnError() async {
        let callCount = LockedCallCount()
        RegionText.recognizeOverrideForTesting = { _ in
            if callCount.incrementAndGet() == 1 { throw RegionTextProbeTestError.boom }
            return ["fleetest"]
        }
        let (lines, error, attempts) = await RegionText.probeWithRetry(
            image: dummyImage(), budget: .milliseconds(500), interval: .milliseconds(20))
        XCTAssertEqual(lines, ["fleetest"])
        XCTAssertNil(error)
        XCTAssertEqual(attempts, 2)
    }
}

/// `RegionText.shouldStartAnotherRound` — 純粋関数の境界(cooldown・予算)。2026-09-18、
/// L24 の再発(N3): 1 ラウンド冷えて終わったプロセスがそのまま見捨てられていた事象の直し方。
/// `ContinuousClock.Instant` の加減算だけで作るので壁時計を待たない
final class RegionTextShouldStartAnotherRoundTests: XCTestCase {
    func testFalseWhenCooldownNotYetElapsed() {
        let now = ContinuousClock().now
        let last = now - .seconds(10)
        XCTAssertFalse(RegionText.shouldStartAnotherRound(
            now: now, lastRoundFinishedAt: last, spentOnProbes: .zero,
            cooldown: .seconds(30), totalBudget: .seconds(6)))
    }

    func testTrueExactlyAtTheCooldownBoundary() {
        let now = ContinuousClock().now
        let last = now - .seconds(30)
        XCTAssertTrue(RegionText.shouldStartAnotherRound(
            now: now, lastRoundFinishedAt: last, spentOnProbes: .zero,
            cooldown: .seconds(30), totalBudget: .seconds(6)))
    }

    func testFalseWhenTotalBudgetIsExhausted() {
        let now = ContinuousClock().now
        let last = now - .seconds(60)
        XCTAssertFalse(RegionText.shouldStartAnotherRound(
            now: now, lastRoundFinishedAt: last, spentOnProbes: .seconds(6),
            cooldown: .seconds(30), totalBudget: .seconds(6)))
    }

    func testFalseWhenTotalBudgetIsAlreadyOverspent() {
        let now = ContinuousClock().now
        let last = now - .seconds(60)
        XCTAssertFalse(RegionText.shouldStartAnotherRound(
            now: now, lastRoundFinishedAt: last, spentOnProbes: .seconds(9),
            cooldown: .seconds(30), totalBudget: .seconds(6)))
    }

    func testTrueWhenCooldownElapsedAndBudgetRemains() {
        let now = ContinuousClock().now
        let last = now - .seconds(31)
        XCTAssertTrue(RegionText.shouldStartAnotherRound(
            now: now, lastRoundFinishedAt: last, spentOnProbes: .milliseconds(4_000),
            cooldown: .seconds(30), totalBudget: .seconds(6)))
    }

    /// **既定値をリテラルで固定する**(production が実際に使う値)。他のテストが cooldown/totalBudget
    /// を明示して呼ぶので、これが無いと既定を 0 に落とす変更が緑のまま通る
    /// (`RegionTextProbeWithRetryTests.testDefaultRetryBudgetAndIntervalArePinned` と同じ規律)
    func testDefaultCooldownAndTotalBudgetArePinned() {
        XCTAssertEqual(RegionText.prewarmColdRetryCooldown, .seconds(30))
        XCTAssertEqual(RegionText.prewarmColdRetryTotalBudget, .seconds(6))
    }

    /// 引数を省いた呼び出し(= production と同じ形)でも既定の cooldown/totalBudget を使うこと
    func testUsesProductionDefaultsWhenOmitted() {
        let now = ContinuousClock().now
        XCTAssertFalse(RegionText.shouldStartAnotherRound(
            now: now, lastRoundFinishedAt: now - .seconds(10), spentOnProbes: .zero))
        XCTAssertTrue(RegionText.shouldStartAnotherRound(
            now: now, lastRoundFinishedAt: now - .seconds(31), spentOnProbes: .zero))
    }
}

/// `RegionText.PrewarmRoundState` — ラウンドの状態機械そのもの(cooldown・予算・二重起動防止)。
/// 実 Vision・スレッド・flock を経由しない自前インスタンスで検証する(高速・決定的)
final class RegionTextPrewarmRoundStateTests: XCTestCase {
    func testNeverFinishedRoundIsInFlight() {
        let state = RegionText.PrewarmRoundState()
        XCTAssertEqual(state.resolveRetryStatus(now: ContinuousClock().now), .inFlight,
                       "ラウンド 1 が一度も終わっていないのに inFlight 以外を返している")
    }

    func testNotEligibleBeforeCooldownElapses() {
        let state = RegionText.PrewarmRoundState()
        let finishedAt = ContinuousClock().now
        state.recordFinished(now: finishedAt, spent: .milliseconds(200))
        XCTAssertEqual(state.resolveRetryStatus(now: finishedAt, cooldown: .seconds(30), totalBudget: .seconds(6)),
                       .notEligible)
    }

    /// 予約は排他: 予約した瞬間に running が立つので、同じ瞬間の別の呼び手は inFlight を見て
    /// 二重にラウンドを起こさない
    func testReservationIsExclusiveAndSubsequentCallsSeeInFlight() {
        let state = RegionText.PrewarmRoundState()
        let finishedAt = ContinuousClock().now
        state.recordFinished(now: finishedAt, spent: .milliseconds(200))
        let eligible = finishedAt + .seconds(31)
        XCTAssertEqual(state.resolveRetryStatus(now: eligible, cooldown: .seconds(30), totalBudget: .seconds(6)),
                       .reserved, "cooldown を空けたのに予約できていない")
        XCTAssertEqual(state.resolveRetryStatus(now: eligible, cooldown: .seconds(30), totalBudget: .seconds(6)),
                       .inFlight, "予約済みのラウンドがあるのに二重に予約している")
    }

    /// 予約すると新しい(未完了の)シグナルに差し替わる —— 前のラウンドの `currentSignal` を
    /// 待っていた古い待ち手を巻き込まない
    func testReservationReplacesTheSignalWithAFreshOne() {
        let state = RegionText.PrewarmRoundState()
        let finishedAt = ContinuousClock().now
        state.recordFinished(now: finishedAt, spent: .zero)
        XCTAssertTrue(state.currentSignal.isFinished)
        let eligible = finishedAt + .seconds(31)
        guard case .reserved = state.resolveRetryStatus(now: eligible, cooldown: .seconds(30), totalBudget: .seconds(6))
        else { return XCTFail("reserved を返していない") }
        XCTAssertFalse(state.currentSignal.isFinished, "予約直後は新しい未完了のシグナルであるべき")
    }

    /// 探りに使った時間はラウンドをまたいで積み上がる。3 ラウンドぶん(2 秒 × 3 = 6 秒)使い切ると
    /// 4 ラウンド目は cooldown を空けても notEligible になる
    func testSpentTimeAccumulatesAcrossRoundsUntilBudgetIsExhausted() {
        let state = RegionText.PrewarmRoundState()
        var t = ContinuousClock().now
        state.recordFinished(now: t, spent: .seconds(2))  // ラウンド 1
        t = t + .seconds(31)
        XCTAssertEqual(state.resolveRetryStatus(now: t, cooldown: .seconds(30), totalBudget: .seconds(6)), .reserved)
        state.recordFinished(now: t, spent: .seconds(2))  // ラウンド 2、合計 4 秒
        t = t + .seconds(31)
        XCTAssertEqual(state.resolveRetryStatus(now: t, cooldown: .seconds(30), totalBudget: .seconds(6)), .reserved)
        state.recordFinished(now: t, spent: .seconds(2))  // ラウンド 3、合計 6 秒 = 予算ちょうど
        t = t + .seconds(31)
        XCTAssertEqual(state.resolveRetryStatus(now: t, cooldown: .seconds(30), totalBudget: .seconds(6)), .notEligible,
                       "予算を使い切ったのに 4 ラウンド目を許している(無限に撃ち直す)")
    }
}

/// `RegionText.awaitPrewarm` のラウンド制を実際のシングルトン(`RegionText.roundState`)経由で
/// 通す。前段のラウンドは実行せず `recordFinished` で直接シードする(実 Vision の初回ロード
/// (最大 47 秒)を待たない・`prewarmOnce` の一度きりの発火に依存しない)。テスト間で共有される
/// プロセス全体の状態(`roundState`・`warm`)なので、必ず自分でリセットしてから使う
final class RegionTextColdRetryRoundTests: XCTestCase {
    override func tearDown() {
        RegionText.warmOverrideForTesting = nil
        RegionText.prewarmFinishOverrideForTesting = nil
        RegionText.recognizeOverrideForTesting = nil
        RegionText.roundState = RegionText.PrewarmRoundState()
        RegionText.resetWarmForTesting()
        super.tearDown()
    }

    /// 冷えた 1 ラウンド目のあと、cooldown を空けた `awaitPrewarm` が新しいラウンドを実際に走らせ、
    /// そのラウンドの探りが(1 回目は空・2 回目は読める)最終的に読めれば `.warmed` を返す
    func testAwaitPrewarmStartsAnotherRoundAfterCooldownAndReportsWarmed() async {
        RegionText.resetWarmForTesting()
        let seeded = RegionText.PrewarmRoundState()
        let coldFinishedAt = ContinuousClock().now - RegionText.prewarmColdRetryCooldown - .seconds(1)
        seeded.recordFinished(now: coldFinishedAt, spent: .milliseconds(500))
        RegionText.roundState = seeded

        let callCount = LockedCallCount()
        RegionText.recognizeOverrideForTesting = { _ in
            callCount.incrementAndGet() == 1 ? [] : ["fleetest"]
        }

        let outcome = await RegionText.awaitPrewarm(mode: .on, cap: .seconds(5))
        guard case .warmed = outcome else { return XCTFail("warmed を返していない: \(outcome)") }
        XCTAssertTrue(RegionText.isWarm)
        XCTAssertGreaterThanOrEqual(callCount.value, 2, "撃ち直したラウンドが実際に走っていない")
    }

    /// mode が off の run では、条件を満たしていても新しいラウンドを起こさない
    /// (off の run に Vision を読ませない契約。待ち手を取り残さないことも確かめる)
    func testAwaitPrewarmStartsNoRoundWhenTheGateIsOff() async {
        RegionText.resetWarmForTesting()
        let seeded = RegionText.PrewarmRoundState()
        seeded.recordFinished(now: ContinuousClock().now - RegionText.prewarmColdRetryCooldown - .seconds(1),
                              spent: .milliseconds(500))
        RegionText.roundState = seeded

        let callCount = LockedCallCount()
        RegionText.recognizeOverrideForTesting = { _ in
            _ = callCount.incrementAndGet()
            return ["fleetest"]
        }

        let outcome = await RegionText.awaitPrewarm(mode: .off, cap: .seconds(5))
        guard case .finishedCold(let waited) = outcome else { return XCTFail("finishedCold を返していない: \(outcome)") }
        XCTAssertEqual(waited, .zero)
        XCTAssertEqual(callCount.value, 0, "off の run で探りを撃っている")
    }

    /// 予算を使い切っていれば、cooldown を空けていても待たずに `.finishedCold` へ戻る
    /// (無限に撃ち直さない)
    func testAwaitPrewarmStaysColdOnceTheRetryBudgetIsExhausted() async {
        RegionText.resetWarmForTesting()
        let seeded = RegionText.PrewarmRoundState()
        let coldFinishedAt = ContinuousClock().now - RegionText.prewarmColdRetryCooldown - .seconds(1)
        seeded.recordFinished(now: coldFinishedAt, spent: RegionText.prewarmColdRetryTotalBudget)
        RegionText.roundState = seeded

        let outcome = await RegionText.awaitPrewarm(mode: .on, cap: .seconds(5))
        guard case .finishedCold(let waited) = outcome else { return XCTFail("finishedCold を返していない: \(outcome)") }
        XCTAssertEqual(waited, .zero, "予算切れなのに待っている")
        XCTAssertFalse(RegionText.isWarm)
    }
}
