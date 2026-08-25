import XCTest
@testable import FTCore

/// notExists / enabled / disabled / count の実行セマンティクス(StepExecutor.executeAssert)。
/// snapshot はスクリプト可能で、ポーリングによる状態変化の追従も検証する。
final class AssertKindsTests: XCTestCase {

    /// snapshot() 呼び出し回数ごとに要素列を差し替えるドライバ(列を使い切ったら最後を繰り返す)
    private final class ScriptedDriver: AppDriver {
        var frames: [[ElementInfo]]
        private(set) var snapshotCallCount = 0
        private(set) var swipeCallCount = 0
        init(frames: [[ElementInfo]]) { self.frames = frames }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
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
        func swipe(_ direction: FTSwipeDirection) async throws { swipeCallCount += 1 }
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
        XCTAssertEqual(failureReason(outcome.status)?.contains("still exists"), true)
    }

    func testNotExistConfirmsAbsenceWithFallbackDriver() async {
        // primary(アプリ内)には無いがシステム UI 側に居る = まだ閉じていない
        let primary = ScriptedDriver(frames: [[node(1, id: "other")]])
        let fallback = ScriptedDriver(frames: [[node(9, label: "許可")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(label: "許可"), timeout: 0)
        let outcome = await executor.execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("system UI"), true)
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
            XCTAssertTrue(reason.contains("near matches"), reason)
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
            XCTAssertTrue(reason.contains("not found"), reason)
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
        XCTAssertEqual(failureReason(disabledOutcome.status)?.contains("the element is enabled"), true)
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
        XCTAssertEqual(failureReason(outcome.status)?.contains("element not found"), true)
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
        XCTAssertEqual(reason?.contains("expected 3"), true)
        XCTAssertEqual(reason?.contains("actual 2"), true)
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
        XCTAssertEqual(failureReason(outcome.status)?.contains("does not start with"), true)
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
        XCTAssertEqual(failureReason(outcome.status)?.contains("equals it"), true)
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
        XCTAssertEqual(failureReason(outcome.status)?.contains("element not found"), true)
    }

    /// `scrollTo` は探索し尽くしても見つからなければ**失敗**する(空振りを許す逃げ道は無い)
    func testScrollToFailsWhenNotFound() async {
        let elements = [[node(1, id: "other")]]
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "居ない"),
                            direction: "down", maxSwipes: 1)
        let failed = await StepExecutor(driver: ScriptedDriver(frames: elements))
            .execute(step)
        XCTAssertEqual(failureReason(failed.status)?.contains("scroll(s)"), true)
    }

    /// `select(scroll:)` はスクロール探索でも掴めなければ空要素を返す(失敗にしない)。
    /// 解決経路が2つ(探索終端と通常解決)あるので、探索側にも契約が通っていることを固定する
    func testSelectWithScrollReturnsEmptyWhenNotFound() async {
        let step = FlowStep(action: "select", locator: FlowLocator(id: "居ない"),
                            direction: "down", maxSwipes: 1)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[node(1, id: "other")]]))
            .execute(step)
        if case .skipped = outcome.status {} else { XCTFail("skipped を期待: \(outcome.status)") }
        XCTAssertNil(outcome.resolvedElement)
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

    /// **探索の1周目は静止を待ってから解決する**。直前の操作がプログラム的な
    /// アニメーションスクロール(「先頭へ」等)だと、ブリッジの整定はすり抜けることがあり、
    /// 動く前のツリーで解決すると**古い座標をタップして別の要素が選ばれる**
    /// (2026-08-02 に CMP の xcuitest / Android で実測。ステップは成功のまま = 黙って誤った結果)。
    /// 以前は「スワイプせずに見つかったら静止待ちを挟まない」最適化だったが、
    /// **実測コストが共通シナリオで +0.1〜1.0%(run 間ノイズ以下)**だったので安全側を採った。
    /// スワイプは1回も起きない(見つかっているので)ことは変わらない
    func testScrollToWaitsForStillnessOnTheFirstAttempt() async {
        let driver = ScriptedDriver(frames: [[node(1, id: "row_30")], [node(1, id: "row_30")]])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 5)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.snapshotCallCount, 2, "静止確認の2枚だけで、スワイプは挟まない")
        XCTAssertEqual(driver.swipeCallCount, 0)
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
        XCTAssertEqual(reason?.contains("is covered by"), true, reason ?? "")
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
        XCTAssertEqual(failureReason(outcome.status)?.contains("is covered by"), false)
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
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
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
        XCTAssertEqual(outcome.driverFallback?.contains("interruption"), true)
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
        XCTAssertEqual(outcome.driverFallback?.contains("interruption"), true)
    }

    /// ポーリングを何周しても**タップの雨を降らせない**。閉じても消えない相手には
    /// **2回で見切る**(1回目は閉じ損ねかもしれない = 閉じるアニメーションの最中に撮った木でも
    /// 早合点しないため。2回目も残っていたら dismiss が効いていないと判断して打ち切る)。
    /// **1ステップ1回**だった頃の固定を 2026-08-20 に更新した(受け手要望で複数回に緩めたため)
    func testInterruptHandlerStopsHammeringWhenModalNeverGoesAway() async {
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
        XCTAssertEqual(driver.tapped, [8, 8], "ポーリングのたびに叩かないこと(2回で見切る)")
    }

    // MARK: - 内蔵スクロール探索(tap(scroll:) / exist(scroll:))

    /// スクロールして見つけてからタップするまでを**1ステップ**で行う
    func testTapWithScrollSearchesThenTapsInOneStep() async {
        let target = node(1, id: "row_40", label: "行 40")
        // 1・2枚目は未発見(スワイプ)、3枚目で現れる
        let driver = TapRecordingDriver(frames: [[node(9, id: "other")], [node(9, id: "other")],
                                                 [target]])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_40"),
                            direction: "up", maxSwipes: 5)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.tapped, [1])
    }

    /// スクロールしても見つからなければ、その旨で失敗する
    func testTapWithScrollFailsWithScrollMessage() async {
        let driver = TapRecordingDriver(frames: [[node(9, id: "other")]])
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_40"),
                            direction: "up", maxSwipes: 2)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("scroll(s)"), true)
        XCTAssertTrue(driver.tapped.isEmpty)
    }

    /// exist(scroll:) も同じく1ステップ。探索して見つかれば検証が通る
    func testExistWithScrollSearchesInOneStep() async {
        let target = node(1, id: "txt_offscreen", label: "画面外テキスト")
        let driver = ScriptedDriver(frames: [[node(9, id: "other")], [target]])
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "txt_offscreen"),
                            direction: "up", timeout: 0, maxSwipes: 3, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status))
    }

    /// scroll を指定しなければ探索しない(現在画面のみ = 従来の契約)
    func testExistWithoutScrollDoesNotSearch() async {
        let driver = ScriptedDriver(frames: [[node(9, id: "other")], [node(1, id: "txt_offscreen")]])
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "txt_offscreen"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertFalse(isPassed(outcome.status))
    }

    // MARK: - countIs の失敗メッセージ

    /// 節が複数あるときは**どの節が何件拾ったか**まで出す(和集合の総数だけでは直せない)
    func testCountFailureShowsPerClauseBreakdown() async {
        let elements = [node(1, type: "button", label: "許可"), node(2, type: "staticText", label: "許可"),
                        node(3, type: "button", label: "別名"), node(4, type: "staticText", label: "別名")]
        let step = FlowStep(assert: "count", locator: FlowLocator(label: "許可"),
                            fallbacks: [FlowLocator(label: "別名")], timeout: 0, expectedCount: 2)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(step)
        let reason = failureReason(outcome.status)
        XCTAssertEqual(reason?.contains("actual 4"), true, reason ?? "")
        XCTAssertEqual(reason?.contains("breakdown"), true, reason ?? "")
        XCTAssertEqual(reason?.contains("text=許可 2"), true, reason ?? "")
        XCTAssertEqual(reason?.contains("text=別名 2"), true, reason ?? "")
    }

    /// 内訳の合計は必ず表示件数と一致する(重複は先に現れた節に数える)
    func testCountBreakdownSumsToTotalWhenClausesOverlap() {
        let shared = ElementInfo(ref: 1, type: "button", identifier: "save", label: "保存",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        let byClause = StepExecutor.unionByClause(
            [FlowLocator(id: "save"), FlowLocator(label: "保存")], elements: [shared])
        XCTAssertEqual(byClause.map(\.elements.count), [1, 0])
        XCTAssertEqual(byClause.reduce(0) { $0 + $1.elements.count },
                       StepExecutor.unionCandidates(
                        [FlowLocator(id: "save"), FlowLocator(label: "保存")], elements: [shared]).count)
    }

    /// 単一節なら従来どおりロケータだけ(内訳は付けない)
    func testCountFailureKeepsSimpleMessageForSingleClause() async {
        let step = FlowStep(assert: "count", locator: FlowLocator(type: "button"),
                            timeout: 0, expectedCount: 3)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [[node(1, type: "button")]]))
            .execute(step)
        let reason = failureReason(outcome.status)
        XCTAssertEqual(reason?.contains("breakdown"), false, reason ?? "")
        XCTAssertEqual(reason?.contains("button"), true, reason ?? "")
    }

    /// 失敗メッセージのロケータ表示は**節を `||` で連ねる**(旧: `(fallback: …)`)
    func testLocatorSummaryJoinsClausesWithOrOperator() {
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "a"),
                            fallbacks: [FlowLocator(label: "b")])
        XCTAssertEqual(step.locatorSummary, "id=a || text=b")
    }

    /// 親子で同じラベルを重ねて数えたときは、**直し方(型で絞る)まで**メッセージに出す。
    /// これを知らないと countIs("項目", 3) が 6 を返す理由に辿り着けない
    func testCountFailureHintsNestedDuplicates() async {
        func el(_ ref: Int, _ type: String, _ depth: Int, _ frame: FTRect) -> ElementInfo {
            ElementInfo(ref: ref, type: type, identifier: nil, label: "項目", value: nil,
                        placeholder: nil, enabled: true, frame: frame, depth: depth)
        }
        // ボタン(親)とその内側の Text(子)が3組。ラベルだけで数えると 6 件になる
        var elements: [ElementInfo] = []
        for i in 0..<3 {
            let y = Double(i) * 60
            elements.append(el(i * 2 + 1, "button", 1, FTRect(x: 0, y: y, width: 200, height: 50)))
            elements.append(el(i * 2 + 2, "staticText", 2, FTRect(x: 10, y: y + 10, width: 100, height: 20)))
        }
        let step = FlowStep(assert: "count", locator: FlowLocator(label: "項目"),
                            timeout: 0, expectedCount: 3)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(step)
        let reason = failureReason(outcome.status)
        XCTAssertEqual(reason?.contains("actual 6"), true, reason ?? "")
        XCTAssertEqual(reason?.contains("Parent and child are being counted as the same element"), true, reason ?? "")
        XCTAssertEqual(reason?.contains("narrowing by type gives 3"), true, reason ?? "")
        XCTAssertEqual(reason?.contains(".button"), true, reason ?? "")
    }

    /// 入れ子が無ければヒントは出さない(余計な文言を足さない)
    func testCountFailureHasNoNestingHintWhenFlat() async {
        let elements = [node(1, type: "button", label: "項目"), node(2, type: "button", label: "項目")]
        let step = FlowStep(assert: "count", locator: FlowLocator(label: "項目"),
                            timeout: 0, expectedCount: 3)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("Parent and child"), false)
    }

    // MARK: - Shirates 準拠で増えたアサート

    private func valued(_ ref: Int, id: String, value: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: id, label: nil, value: value,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
    }

    /// value 系は label ではなく value を見る(text 系と同じ判定器を共有する)
    func testValueAssertionsReadValue() async {
        let elements = [valued(1, id: "input", value: "合計 1,200円")]
        for (assert, expected, shouldPass) in [
            ("valueContains", "1,200", true), ("valueContains", "9,999", false),
            ("valueStartsWith", "合計", true), ("valueEndsWith", "円", true),
            ("valueContainsNot", "ドル", true), ("valueContainsNot", "円", false),
        ] as [(String, String, Bool)] {
            let step = FlowStep(assert: assert, locator: FlowLocator(id: "input"),
                                expected: expected, timeout: 0)
            let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements]))
                .execute(step)
            XCTAssertEqual(isPassed(outcome.status), shouldPass, "\(assert) \(expected)")
        }
    }

    /// 否定の失敗理由は「どの関係で成立してしまったか」まで書く
    func testNegativeAssertFailureNamesTheRelation() async {
        let step = FlowStep(assert: "textContainsNot", locator: FlowLocator(id: "status"),
                            expected: "エラー", timeout: 0)
        let outcome = await StepExecutor(
            driver: ScriptedDriver(frames: [[node(1, id: "status", label: "エラー 404")]]))
            .execute(step)
        XCTAssertEqual(failureReason(outcome.status)?.contains("contains"), true)
    }

    /// Empty 系以外で expected が無いのは書き間違い(空文字と比べて必ず落とさない)
    func testNegativeAssertWithoutExpectedIsSkipped() async {
        let step = FlowStep(assert: "textContainsNot", locator: FlowLocator(id: "status"),
                            timeout: 0)
        let outcome = await StepExecutor(
            driver: ScriptedDriver(frames: [[node(1, id: "status", label: "x")]])).execute(step)
        if case .skipped = outcome.status {} else { XCTFail("skipped ではない: \(outcome.status)") }
    }

    /// idIs は解決した要素の id を見る(セレクタに #id を足す形ではないので実際の id を出せる)
    func testIdEqualsReportsActualIdentifier() async {
        let elements = [node(1, id: "btn_ok", label: "OK")]
        let pass = FlowStep(assert: "idEquals", locator: FlowLocator(label: "OK"),
                            expected: "btn_ok", timeout: 0, occlusionGuard: false)
        let passed = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(pass)
        XCTAssertTrue(isPassed(passed.status))

        let fail = FlowStep(assert: "idEquals", locator: FlowLocator(label: "OK"),
                            expected: "btn_cancel", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: ScriptedDriver(frames: [elements])).execute(fail)
        XCTAssertEqual(failureReason(outcome.status)?.contains("btn_ok"), true)
        XCTAssertEqual(failureReason(outcome.status)?.contains("id"), true)
    }

    // MARK: - 期限切れ直前のキャッシュ捨て(AssertFreshRetry)

    /// キャッシュ供給の a11y ツリーを模したドライバ: 通常の snapshot は**何回撮っても古いまま**で、
    /// bypassingCache=true のときだけ真の状態を返す(Android の実挙動と同じ形)
    private final class StaleCacheDriver: AppDriver {
        let stale: [ElementInfo]
        let fresh: [ElementInfo]
        let supportsBypass: Bool
        private(set) var staleReads = 0
        private(set) var freshReads = 0
        init(stale: [ElementInfo], fresh: [ElementInfo], supportsBypass: Bool = true) {
            self.stale = stale
            self.fresh = fresh
            self.supportsBypass = supportsBypass
        }

        var supportsCacheBypass: Bool { supportsBypass }

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
            if bypassingCache { freshReads += 1 } else { staleReads += 1 }
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: bypassingCache ? fresh : stale,
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

    /// 実害の再現: アプリは正しい状態なのにキャッシュが古く、期限切れまで古い値を読み続ける。
    /// 期限切れ直前に1回だけ取り直すことで**失敗ではなく成功**になる
    func testStaleTreeIsRecheckedOnceBeforeFailing() async {
        let driver = StaleCacheDriver(stale: [node(1, id: "txt", label: "submitted=-")],
                                      fresh: [node(1, id: "txt", label: "submitted=persist99")])
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt"),
                            expected: "submitted=persist99", timeout: 1, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "取り直しで成功になるはず: \(outcome.status)")
        // 取り直しは**1回だけ**(毎周回払うとコストが跳ねる)
        XCTAssertEqual(driver.freshReads, 1)
        XCTAssertGreaterThan(driver.staleReads, 0)
    }

    /// 非対応ドライバ(iOS 系)では取り直しの周回そのものを行わない
    func testUnsupportedDriverIsNotRetried() async {
        let driver = StaleCacheDriver(stale: [node(1, id: "txt", label: "old")],
                                      fresh: [node(1, id: "txt", label: "new")],
                                      supportsBypass: false)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt"),
                            expected: "new", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertNotNil(failureReason(outcome.status))
        XCTAssertEqual(driver.freshReads, 0)
    }

    // MARK: - 否定形を通す前の確認(AssertFreshRetry.confirmPass)

    // **この群の失敗モードは沈黙(誤った成功)**なので、緑は証拠にならない。
    // 各テストは「古い木なら通ってしまう盤面」を作り、**通らないこと**を見る。

    /// notExist: 要素は実在するのに古い木にまだ載っていない。確認が無ければ**誤って成功**する
    func testNotExistDoesNotPassOnAStaleAbsence() async {
        let driver = StaleCacheDriver(stale: [], fresh: [node(1, id: "dialog", label: "エラー")])
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "dialog"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertNotNil(failureReason(outcome.status),
                        "実在する要素を不在と通した(誤った成功): \(outcome.status)")
        XCTAssertGreaterThan(driver.freshReads, 0, "確認の取り直しが撃たれていない")
    }

    /// 逆方向: **本当に不在**なら従来どおり通る(確認が誤検出を生まないこと)。
    /// 取り直しは1回だけ = 通る側の固定費を増やさない
    func testNotExistStillPassesWhenGenuinelyAbsent() async {
        let driver = StaleCacheDriver(stale: [], fresh: [])
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "dialog"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "不在なのに落ちた: \(outcome.status)")
        XCTAssertEqual(driver.freshReads, 1)
    }

    /// 否定テキスト比較: 値は既に "new" なのに古い木が "old" を返す。
    /// `textIsNot "new"` は古い値で成立してしまう
    func testNegativeTextComparisonDoesNotPassOnAStaleValue() async {
        let driver = StaleCacheDriver(stale: [node(1, id: "txt", label: "old")],
                                      fresh: [node(1, id: "txt", label: "new")])
        let step = FlowStep(assert: "textNotEquals", locator: FlowLocator(id: "txt"),
                            expected: "new", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertNotNil(failureReason(outcome.status),
                        "古い値で否定条件を満たして通した(誤った成功): \(outcome.status)")
    }

    /// 逆方向: 値が本当に違うなら通る
    func testNegativeTextComparisonStillPassesWhenGenuinelyDifferent() async {
        let driver = StaleCacheDriver(stale: [node(1, id: "txt", label: "old")],
                                      fresh: [node(1, id: "txt", label: "old")])
        let step = FlowStep(assert: "textNotEquals", locator: FlowLocator(id: "txt"),
                            expected: "new", timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "値が違うのに落ちた: \(outcome.status)")
    }

    /// 非対応ドライバ(iOS 系)では否定形でも取り直さない = 固定費を増やさない
    func testNegativePassIsNotConfirmedOnUnsupportedDrivers() async {
        let driver = StaleCacheDriver(stale: [], fresh: [node(1, id: "dialog")],
                                      supportsBypass: false)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "dialog"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver).execute(step)
        XCTAssertTrue(isPassed(outcome.status))
        XCTAssertEqual(driver.freshReads, 0)
    }

    /// 予算は pass 側と fail 側で別々 —— pass の確認で使い切っても、期限切れの取り直しは残る。
    /// 共有にすると、塞いだ穴の隣に**誤った失敗**を作る
    func testPassConfirmationDoesNotConsumeTheFailureRetryBudget() async {
        var retry = AssertFreshRetry()
        XCTAssertTrue(retry.confirmPass(ifSupported: true))
        XCTAssertTrue(retry.takeArmed())
        XCTAssertFalse(retry.confirmPass(ifSupported: true), "pass 側は1回だけ")
        XCTAssertTrue(retry.arm(ifSupported: true), "fail 側の予算まで消費している")
        XCTAssertTrue(retry.takeArmed())
        XCTAssertFalse(retry.arm(ifSupported: true), "fail 側も1回だけ")
    }
}
