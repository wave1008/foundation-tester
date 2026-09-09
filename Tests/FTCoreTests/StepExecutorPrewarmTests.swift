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
