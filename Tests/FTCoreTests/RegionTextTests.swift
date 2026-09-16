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
