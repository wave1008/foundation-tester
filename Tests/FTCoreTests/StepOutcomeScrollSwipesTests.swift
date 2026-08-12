// StepOutcome.scrollSwipes(runScrollSearch が撃った実スワイプ数を成功時の StepOutcome へ載せる)
// を固定する。MCP の ft_scroll_to が所要時間の内訳(swipe 数)にそのまま使うため、
// action 経路・assert 経路のどちらでも同じ値が載ることを確認する。

import XCTest
@testable import FTCore

/// snapshot() 呼び出しごとに台本の次の木を返す最小ドライバ(尽きたら最後を繰り返す)。
/// swipe/swipe(intent:path:) の両方を数える(runScrollSearch はドライバ能力次第でどちらか
/// を撃つため、どちらでも取りこぼさない)
private final class ScriptedSwipeDriver: AppDriver {
    private let scripted: [[ElementInfo]]
    private var index = 0
    private(set) var swipeCount = 0

    init(scripted: [[ElementInfo]]) { self.scripted = scripted }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipeCount += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipeCount += 1
    }
    func snapshot() async throws -> SnapshotResponse {
        let elements = scripted[min(index, scripted.count - 1)]
        index += 1
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class StepOutcomeScrollSwipesTests: XCTestCase {

    private func row(ref: Int, id: String, y: Double = 300) -> ElementInfo {
        ElementInfo(ref: ref, type: "clickable", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 1)
    }

    /// 初回照会で見つかれば `runScrollSearch` は1本も振らない ——
    /// **scrollSwipes は nil ではなく 0**(「探索はしたが振らずに済んだ」と「探索していない」を
    /// 区別する。scrollTimingNote は nil を「振っていない」と等価に扱ってよいが、区別自体は
    /// ここで確定させておく)
    func testScrollSwipesIsZeroWhenFoundOnFirstLook() async throws {
        let driver = ScriptedSwipeDriver(scripted: [[row(ref: 1, id: "target")]])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"), maxSwipes: 8)

        let outcome = await StepExecutor(driver: driver).execute(step)

        guard case .passed = outcome.status else {
            return XCTFail("初回照会で見つかるはずなので pass: \(outcome.status)")
        }
        XCTAssertEqual(outcome.scrollSwipes, 0,
                       "初回発見なのに scrollSwipes が 0 でない: \(String(describing: outcome.scrollSwipes))")
        XCTAssertEqual(driver.swipeCount, 0)
    }

    /// 1本振った後に見つかるケース。**scrollSwipes は実際に撃った本数と一致する**こと
    /// (台本は testEmptyDragFallsBackToTypeDriverWhenEngineIncapable と同型:
    /// 空の2枚で静止確認 → スワイプ → 3枚目で発見)
    func testScrollSwipesCountsActualSwipesAfterSearching() async throws {
        let driver = ScriptedSwipeDriver(scripted: [[], [], [row(ref: 1, id: "target")]])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"), maxSwipes: 8)

        let outcome = await StepExecutor(driver: driver, releasesScrollTouch: true).execute(step)

        guard case .passed = outcome.status else {
            return XCTFail("スワイプ後に見つかるはずなので pass: \(outcome.status)")
        }
        XCTAssertEqual(outcome.scrollSwipes, driver.swipeCount,
                       "StepOutcome.scrollSwipes が実際のスワイプ回数と食い違う")
        XCTAssertEqual(outcome.scrollSwipes, 1)
    }

    /// **assert 経路でも同じ受け渡し形**(exist(direction:) の内蔵探索)。action 経路だけの
    /// 特別扱いになっていないかを確認する(StepExecutor+Assert.swift の executeAssertExists も
    /// recordedScrollSearchNote を通る)
    func testScrollSwipesIsPopulatedOnTheAssertPathToo() async throws {
        let driver = ScriptedSwipeDriver(scripted: [[], [], [row(ref: 1, id: "target")]])
        var step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"))
        step.direction = "up"
        step.maxSwipes = 8

        let outcome = await StepExecutor(driver: driver, releasesScrollTouch: true).execute(step)

        guard case .passed = outcome.status else {
            return XCTFail("スワイプ後に見つかるはずなので pass: \(outcome.status)")
        }
        XCTAssertEqual(outcome.scrollSwipes, driver.swipeCount)
        XCTAssertNotNil(outcome.scrollSwipes, "assert 経路では scrollSwipes が載らない")
    }

    /// スクロール探索を経由しないステップ(内蔵探索を使わない単純な tap)は
    /// scrollSwipes が nil のまま(=「探索していない」を偽の 0 と混同しない)
    func testScrollSwipesStaysNilForStepsWithoutScrollSearch() async throws {
        let driver = ScriptedSwipeDriver(scripted: [[row(ref: 1, id: "target")]])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"))

        let outcome = await StepExecutor(driver: driver).execute(step)

        guard case .passed = outcome.status else {
            return XCTFail("tap は見つかるはずなので pass: \(outcome.status)")
        }
        XCTAssertNil(outcome.scrollSwipes,
                     "スクロール探索を経由していないのに scrollSwipes が埋まっている")
    }

    /// **リセット漏れの検出**: 同じ executor インスタンスで scrollTo の次に scroll 探索を
    /// 使わないステップを実行すると、前ステップの scrollSwipes を持ち越さず nil に戻ること
    /// (execute(_:cached:) 冒頭の `scrollSwipesThisStep = nil` の契約)
    func testScrollSwipesResetsBetweenStepsOnTheSameExecutor() async throws {
        let driver = ScriptedSwipeDriver(scripted: [[], [], [row(ref: 1, id: "target")]])
        let executor = StepExecutor(driver: driver, releasesScrollTouch: true)

        let first = await executor.execute(
            FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"), maxSwipes: 8))
        guard case .passed = first.status else {
            return XCTFail("1ステップ目はスワイプ後に見つかるはず: \(first.status)")
        }
        XCTAssertEqual(first.scrollSwipes, 1)

        let second = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        guard case .passed = second.status else {
            return XCTFail("2ステップ目の tap は見つかるはず: \(second.status)")
        }
        XCTAssertNil(second.scrollSwipes,
                     "前ステップ(scrollTo)の scrollSwipes が持ち越されている(リセット漏れ)")
    }
}
