// ステップ単位の要素上限ラッチ(2026-08-15)。
//
// AppDriver.raiseElementLimitOnNextSnapshot は次の1回だけ上限を上げる one-shot。
// retakenAtElementLimitCeiling(StepExecutor+Assert.swift)が発火した後、同じステップの
// 後続読み(freshSnapshot / readback ヘルパの直呼び)が既定上限へ戻ると、天井でしか出ない対象が
// また落ちて黙って素通り・別の物へのタップ・検証不能への退化につながる。
// StepExecutor.elementLimitCeilingLatchedThisStep がこれを塞ぐ: 発火したらステップの残りの
// 読みすべてで毎回 arm し直し、次のステップには持ち越さない。

import XCTest
@testable import FTCore

final class ActionCeilingLatchTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    // MARK: - 1. freshSnapshot は one-shot を毎回 arm し直す

    func testFreshSnapshotArmsTheCeilingEveryTimeWhileLatched() async throws {
        let driver = RecordingDriver(screen: screen)
        let executor = StepExecutor(driver: driver)
        executor.elementLimitCeilingLatchedThisStep = true

        _ = try await executor.freshSnapshot(.afterOwnMove)
        _ = try await executor.freshSnapshot(.afterOwnMove)

        let expected: [Int?] = [BridgeAPI.maxSnapshotElementsCeiling, BridgeAPI.maxSnapshotElementsCeiling]
        XCTAssertEqual(driver.armCalls, expected,
                       "one-shot なので、立っている間は呼ぶたびに arm し直すはず: \(driver.armCalls)")
    }

    func testFreshSnapshotDoesNotArmWhenNotLatched() async throws {
        let driver = RecordingDriver(screen: screen)
        let executor = StepExecutor(driver: driver)

        _ = try await executor.freshSnapshot(.afterOwnMove)

        XCTAssertTrue(driver.armCalls.isEmpty, "ラッチが立っていないのに天井を要求した: \(driver.armCalls)")
    }

    // MARK: - 2. swipeElementToElement: 終点も撮り直し対象になる(始点だけの非対称を埋める)

    /// 現行では始点(529 行付近)だけ救済され、終点は truncatedCount>0 でも即 failed になっていた
    /// (= このテストを書いた時点で壊すと "cannot resolve the end locator" で落ちる)
    func testSwipeElementToElementRetakesTheEndLocatorAtTheCeiling() async throws {
        let driver = SwipeEndCeilingDriver(screen: screen)
        let step = FlowStep(action: "swipeElementToElement", locator: FlowLocator(id: "start"),
                            endLocator: FlowLocator(id: "end"), timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "上限で間引かれた終点を解決できないと報告した: \(outcome.status)")
        XCTAssertTrue(driver.armCalls.contains(BridgeAPI.maxSnapshotElementsCeiling),
                      "終点の撮り直しで天井を要求していない: \(driver.armCalls)")
        XCTAssertEqual(driver.draggedFromID, "start")
        XCTAssertEqual(driver.draggedToID, "end")
    }

    // MARK: - 3. ラッチはステップを跨いで残らない

    func testLatchDoesNotCarryOverToTheNextStep() async throws {
        let driver = TwoStepLatchDriver(screen: screen)
        let executor = StepExecutor(driver: driver)

        // ステップ1: target1 は既定上限で切り詰められている → ラッチが立って天井で救済される
        let step1 = FlowStep(action: "tap", locator: FlowLocator(id: "target1"),
                             timeout: 0, occlusionGuard: false)
        let outcome1 = await executor.execute(step1)
        XCTAssertTrue(StepExecutor.isSuccess(outcome1.status), "\(outcome1.status)")
        let armCallsAfterStep1 = driver.armCalls.count
        XCTAssertGreaterThan(armCallsAfterStep1, 0, "ステップ1で天井を要求していない")

        // ステップ2: target2 は既定上限でも最初から実在する → 撮り直し不要のはず。
        // ラッチはステップ1の実行中に立ったまま(reset は次の execute() の入口で行われる)なので、
        // ここで新たな arm が起きないことこそが「ステップを跨いで残らない」ことの検証になる
        // (もし reset が効いていなければ、target2 の解決自体は既定上限でも成功するため見た目は
        // 変わらないが、freshSnapshot が毎回 arm してしまい件数が増える)
        let step2 = FlowStep(action: "tap", locator: FlowLocator(id: "target2"),
                             timeout: 0, occlusionGuard: false)
        let outcome2 = await executor.execute(step2)
        XCTAssertTrue(StepExecutor.isSuccess(outcome2.status), "\(outcome2.status)")
        XCTAssertEqual(driver.armCalls.count, armCallsAfterStep1,
                       "次のステップへラッチが持ち越され、不要な天井要求が起きた: \(driver.armCalls)")
    }

    // MARK: - 4. tap のリトライ/ghost 救済ループは、切り詰めの撮り直しを最初の解決ミスの
    //            周回で行う(既定上限のスナップショットでループ全予算を空撃ちしてから
    //            ループ後にようやく天井へ当たる、を禁止する)

    /// 対象は既定上限の木には無く(truncatedCount>0)、天井の木にだけ現れる。timeout を
    /// 指定しない(= 既定のリトライ変種、最大3周)ので、早期撮り直しを外すと3周とも
    /// 既定上限の読みを払ってからループ後の1回でようやく成功する形が再現できる。
    /// (このテストを書いた時点で早期撮り直しを外すと unarmedSnapshotCount が 1 を超えて落ちる)
    func testTapRetakesAtCeilingOnFirstMissInsteadOfBurningRetryBudget() async throws {
        let driver = TruncatedUntilCeilingDriver(screen: screen)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status),
                      "天井でしか出ない対象を解決できないと報告した: \(outcome.status)")
        XCTAssertEqual(driver.unarmedSnapshotCount, 1,
                       "リトライの予算を、当たるはずのない既定上限のスナップショットで空撃ちした: "
                       + "\(driver.unarmedSnapshotCount) 回")
    }

    // MARK: - 5. 切り詰めが無い通常の tap では天井を一度も要求しない(退行なし)

    func testOrdinaryTapNeverArmsTheCeiling() async throws {
        let driver = UntruncatedTapDriver(screen: screen)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertTrue(driver.armCalls.isEmpty, "切り詰めが無いのに天井を要求した: \(driver.armCalls)")
    }
}

/// arm 呼び出しをそのまま記録するだけの最小ドライバ(1のテスト用)。
private final class RecordingDriver: AppDriver {
    private(set) var armCalls: [Int?] = []
    private let screen: FTRect
    init(screen: FTRect) { self.screen = screen }

    func raiseElementLimitOnNextSnapshot(_ max: Int?) { armCalls.append(max) }

    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0)
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

/// **始点は既定上限でも実在し、終点だけ切り詰められている**木を返すドライバ(2のテスト用)。
/// 天井を要求されたときだけ両方を含む木を返す(one-shot: 消費したら次回はまた既定へ戻る)
private final class SwipeEndCeilingDriver: AppDriver {
    private(set) var armCalls: [Int?] = []
    private(set) var draggedFromID: String?
    private(set) var draggedToID: String?
    private var ceilingRequested = false
    private let screen: FTRect
    init(screen: FTRect) { self.screen = screen }

    private let start = ElementInfo(ref: 1, type: "cell", identifier: "start", label: nil, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 10, y: 50, width: 100, height: 40), depth: 1)
    private let end = ElementInfo(ref: 99, type: "cell", identifier: "end", label: nil, value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 10, y: 400, width: 100, height: 40), depth: 1)
    private func filler() -> [ElementInfo] {
        (0..<3).map { index in
            ElementInfo(ref: index + 10, type: "staticText", identifier: "filler\(index)", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index) * 10, width: 10, height: 10), depth: 1)
        }
    }

    func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        armCalls.append(max)
        ceilingRequested = (max ?? 0) >= BridgeAPI.maxSnapshotElementsCeiling
    }

    func snapshot() async throws -> SnapshotResponse {
        guard ceilingRequested else {
            return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [start] + filler(),
                                    truncatedCount: 40)
        }
        ceilingRequested = false   // one-shot: 消費したら戻す(実ブリッジと同じ挙動)
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [start, end] + filler(),
                                truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
             pressSeconds: Double, durationSeconds: Double) async throws {
        draggedFromID = abs(fromY - start.frame.centerY) < 1 ? "start" : nil
        draggedToID = abs(toY - end.frame.centerY) < 1 ? "end" : nil
    }
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

/// **target は既定上限の木には無く、天井を要求されたときだけ現れる**木を返すドライバ(4のテスト用)。
/// `unarmedSnapshotCount` が「既定上限で撮った回数」の証拠(1を超えたらリトライ予算の空撃ち)
private final class TruncatedUntilCeilingDriver: AppDriver {
    private(set) var armCalls: [Int?] = []
    private(set) var unarmedSnapshotCount = 0
    private var ceilingRequested = false
    private let screen: FTRect
    init(screen: FTRect) { self.screen = screen }

    private let target = ElementInfo(ref: 99, type: "button", identifier: "target", label: nil,
                                     value: nil, placeholder: nil, enabled: true,
                                     frame: FTRect(x: 10, y: 400, width: 100, height: 40), depth: 1)
    private func filler() -> [ElementInfo] {
        (0..<3).map { index in
            ElementInfo(ref: index + 10, type: "staticText", identifier: "filler\(index)", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index) * 10, width: 10, height: 10), depth: 1)
        }
    }

    func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        armCalls.append(max)
        ceilingRequested = (max ?? 0) >= BridgeAPI.maxSnapshotElementsCeiling
    }

    func snapshot() async throws -> SnapshotResponse {
        guard ceilingRequested else {
            unarmedSnapshotCount += 1
            return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: filler(),
                                    truncatedCount: 40)
        }
        ceilingRequested = false   // one-shot: 消費したら戻す(実ブリッジと同じ挙動)
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: filler() + [target],
                                truncatedCount: 0)
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

/// target が既定上限の木に最初から実在する(truncatedCount=0)ドライバ(5のテスト用:
/// 撮り直しが一度も起きないことの確認)
private final class UntruncatedTapDriver: AppDriver {
    private(set) var armCalls: [Int?] = []
    private let screen: FTRect
    private let target = ElementInfo(ref: 1, type: "button", identifier: "target", label: nil,
                                     value: nil, placeholder: nil, enabled: true,
                                     frame: FTRect(x: 10, y: 50, width: 100, height: 40), depth: 1)
    init(screen: FTRect) { self.screen = screen }

    func raiseElementLimitOnNextSnapshot(_ max: Int?) { armCalls.append(max) }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [target], truncatedCount: 0)
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

/// **1ステップ目は切り詰めで target1 が落ちている、2ステップ目は target2 が最初から実在する**木を
/// 返すドライバ(3のテスト用)。同じインスタンスを2回の execute() にまたがせて使う
private final class TwoStepLatchDriver: AppDriver {
    private(set) var armCalls: [Int?] = []
    private var ceilingRequested = false
    private let screen: FTRect
    init(screen: FTRect) { self.screen = screen }

    private func filler() -> [ElementInfo] {
        (0..<3).map { index in
            ElementInfo(ref: index + 10, type: "staticText", identifier: "filler\(index)", label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index) * 10, width: 10, height: 10), depth: 1)
        }
    }
    private let target1 = ElementInfo(ref: 99, type: "button", identifier: "target1", label: "一",
                                      value: nil, placeholder: nil, enabled: true,
                                      frame: FTRect(x: 10, y: 200, width: 100, height: 40), depth: 1)
    private let target2 = ElementInfo(ref: 50, type: "button", identifier: "target2", label: "二",
                                      value: nil, placeholder: nil, enabled: true,
                                      frame: FTRect(x: 10, y: 300, width: 100, height: 40), depth: 1)

    func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        armCalls.append(max)
        ceilingRequested = (max ?? 0) >= BridgeAPI.maxSnapshotElementsCeiling
    }

    func snapshot() async throws -> SnapshotResponse {
        // target2 は切り詰めに関わらず常に実在(2ステップ目が撮り直しを要らないことの確認用)。
        // target1 は天井を要求したときだけ現れる
        guard ceilingRequested else {
            return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                    elements: filler() + [target2], truncatedCount: 40)
        }
        ceilingRequested = false   // one-shot
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: filler() + [target1, target2], truncatedCount: 0)
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
