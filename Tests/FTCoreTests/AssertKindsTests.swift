import XCTest
@testable import FTCore

/// notExists / enabled / disabled / count の実行セマンティクス(StepExecutor.executeAssert)。
/// snapshot はスクリプト可能で、ポーリングによる状態変化の追従も検証する。
final class AssertKindsTests: XCTestCase {

    /// snapshot() 呼び出し回数ごとに要素列を差し替えるドライバ(列を使い切ったら最後を繰り返す)
    private final class ScriptedDriver: AppDriver {
        var frames: [[ElementInfo]]
        private(set) var snapshotCallCount = 0
        init(frames: [[ElementInfo]]) { self.frames = frames }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            snapshotCallCount += 1
            let index = min(snapshotCallCount - 1, max(0, frames.count - 1))
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: frames.isEmpty ? [] : frames[index],
                                    truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func node(_ ref: Int, type: String = "button", id: String? = nil,
                      label: String? = nil, enabled: Bool = true, depth: Int = 1,
                      checked: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: depth,
                    checked: checked)
    }

    private func isPassed(_ status: StepResult.Status) -> Bool {
        if case .passed = status { return true }
        if case .passedViaFallback = status { return true }
        return false
    }

    private func failureReason(_ status: StepResult.Status) -> String? {
        if case .failed(let reason) = status { return reason }
        return nil
    }

    // MARK: - notExists

    func testNotExistPassesImmediatelyWhenAbsent() async {
        let driver = ScriptedDriver(frames: [[node(1, id: "other")]])
        let executor = StepExecutor(driver: driver)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "dialog"), timeout: 5)
        let outcome = await executor.execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        // 不在なら初回の 1 回で確定する(タイムアウトまで待たない)
        XCTAssertEqual(driver.snapshotCallCount, 1)
    }

    func testNotExistWaitsUntilElementDisappears() async {
        let driver = ScriptedDriver(frames: [
            [node(1, id: "dialog")],
            [node(1, id: "dialog")],
            [node(2, id: "other")],
        ])
        let executor = StepExecutor(driver: driver)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "dialog"), timeout: 5)
        let outcome = await executor.execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.snapshotCallCount, 3)
    }

    func testNotExistFailsWhileStillPresent() async {
        let driver = ScriptedDriver(frames: [[node(1, id: "dialog")]])
        let executor = StepExecutor(driver: driver)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "dialog"), timeout: 0)
        let outcome = await executor.execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("まだ存在します"), true)
    }

    func testNotExistConfirmsAbsenceWithFallbackDriver() async {
        // primary(アプリ内)には無いがシステム UI 側に居る = まだ閉じていない
        let primary = ScriptedDriver(frames: [[node(1, id: "other")]])
        let fallback = ScriptedDriver(frames: [[node(9, label: "許可")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(label: "許可"), timeout: 0)
        let outcome = await executor.execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("システム UI"), true)
    }

    // MARK: - textContains / textMatches

    func testTextContainsAndMatches() async {
        let frames = [[node(1, type: "staticText", id: "total", label: "合計 1,200円")]]
        func run(_ assert: String, _ expected: String) async -> Bool {
            let step = FlowStep(assert: assert, locator: FlowLocator(id: "total"),
                                expected: expected, timeout: 0, occlusionGuard: false)
            let outcome = await StepExecutor(driver: ScriptedDriver(frames: frames)).execute(step)
            return isPassed(outcome.status)
        }
        let containsHit = await run("textContains", "1,200")
        XCTAssertTrue(containsHit)
        let containsMiss = await run("textContains", "1,300")
        XCTAssertFalse(containsMiss)
        // 部分一致の正規表現(全体一致にしたいときは ^...$ を書く契約)
        let regexHit = await run("textMatches", "合計 [0-9,]+円")
        XCTAssertTrue(regexHit)
        let anchoredHit = await run("textMatches", "^合計")
        XCTAssertTrue(anchoredHit)
        let anchoredMiss = await run("textMatches", "^1,200")
        XCTAssertFalse(anchoredMiss)
    }

    /// 惜しい候補を失敗メッセージに添える(直すための往復を1回減らす)
    func testUnresolvedLocatorSuggestsNearbyCandidates() async {
        let frames = [[node(1, type: "button", id: "btn_submit", label: "送信")]]
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_submitt"), timeout: 0)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: frames)).execute(step)
        if case .failed(let reason) = outcome.status {
            XCTAssertTrue(reason.contains("近い候補"), reason)
            XCTAssertTrue(reason.contains("btn_submit"), reason)
        } else {
            XCTFail("失敗するはず")
        }
    }

    // MARK: - checked / notChecked

    /// ブリッジは checked を **true のときだけ送る**(省略 = オフ or 状態を持たない要素)。
    /// notChecked はその省略も「オフ」として通す = 状態の無い要素で失敗しない
    func testCheckedAndNotCheckedFollowOmittedFalseConvention() async {
        let on = [[node(1, id: "sw", checked: true)]]
        let off = [[node(1, id: "sw", checked: nil)]]
        let checkedOnOn = await StepExecutor(driver: ScriptedDriver(frames: on))
            .execute(FlowStep(assert: "checked", locator: FlowLocator(id: "sw"), timeout: 0))
        XCTAssertTrue(isPassed(checkedOnOn.status))
        let checkedOnOff = await StepExecutor(driver: ScriptedDriver(frames: off))
            .execute(FlowStep(assert: "checked", locator: FlowLocator(id: "sw"), timeout: 0))
        XCTAssertFalse(isPassed(checkedOnOff.status))
        let notCheckedOnOff = await StepExecutor(driver: ScriptedDriver(frames: off))
            .execute(FlowStep(assert: "notChecked", locator: FlowLocator(id: "sw"), timeout: 0))
        XCTAssertTrue(isPassed(notCheckedOnOff.status))
    }

    /// 「見つからない」と「状態が違う」を別メッセージにする(enabled と同じ規律)
    func testCheckedDistinguishesMissingFromOff() async {
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[node(1, id: "other")]]))
            .execute(FlowStep(assert: "checked", locator: FlowLocator(id: "sw"), timeout: 0))
        if case .failed(let reason) = outcome.status {
            XCTAssertTrue(reason.contains("見つかりません"), reason)
        } else {
            XCTFail("失敗するはず")
        }
    }

    // MARK: - enabled / disabled

    func testEnabledPassesAndDisabledFailsForEnabledElement() async {
        let frames = [[node(1, id: "send", enabled: true)]]
        let enabledOutcome = await StepExecutor(driver: ScriptedDriver(frames: frames))
            .execute(FlowStep(assert: "enabled", locator: FlowLocator(id: "send"), timeout: 0))
        XCTAssertTrue(isPassed(enabledOutcome.status))

        let disabledOutcome = await StepExecutor(driver: ScriptedDriver(frames: frames))
            .execute(FlowStep(assert: "disabled", locator: FlowLocator(id: "send"), timeout: 0))
        XCTAssertEqual(failureReason(disabledOutcome.status)?.contains("要素は有効です"), true)
    }

    func testEnabledWaitsForStateChange() async {
        let driver = ScriptedDriver(frames: [
            [node(1, id: "send", enabled: false)],
            [node(1, id: "send", enabled: true)],
        ])
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(assert: "enabled", locator: FlowLocator(id: "send"), timeout: 5))
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.snapshotCallCount, 2)
    }

    func testEnabledFailsWithNotFoundWhenMissing() async {
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[]]))
            .execute(FlowStep(assert: "enabled", locator: FlowLocator(id: "send"), timeout: 0))
        XCTAssertEqual(failureReason(outcome.status)?.contains("要素が見つかりません"), true)
    }

    // MARK: - count

    func testCountMatchesWithinScope() async {
        let elements = [
            node(0, type: "other", depth: 0),
            node(1, type: "other", id: "list", depth: 1),
            node(2, type: "clickable", depth: 2),
            node(3, type: "clickable", depth: 2),
            node(4, type: "clickable", depth: 1),   // list の外
        ]
        let scoped = FlowLocator(type: "clickable", scope: [FlowLocator(id: "list")])
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements]))
            .execute(FlowStep(assert: "count", locator: scoped, timeout: 0, expectedCount: 2))
        XCTAssertTrue(isPassed(outcome.status))
    }

    func testCountFailureReportsActual() async {
        let elements = [node(1, type: "clickable"), node(2, type: "clickable")]
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements]))
            .execute(FlowStep(assert: "count", locator: FlowLocator(type: "clickable"),
                              timeout: 0, expectedCount: 3))
        let reason = failureReason(outcome.status)
        XCTAssertEqual(reason?.contains("期待 3"), true)
        XCTAssertEqual(reason?.contains("実際 2"), true)
    }

    func testCountWaitsForListToFill() async {
        let driver = ScriptedDriver(frames: [
            [node(1, type: "clickable")],
            [node(1, type: "clickable"), node(2, type: "clickable")],
        ])
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(assert: "count", locator: FlowLocator(type: "clickable"),
                              timeout: 5, expectedCount: 2))
        XCTAssertTrue(isPassed(outcome.status))
    }

    func testCountWithoutExpectedCountIsSkipped() async {
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[]]))
            .execute(FlowStep(assert: "count", locator: FlowLocator(type: "clickable"), timeout: 0))
        if case .skipped = outcome.status {} else { XCTFail("skipped を期待: \(outcome.status)") }
    }
    func testCountUsesUnionOfClauses() async {
        // `||` は候補集合の和(Shirates 準拠)。全節を合わせて数える
        let elements = [node(1, type: "clickable", id: "row"), node(2, type: "row"), node(3, type: "row")]
        let step = FlowStep(assert: "count", locator: FlowLocator(type: "clickable"),
                            fallbacks: [FlowLocator(type: "row")], timeout: 0, expectedCount: 3)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(step)
        XCTAssertTrue(isPassed(outcome.status), ".clickable 1 件 + .row 2 件 = 3 件")
    }

    func testCountDeduplicatesElementMatchedByMultipleClauses() async {
        // 同じ要素が複数の節にマッチしても1度だけ数える(Shirates の filterBySelector と同じ)
        let elements = [node(1, type: "button", id: "save", label: "保存"), node(2, type: "button")]
        let step = FlowStep(assert: "count", locator: FlowLocator(id: "save"),
                            fallbacks: [FlowLocator(label: "保存")], timeout: 0, expectedCount: 1)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "#save と 保存 は同じ要素なので 1 件")
    }

    func testCountIncludesLaterClauseWhenPrimaryHasNoCandidate() async {
        let elements = [node(1, type: "row"), node(2, type: "row")]
        let step = FlowStep(assert: "count", locator: FlowLocator(type: "clickable"),
                            fallbacks: [FlowLocator(type: "row")], timeout: 0, expectedCount: 2)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(step)
        XCTAssertTrue(isPassed(outcome.status))
    }

    // MARK: - アサーションの対称化(前方/後方一致・否定・空判定)

    func testTextStartsWithAndEndsWith() async {
        let elements = [node(1, id: "msg", label: "合計 1,200 円")]
        for (assert, expected, shouldPass) in [
            ("textStartsWith", "合計", true), ("textStartsWith", "1,200", false),
            ("textEndsWith", "円", true), ("textEndsWith", "合計", false),
        ] as [(String, String, Bool)] {
            let step = FlowStep(assert: assert, locator: FlowLocator(id: "msg"),
                                expected: expected, timeout: 0, occlusionGuard: false)
            let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements]))
                .execute(step)
            XCTAssertEqual(isPassed(outcome.status), shouldPass, "\(assert) \(expected)")
        }
    }

    func testTextStartsWithFailureMessageNamesTheRelation() async {
        let step = FlowStep(assert: "textStartsWith", locator: FlowLocator(id: "msg"),
                            expected: "合計", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[node(1, id: "msg", label: "小計 500 円")]]))
            .execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("で始まりません"), true)
    }

    func testTextIsNotWaitsForValueToChange() async {
        let driver = ScriptedDriver(frames: [
            [node(1, id: "status", label: "処理中")],
            [node(1, id: "status", label: "完了")],
        ])
        let step = FlowStep(assert: "textNotEquals", locator: FlowLocator(id: "status"),
                            expected: "処理中", timeout: 5)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.snapshotCallCount, 2)
    }

    func testTextIsNotFailsWhileValueMatches() async {
        let step = FlowStep(assert: "textNotEquals", locator: FlowLocator(id: "status"),
                            expected: "処理中", timeout: 0)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[node(1, id: "status", label: "処理中")]]))
            .execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("一致しています"), true)
    }

    func testTextIsEmptyAndNotEmpty() async {
        let blank = [node(1, id: "input", label: "")]
        let filled = [node(1, id: "input", label: "太郎")]
        for (assert, elements, shouldPass) in [
            ("textIsEmpty", blank, true), ("textIsEmpty", filled, false),
            ("textIsNotEmpty", filled, true), ("textIsNotEmpty", blank, false),
        ] as [(String, [ElementInfo], Bool)] {
            let step = FlowStep(assert: assert, locator: FlowLocator(id: "input"), timeout: 0)
            let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements]))
                .execute(step)
            XCTAssertEqual(isPassed(outcome.status), shouldPass, assert)
        }
    }

    func testEmptyAssertionsDistinguishMissingElement() async {
        let step = FlowStep(assert: "textIsNotEmpty", locator: FlowLocator(id: "居ない"), timeout: 0)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[node(1, id: "other")]]))
            .execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("要素が見つかりません"), true)
    }

    /// tap(scroll:, optional: true) が伝える optional は scrollTo 経路でも同契約
    /// (見つからないときは失敗ではなくスキップ)
    func testScrollToHonoursOptional() async {
        let elements = [[node(1, id: "other")]]
        let optionalStep = FlowStep(action: "scrollTo", locator: FlowLocator(id: "居ない"),
                                    direction: "down", maxSwipes: 1, optional: true)
        let skipped = await StepExecutor(driver: ScriptedDriver(frames: elements))
            .execute(optionalStep)
        if case .skipped = skipped.status {} else { XCTFail("skipped を期待: \(skipped.status)") }
        let requiredStep = FlowStep(action: "scrollTo", locator: FlowLocator(id: "居ない"),
                                    direction: "down", maxSwipes: 1)
        let failed = await StepExecutor(driver: ScriptedDriver(frames: elements))
            .execute(requiredStep)
        XCTAssertEqual(failureReason(failed.status)?.contains("スクロールしても"), true)
    }

    // MARK: - スクロール探索の静止待ち

    /// フリングの慣性で動いている間は返さない(次のステップが別要素を掴むのを防ぐ)。
    /// frame が連続2回同じになったら静止とみなす
    func testScrollToWaitsUntilFoundElementStopsMoving() async {
        func row(_ y: Double) -> ElementInfo {
            ElementInfo(ref: 1, type: "button", identifier: "row_30", label: "行 30",
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: y, width: 100, height: 50), depth: 1)
        }
        // 1回目: 未発見 → スワイプ。2回目で発見(y=300)、その後 200 → 100 → 100(静止)
        let driver = ScriptedDriver(frames: [
            [node(9, id: "other")], [row(300)], [row(200)], [row(100)], [row(100)],
        ])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 5)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        // 発見(2回目)のあと、静止を確認するまで snapshot を追加で撮る
        XCTAssertEqual(driver.snapshotCallCount, 5)
    }

    /// スワイプせずに見つかったときは静止待ちを挟まない(既存の速度を落とさない)
    func testScrollToSkipsSettleWhenFoundWithoutSwiping() async {
        let driver = ScriptedDriver(frames: [[node(1, id: "row_30")]])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 5)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.snapshotCallCount, 1)
    }

    // MARK: - アプリ内メッセージに覆われたときの失敗メッセージ

    /// 同一プロセスのモーダル(アプリ内メッセージ)は別 window 検出では捕まらない。
    /// 幾何判定で「誰が覆っているか」を失敗メッセージに添える
    func testFailureMentionsCoveringInAppElement() async {
        // #txt_result(上)を、記載順で後 = 手前寄りの #promo_modal が全面的に覆う
        let target = ElementInfo(ref: 1, type: "staticText", identifier: "txt_result",
                                 label: "result=old", value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 100, width: 200, height: 40), depth: 1)
        let modal = ElementInfo(ref: 2, type: "other", identifier: "promo_modal",
                                label: "キャンペーンのお知らせ", value: nil, placeholder: nil,
                                enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 1)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_result"),
                            expected: "result=new", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[target, modal]]))
            .execute(step)
        let reason = failureReason(outcome.status)
        XCTAssertEqual(reason?.contains("#promo_modal"), true, reason ?? "")
        XCTAssertEqual(reason?.contains("覆われています"), true, reason ?? "")
    }

    /// 覆いが無ければ従来どおりのメッセージ(余計な文言を足さない)
    func testFailureHasNoCoveringHintWhenNothingOverlaps() async {
        let target = ElementInfo(ref: 1, type: "staticText", identifier: "txt_result",
                                 label: "result=old", value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 100, width: 200, height: 40), depth: 1)
        let other = ElementInfo(ref: 2, type: "staticText", identifier: "txt_other", label: "別",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 10, y: 400, width: 200, height: 40), depth: 1)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_result"),
                            expected: "result=new", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[target, other]]))
            .execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("覆われています"), false)
    }

    // MARK: - 割り込みハンドラ(アプリ内メッセージ)

    /// tap を記録するドライバ(どの ref が叩かれたかを検証する)
    private final class TapRecordingDriver: AppDriver {
        var frames: [[ElementInfo]]
        private(set) var snapshotCallCount = 0
        private(set) var tapped: [Int] = []
        init(frames: [[ElementInfo]]) { self.frames = frames }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            snapshotCallCount += 1
            let index = min(snapshotCallCount - 1, max(0, frames.count - 1))
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: frames.isEmpty ? [] : frames[index],
                                    truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tapped.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    /// 宣言した割り込みが出ていたら、本来の操作の前に閉じる。閉じたことは注記に残る
    func testInterruptHandlerDismissesBeforeActing() async {
        let modal = node(9, id: "promo_modal", label: "お知らせ")
        let close = node(8, id: "btn_promo_close", label: "閉じる")
        let target = node(1, id: "btn_submit", label: "送信")
        let driver = TapRecordingDriver(frames: [[modal, close, target], [target]])
        let executor = StepExecutor(driver: driver)
        executor.interruptHandlers = [
            .init(detect: FlowLocator(id: "promo_modal"), dismiss: FlowLocator(id: "btn_promo_close")),
        ]
        let outcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_submit")))
        XCTAssertTrue(isPassed(outcome.status))
        // 閉じる → 本来の対象、の順に叩く
        XCTAssertEqual(driver.tapped, [8, 1])
        XCTAssertEqual(outcome.driverFallback?.contains("割り込み"), true)
    }

    /// 宣言が無ければ何もしない(追加のスナップショットも取らない)
    func testNoInterruptHandlerMeansNoExtraWork() async {
        let target = node(1, id: "btn_submit")
        let driver = TapRecordingDriver(frames: [[target]])
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_submit")))
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.tapped, [1])
        XCTAssertEqual(driver.snapshotCallCount, 1)
        XCTAssertNil(outcome.driverFallback)
    }

    /// 宣言していても出ていなければ発火しない
    func testInterruptHandlerDoesNotFireWhenAbsent() async {
        let target = node(1, id: "btn_submit")
        let driver = TapRecordingDriver(frames: [[target]])
        let executor = StepExecutor(driver: driver)
        executor.interruptHandlers = [
            .init(detect: FlowLocator(id: "promo_modal"), dismiss: FlowLocator(id: "btn_promo_close")),
        ]
        let outcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_submit")))
        XCTAssertEqual(driver.tapped, [1])
        XCTAssertNil(outcome.driverFallback)
        XCTAssertTrue(isPassed(outcome.status))
    }

    /// 覆いで対象が解決できない形でも、閉じてから解決できる
    func testInterruptHandlerUnblocksResolution() async {
        let modal = node(9, id: "promo_modal", label: "お知らせ")
        let close = node(8, id: "btn_promo_close", label: "閉じる")
        let target = node(1, id: "btn_submit", label: "送信")
        // 1枚目に対象は居ない(モーダルが画面を占有)。閉じた後の2枚目で現れる
        let driver = TapRecordingDriver(frames: [[modal, close], [target]])
        let executor = StepExecutor(driver: driver)
        executor.interruptHandlers = [
            .init(detect: FlowLocator(id: "promo_modal"), dismiss: FlowLocator(id: "btn_promo_close")),
        ]
        let outcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_submit")))
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.tapped, [8, 1])
    }

    /// 否定・空判定の失敗にも覆いのヒントを添える(textEquals 系と同じ契約)
    func testNegativeAssertFailureMentionsCoveringElement() async {
        let target = ElementInfo(ref: 1, type: "staticText", identifier: "txt_status",
                                 label: "処理中", value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 100, width: 200, height: 40), depth: 1)
        let modal = ElementInfo(ref: 2, type: "other", identifier: "announce_modal",
                                label: "お知らせ", value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 1)
        let step = FlowStep(assert: "textNotEquals", locator: FlowLocator(id: "txt_status"),
                            expected: "処理中", timeout: 0)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[target, modal]]))
            .execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("#announce_modal"), true)
    }

    /// 複数宣言しても**1ステップで発火するのは最初に当たった1つだけ**
    /// (閉じても消えない相手で無限に回らないための契約)
    func testInterruptHandlersFireOncePerStepInDeclarationOrder() async {
        let first = node(9, id: "modal_a", label: "A")
        let second = node(8, id: "modal_b", label: "B")
        let target = node(1, id: "btn_submit", label: "送信")
        // 閉じても両方残り続ける画面(2枚目以降も同じ)= 何度でも発火し得る状況
        let driver = TapRecordingDriver(frames: [[first, second, target]])
        let executor = StepExecutor(driver: driver)
        executor.interruptHandlers = [
            .init(detect: FlowLocator(id: "modal_a"), dismiss: FlowLocator(id: "modal_a")),
            .init(detect: FlowLocator(id: "modal_b"), dismiss: FlowLocator(id: "modal_b")),
        ]
        let outcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_submit")))
        XCTAssertTrue(isPassed(outcome.status))
        // 宣言順で最初の modal_a(ref 9)だけを閉じ、そのあと本来の対象(ref 1)
        XCTAssertEqual(driver.tapped, [9, 1])
    }

    /// **検証コマンドでも発火する**(割り込みは待機中にこそ出るので、アクション側だけでは足りない)
    func testInterruptHandlerFiresDuringAssertion() async {
        let modal = node(9, id: "promo_modal", label: "お知らせ")
        let close = node(8, id: "btn_promo_close", label: "閉じる")
        let target = node(1, type: "staticText", id: "txt_result", label: "result=ok")
        // モーダルが出ている間は結果テキストが読めない → 閉じた後の2枚目で読める
        let driver = TapRecordingDriver(frames: [[modal, close], [target]])
        let executor = StepExecutor(driver: driver)
        executor.interruptHandlers = [
            .init(detect: FlowLocator(id: "promo_modal"), dismiss: FlowLocator(id: "btn_promo_close")),
        ]
        let outcome = await executor.execute(
            FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_result"),
                     expected: "result=ok", timeout: 5, occlusionGuard: false))
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.tapped, [8])
        XCTAssertEqual(outcome.driverFallback?.contains("割り込み"), true)
    }

    /// ポーリングを何周しても**タップは1回だけ**(閉じても消えない相手でタップの雨を降らせない)
    func testInterruptHandlerTapsOnceEvenWhenModalNeverGoesAway() async {
        let modal = node(9, id: "promo_modal", label: "お知らせ")
        let close = node(8, id: "btn_promo_close", label: "閉じる")
        // 何度閉じても消えない = 全フレームに出続ける。対象は最後まで現れない
        let driver = TapRecordingDriver(frames: [[modal, close]])
        let executor = StepExecutor(driver: driver)
        executor.interruptHandlers = [
            .init(detect: FlowLocator(id: "promo_modal"), dismiss: FlowLocator(id: "btn_promo_close")),
        ]
        let outcome = await executor.execute(
            FlowStep(assert: "exists", locator: FlowLocator(id: "txt_result"), timeout: 1))
        XCTAssertFalse(isPassed(outcome.status))
        XCTAssertEqual(driver.tapped, [8], "ポーリングのたびに叩かないこと")
    }
}
