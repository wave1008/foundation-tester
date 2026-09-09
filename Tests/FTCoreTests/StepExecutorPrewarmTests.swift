// Vision のモデルの初回ロードは**プロセスに1回・実測 25〜108 秒**で、ガードの中から呼ぶと
// 最初にガードへ入った1ステップがそれを丸ごと払う(2026-09-10 のフル E2E: そのステップだけ
// 36〜108 秒・以降は 100〜300ms)。だから暖機は executor を作った時点で始める。
// **ただしガードが効かない run では撃たない** —— 使いもしない Vision を読ませない。

import Foundation
import XCTest
@testable import FTCore

final class StepExecutorPrewarmTests: XCTestCase {

    func testPrewarmsWhenTheGuardIsOnByDefault() {
        let before = RegionText.prewarmRequestCount
        _ = StepExecutor(driver: SilentDriver(), occlusionGuard: true,
                         occlusionOCRMode: .on, occlusionGuardEnabled: true, isAndroid: false)
        XCTAssertEqual(RegionText.prewarmRequestCount, before + 1,
                       "ガードが効く executor で暖機を始めていない")
    }

    /// マスタースイッチ(実行プロファイルの falsePositiveCheck)が off の run では撃たない
    func testDoesNotPrewarmWhenTheMasterSwitchIsOff() {
        let before = RegionText.prewarmRequestCount
        _ = StepExecutor(driver: SilentDriver(), occlusionGuard: true,
                         occlusionOCRMode: .on, occlusionGuardEnabled: false, isAndroid: false)
        XCTAssertEqual(RegionText.prewarmRequestCount, before)
    }

    /// executor 既定でガードが効かない run でも撃たない(ステップ指定で立つ稀な場合は
    /// 予算つきの OCR 段が面倒を見る。RegionText.occlusionBudget)
    func testDoesNotPrewarmWhenTheGuardIsOffByDefault() {
        let before = RegionText.prewarmRequestCount
        _ = StepExecutor(driver: SilentDriver(), occlusionGuard: false,
                         occlusionOCRMode: .on, occlusionGuardEnabled: true, isAndroid: false)
        XCTAssertEqual(RegionText.prewarmRequestCount, before)
    }

    /// OCR の殺しスイッチ(FT_OCCLUSION_OCR=0)が効いていれば Vision に触らない
    func testDoesNotPrewarmWhenOCRIsOff() {
        let before = RegionText.prewarmRequestCount
        _ = StepExecutor(driver: SilentDriver(), occlusionGuard: true,
                         occlusionOCRMode: .off, occlusionGuardEnabled: true, isAndroid: false)
        XCTAssertEqual(RegionText.prewarmRequestCount, before)
    }
}

/// 何もしないドライバ(この検証は executor を**作る**ところだけを見るので、実行はしない)
private final class SilentDriver: AppDriver {
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 100, height: 100),
                         elements: [], truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// 近道(OCR)を撃つかの判定。**モデルが載るまでは撃たない** —— 撃つと 1 ステップにつき
/// 予算(RegionText.occlusionBudget)を丸ごと捨てるだけで、判定は結局 FM が下す
final class OCRShortcutGateTests: XCTestCase {

    func testTakesTheShortcutOnlyWhenTheModelIsWarm() {
        XCTAssertTrue(RegionText.shouldTakeShortcut(mode: .on, warm: true, abandonedInFlight: 0))
        XCTAssertFalse(RegionText.shouldTakeShortcut(mode: .on, warm: false, abandonedInFlight: 0),
                       "モデルが載っていないのに近道を撃っている")
    }

    /// 殺しスイッチ(FT_OCCLUSION_OCR=0)は暖まっていても撃たない
    func testKillSwitchWinsOverWarm() {
        XCTAssertFalse(RegionText.shouldTakeShortcut(mode: .off, warm: true, abandonedInFlight: 0))
    }

    /// コーパス採取(measure)は暖まっていれば撃つ(採るのが目的)
    func testMeasureModeTakesTheShortcutWhenWarm() {
        XCTAssertTrue(RegionText.shouldTakeShortcut(mode: .measure, warm: true, abandonedInFlight: 0))
        XCTAssertFalse(RegionText.shouldTakeShortcut(mode: .measure, warm: false, abandonedInFlight: 0))
    }

    /// **諦めた読みが走っている間は撃たない**(積み増すと全部予算切れになる。shouldTakeShortcut の doc)
    func testDoesNotPileUpBehindAnAbandonedRead() {
        XCTAssertFalse(RegionText.shouldTakeShortcut(mode: .on, warm: true, abandonedInFlight: 1),
                       "詰まった読みの後ろに新しい読みを積んでいる")
        XCTAssertTrue(RegionText.shouldTakeShortcut(mode: .on, warm: true, abandonedInFlight: 0))
    }
}

/// 暖機の探りの結果から warm と言ってよいかの判定(`RegionText.warmedUp`)。
/// **読めなかった回を warm と言うと**、劣化した Vision に対して近道を撃ち続け、
/// ステップごとに予算を捨てることになる
final class RegionTextWarmVerdictTests: XCTestCase {

    func testWarmOnlyWhenTheProbeActuallyRead() {
        XCTAssertTrue(RegionText.warmedUp(probe: ["ログイン"]))
        // **呼び出しが成功しても 1 行も返らない**状態が実在する(RegionText.warmedUp の doc)
        XCTAssertFalse(RegionText.warmedUp(probe: []), "1行も読めていないのに warm と言っている")
        XCTAssertFalse(RegionText.warmedUp(probe: nil), "読めていないのに warm と言っている")
    }
}

/// 差し替え口(`warmOverrideForTesting`)だけになると「暖機を一度も通らない」変更が
/// 緑のまま通るので、**production の既定**をここで固定する
final class RegionTextWarmDefaultTests: XCTestCase {

    func testWarmOverrideIsNotSetInProduction() {
        XCTAssertNil(RegionText.warmOverrideForTesting,
                     "差し替え口が残っている(テストが後始末していない)")
    }
}

/// 諦めた読みの本数(`abandonedInFlight`)は**諦めた瞬間に増え、その読みが戻ったら減る**。
/// 戻しを忘れると近道が永久に閉じ、増やし忘れると積み増しが止まらない
final class RegionTextAbandonedInFlightTests: XCTestCase {

    func testCountsTheAbandonedReadUntilItFinishes() async throws {
        // 予算 0 で撃つと必ず諦める(Vision の呼び出しは 0ms では返らない)
        let png = try XCTUnwrap(Self.tinyTextPNG())
        let rect = FTRect(x: 0, y: 0, width: 120, height: 40)
        let before = RegionText.abandonedInFlight
        let outcome = await RegionText.resolveWithinBudget(expected: "fleetest", pngData: png,
                                                           frame: rect, screen: rect,
                                                           budget: .zero)
        guard case .budgetExhausted = outcome else { return XCTFail("予算 0 なのに諦めていない") }
        XCTAssertEqual(RegionText.abandonedInFlight, before + 1, "諦めた読みを数えていない")
        // 読みは走り続けて戻る(健全な Vision なら 1 秒以内)
        for _ in 0..<100 {
            if RegionText.abandonedInFlight == before { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(RegionText.abandonedInFlight, before, "戻った読みを引いていない(近道が永久に閉じる)")
    }

    private static func tinyTextPNG() -> Data? {
        let w = 120, h = 40
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let a = NSAttributedString(string: "fleetest", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
        ctx.textPosition = CGPoint(x: 4, y: 10); CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, img, nil); guard CGImageDestinationFinalize(d) else { return nil }
        return out as Data
    }
}
