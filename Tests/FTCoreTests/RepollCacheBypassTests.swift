// 待つ間の 2 回目以降の読みでキャッシュを迂回する(StepExecutor.repollBypassesCache)。
// Android の Compose は新しく出たノードを a11y のキャッシュへ 800ms 以上出さないので、素取得の
// ポーリングは出現の検出が 1 周期遅れる。1 回目の読み(ふだんの経路)では払わないことも守る。

import XCTest
@testable import FTCore

final class RepollCacheBypassTests: XCTestCase {

    /// 素取得は何回読んでも古い木、迂回したときだけ今の木を返す(Android の実挙動の形)
    private final class StaleCacheDriver: AppDriver {
        let stale: [ElementInfo]
        let fresh: [ElementInfo]
        private(set) var reads: [Bool] = []   // 各読みで迂回したか
        private(set) var tappedRefs: [Int] = []
        init(stale: [ElementInfo], fresh: [ElementInfo]) {
            self.stale = stale
            self.fresh = fresh
        }
        var supportsCacheBypass: Bool { true }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse { try await snapshot(bypassingCache: false) }
        func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
            reads.append(bypassingCache)
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: bypassingCache ? fresh : stale,
                                    truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tappedRefs.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func target() -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: "txt_delayed", label: "遅延表示 完了", value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: 20, y: 300, width: 200, height: 48),
                    depth: 1)
    }

    private func isPassed(_ status: StepResult.Status) -> Bool {
        if case .passed = status { return true }
        if case .passedViaFallback = status { return true }
        return false
    }

    func testOnlySelfRenderedAndroidAppsBypassOnRepoll() {
        XCTAssertTrue(StepExecutor.repollBypassesCache(isAndroid: true, app: .compose))
        XCTAssertTrue(StepExecutor.repollBypassesCache(isAndroid: true, app: .flutter))
        XCTAssertFalse(StepExecutor.repollBypassesCache(isAndroid: true, app: .androidView))
        XCTAssertFalse(StepExecutor.repollBypassesCache(isAndroid: true, app: .reactNative))
        XCTAssertFalse(StepExecutor.repollBypassesCache(isAndroid: true, app: nil), "不明は迂回しない")
        XCTAssertFalse(StepExecutor.repollBypassesCache(isAndroid: false, app: .compose), "iOS は対象外")
    }

    func testFreshRetryBypassesFromTheSecondReadOnly() {
        var on = AssertFreshRetry(bypassOnRepoll: true)
        XCTAssertEqual([on.takeArmed(), on.takeArmed(), on.takeArmed()], [false, true, true],
                       "1 回目の読みは払わない")
        var off = AssertFreshRetry(bypassOnRepoll: false)
        XCTAssertEqual([off.takeArmed(), off.takeArmed()], [false, false])
    }

    /// Compose の Android: 1 回目は古い木で見つからず、2 回目(迂回)で見つかる
    func testExistOnComposeAndroidFindsTheElementOnTheSecondRead() async {
        let driver = StaleCacheDriver(stale: [], fresh: [target()])
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "txt_delayed"),
                            timeout: 5, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: true, uiFramework: .compose).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        XCTAssertEqual(driver.reads, [false, true], "2 回目の読みで迂回して見つける")
    }

    /// 対照: View/XML では従来どおり、期限切れ直前の 1 回(AssertFreshRetry.arm)まで迂回しない
    func testExistOnAndroidViewKeepsReadingTheCacheUntilTheDeadline() async {
        let driver = StaleCacheDriver(stale: [], fresh: [target()])
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "txt_delayed"),
                            timeout: 0.5, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: true, uiFramework: .androidView).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "期限切れ直前の取り直しで見つかる: \(outcome.status)")
        XCTAssertGreaterThan(driver.reads.filter { !$0 }.count, 1, "素取得を繰り返してから")
        XCTAssertEqual(driver.reads.last, true)
        XCTAssertEqual(driver.reads.filter { $0 }.count, 1)
    }

    /// シナリオ実行の Android の分岐が uiFrameworkHint を決めていること。上のテストは uiFramework を
    /// 直接渡すので、実行バイナリの配線が抜けていても緑のまま(2026-09-18 に実際にそうなっていた =
    /// Android では常に nil で迂回が黙って効かず、E2E の待ちは 1 秒遅いまま)
    func testScenarioRunnerDeterminesTheFrameworkOnAndroid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/FTScenarioRunner/ScenarioRunnerMain.swift"), encoding: .utf8)
        guard let start = text.range(of: "case \"android\":"),
              let end = text.range(of: "default:", range: start.upperBound..<text.endIndex) else {
            return XCTFail("ScenarioRunnerMain の Android の分岐が見つかりません")
        }
        XCTAssertTrue(text[start.lowerBound..<end.lowerBound]
                        .contains("uiFrameworkHint = AppUIFrameworkQuery.staticAnswer(for: uiFrameworkSubject)"),
                      "Android の分岐が uiFrameworkHint を決めていない(repollBypassesCache が常に false になる)")
    }

    /// 操作側の待ち(tap が要素の出現を待つ)も同じく 2 回目の読みで迂回する
    func testTapOnComposeAndroidResolvesOnTheSecondRead() async {
        let driver = StaleCacheDriver(stale: [], fresh: [target()])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "txt_delayed"), timeout: 5)
        let outcome = await StepExecutor(driver: driver, isAndroid: true, uiFramework: .compose).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "\(outcome.status)")
        XCTAssertEqual(driver.tappedRefs, [1])
        XCTAssertEqual(driver.reads.first, false, "1 回目の読みは払わない")
        XCTAssertTrue(driver.reads.dropFirst().contains(true), "待ちの読み直しで迂回していない: \(driver.reads)")
    }
}
