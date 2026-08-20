// irregularHandler は**1ステップで複数回**閉じられる(上限つき)ことの固定。
//
// 受け手要望(2026-08-20): 「1ステップにつき1回だけ」だと、長いステップの最中に2度目の配信が
// 湧いたときに閉じ切れず、待ち続けたまま失敗する。実アプリ(配信基盤)では出る側を止められない。
//
// 上限を残すのは**閉じても消えない相手に無限に付き合わない**ため。加えて、
// **同じ相手が閉じた直後にまだ居るならその場で打ち切る**(dismiss セレクタが効いていない疑い)。

import XCTest
@testable import FTCore

/// 割り込みが `appearances` 回湧くドライバ。dismiss を叩くと消える(`dismissible == false` なら
/// 叩いても消えない = 閉じられない相手の再現)
private final class InterruptingDriver: AppDriver {
    private let appearances: Int
    private let dismissible: Bool
    private var dismissed = 0
    private var shown = true
    /// 閉じた直後の数枚は**モーダルが消えた木**を返す(実機の見え方。ここを省くと
    /// 「閉じたのに即再一致」= 閉じられない相手と区別が付かず、打ち切り判定に当たってしまう)
    private var cleanSnapshotsLeft = 0
    private(set) var taps = 0

    init(appearances: Int, dismissible: Bool = true) {
        self.appearances = appearances
        self.dismissible = dismissible
    }

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
    func tap(ref: Int) async throws {
        taps += 1
        guard dismissible else { return }
        dismissed += 1
        shown = false
        // **実物は「次の1枚」で戻ってこない**。閉じた後の整定(木を数枚読む)を跨いでから
        // 次が湧く形にする —— 1枚で戻す作りにすると、整定の最中に再一致して
        // 「閉じられない相手」と区別が付かなくなる(テスト側の作り物の都合で打ち切りが出る)
        cleanSnapshotsLeft = 3
    }
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        if !shown, dismissed < appearances {
            // 1枚だけ「消えた画面」を見せてから、次の湧きを出す
            if cleanSnapshotsLeft > 0 { cleanSnapshotsLeft -= 1 } else { shown = true }
        }
        func element(_ ref: Int, _ id: String) -> ElementInfo {
            ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(ref) * 50, width: 200, height: 40), depth: 1)
        }
        // 途中の「消えた画面」では**まだ対象を出さない**(出すとそこで検証が通ってしまい、
        // 2度目以降の割り込みを閉じる場面に入らない)
        let elements: [ElementInfo]
        if shown {
            elements = [element(1, "promo_modal"), element(2, "btn_promo_close")]
        } else if dismissed >= appearances {
            elements = [element(1, "target")]
        } else {
            elements = [element(1, "filler")]
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

/// 閉じるボタンを叩いた**直後の1枚ではまだモーダルが写っている**(消えるアニメーション)。
/// 実機の見え方で、これが受け手報告の形
private final class ClosingAnimationDriver: AppDriver {
    private var dismissed = false
    private var snapshotsSinceDismiss = 0
    private(set) var tappedTarget = false

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
    func tap(ref: Int) async throws {
        if ref == 2 { dismissed = true; snapshotsSinceDismiss = 0 }
        if ref == 3 { tappedTarget = true }
    }
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        func element(_ ref: Int, _ id: String) -> ElementInfo {
            ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(ref) * 50, width: 200, height: 40), depth: 1)
        }
        if dismissed { snapshotsSinceDismiss += 1 }
        // **閉じるアニメーションの最中は木が動く**(カードが消えていく)。静止した木で模すと
        // 整定判定が即成立してしまい、「整定を待つ / 待たない」の差が出ない。
        // 長さは**操作側のリトライ予算(3回)より長く、整定のポーリング上限(6回)より短く**
        // 取る —— そうしないと「どちらでも通る」か「どちらでも落ちる」になり判定にならない
        let stillClosing = dismissed && snapshotsSinceDismiss <= 5
        if !dismissed || stillClosing {
            let slide = Double(snapshotsSinceDismiss) * 12   // 消えていく途中の位置
            return SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                elements: [
                    ElementInfo(ref: 1, type: "button", identifier: "promo_modal", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 50 + slide, width: 200, height: 40), depth: 1),
                    ElementInfo(ref: 2, type: "button", identifier: "btn_promo_close", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 100 + slide, width: 200, height: 40), depth: 1),
                ], truncatedCount: 0)
        }
        let elements = [element(3, "target")]
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class InterruptDismissalCapTests: XCTestCase {

    private func executor(_ driver: AppDriver, maxDismissals: Int? = nil) -> StepExecutor {
        let executor = StepExecutor(driver: driver)
        let handler = maxDismissals.map {
            StepExecutor.InterruptHandler(detect: FlowLocator(id: "promo_modal"),
                                          dismiss: FlowLocator(id: "btn_promo_close"),
                                          maxDismissals: $0)
        } ?? StepExecutor.InterruptHandler(detect: FlowLocator(id: "promo_modal"),
                                           dismiss: FlowLocator(id: "btn_promo_close"))
        executor.interruptHandlers = [handler]
        return executor
    }

    /// 既定の待ちは5秒。**閉じるたびに整定を待つ**ので、回数を試すテストは長めに取る
    /// (閉じる回数 × 整定 が既定の待ちに収まらないと、上限ではなく時間切れを測ることになる)
    private func waitForTarget(timeout: Double = 5) -> FlowStep {
        FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: timeout)
    }

    /// **2度目の割り込みも閉じる**(ここが要望の本体)。注記には回数が出る
    func testDismissesTheInterruptionMoreThanOncePerStep() async throws {
        let driver = InterruptingDriver(appearances: 2)
        let outcome = await executor(driver).execute(waitForTarget())

        guard case .passed = outcome.status else {
            return XCTFail("2度目を閉じられていれば通るはず: \(outcome.status)")
        }
        XCTAssertEqual(driver.taps, 2, "2度目の割り込みを閉じていない")
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("dismissed the interruption"), note)
        XCTAssertTrue(note.contains("×2"), "閉じた回数が読めない: \(note)")
    }

    /// 1回で済むときは従来どおり(回数は書かない)
    func testKeepsTheOldNoteWhenOnceIsEnough() async throws {
        let driver = InterruptingDriver(appearances: 1)
        let outcome = await executor(driver).execute(waitForTarget())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.taps, 1)
        XCTAssertEqual(outcome.driverFallback, "dismissed the interruption id=promo_modal")
    }

    /// **閉じても消えない相手には付き合わない**。2回叩いた時点で打ち切り、理由を注記に残す
    /// (上限まで叩き続けると、効かない dismiss を3回撃って時間を捨てる)
    func testStopsWhenTheInterruptionDoesNotGoAway() async throws {
        let driver = InterruptingDriver(appearances: 9, dismissible: false)
        let outcome = await executor(driver).execute(waitForTarget())

        guard case .failed(let message) = outcome.status else {
            return XCTFail("割り込みが消えないので失敗するはず: \(outcome.status)")
        }
        XCTAssertEqual(driver.taps, 2, "効かない dismiss を叩き続けている(\(driver.taps) 回)")
        XCTAssertTrue(message.contains("target"), message)
    }

    /// **閉じた直後の取り直しは整定してから**(2026-08-20 の受け手報告)。
    /// 閉じるアニメーションの最中の1枚を掴むと、**同じステップの中で割り込みを閉じたのに
    /// 直後の解決が失敗する**。
    ///
    /// **待ちのある検証ではなく `tap` で見る** —— 検証はポーリングするので、
    /// 取り直しが1枚早くても次の周回で拾ってしまい、この退行を殺せない。
    /// 操作は**その場の1枚で解決して失敗が確定する**ので、ここが本番の形
    func testResolvesTheBackgroundRightAfterDismissing() async throws {
        let driver = ClosingAnimationDriver()
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"))
        let outcome = await executor(driver).execute(step)

        guard case .passed = outcome.status else {
            return XCTFail("閉じた後に整定を待てば背面を掴めるはず: \(outcome.status)")
        }
        XCTAssertEqual(driver.tappedTarget, true, "背面を叩いていない")
    }

    /// **閉じたのに落ちたときは、直前の操作が吸われたかもしれないと言う**(撃ち直しはしない ——
    /// 既に届いていた場合に二重実行になる)。ここが黙ると、ログからは
    /// 「割り込みは閉じたのになぜ落ちたのか」が読み取れない
    func testFailedStepsSayTheInteractionMayHaveBeenSwallowed() async throws {
        let driver = InterruptingDriver(appearances: 9, dismissible: false)
        let outcome = await executor(driver).execute(waitForTarget())

        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("may have been swallowed"), note)
        XCTAssertTrue(note.contains("double-fire"), "撃ち直さない理由が書かれていない: \(note)")
    }

    /// **通ったステップでは言わない**(毎回出すと注記が騒がしくなり、本当に効く場面で読まれない)
    func testPassingStepsDoNotMentionSwallowing() async throws {
        let driver = InterruptingDriver(appearances: 1)
        let outcome = await executor(driver).execute(waitForTarget())
        XCTAssertFalse((outcome.driverFallback ?? "").contains("swallowed"),
                       outcome.driverFallback ?? "")
    }

    /// **上限は宣言ごとに指定できる**(2026-08-20 の受け手要望)。湧く頻度は配信側の設定次第で
    /// こちらからは決められないので、既定の3で足りないシナリオは自分で上げられる
    func testHonoursThePerHandlerLimit() async throws {
        let driver = InterruptingDriver(appearances: 9)
        _ = await executor(driver, maxDismissals: 5).execute(waitForTarget(timeout: 20))
        XCTAssertEqual(driver.taps, 5, "宣言した上限(5)まで閉じていない(\(driver.taps) 回)")

        let low = InterruptingDriver(appearances: 9)
        _ = await executor(low, maxDismissals: 1).execute(waitForTarget())
        XCTAssertEqual(low.taps, 1, "宣言した上限(1)を超えて閉じている(\(low.taps) 回)")
    }

    /// **0 以下は 1 に丸める**(「閉じない宣言」は宣言しないのと同じ。書き間違いを黙って通さない)
    func testClampsNonPositiveLimits() async throws {
        let driver = InterruptingDriver(appearances: 9)
        _ = await executor(driver, maxDismissals: 0).execute(waitForTarget())
        XCTAssertEqual(driver.taps, 1, "0 指定で1回も閉じていない")
    }

    /// **上限は効く**。湧き続ける相手でも1ステップ 10 回まで(既定)
    /// **条件判定は1回を1ステップとして数え直す**(`beginInterruptionScope`)。
    /// 呼ばないと直前のステップで上限まで閉じた状態を引き継ぎ、`ifCanSelect` が
    /// **1回も閉じられないまま不成立を確定する** = 分岐が黙って飛ぶ
    func testStandaloneScopeStartsTheCountOver() async throws {
        let driver = InterruptingDriver(appearances: 30)
        let executor = executor(driver)
        _ = await executor.execute(waitForTarget(timeout: 30))
        let afterStep = driver.taps
        XCTAssertGreaterThan(afterStep, 0, "前提: このステップで上限まで閉じていること")

        // 前提: 上限で打ち切ったので割り込みはまだ画面に出ている
        let covered = try await driver.snapshot()
        XCTAssertNotNil(covered.elements.first { $0.identifier == "promo_modal" },
                        "前提: 上限に当たって閉じ切れていない状態であること")

        // 上限に達したまま条件判定へ来ても、数え直せばまた閉じられる
        executor.beginInterruptionScope()
        let dismissal = await executor.dismissDeclaredInterruption(in: covered)

        XCTAssertNotNil(dismissal, "数え直していないので1回も閉じられない")
        XCTAssertGreaterThan(driver.taps, afterStep)
    }

    func testCapsTheNumberOfDismissalsPerStep() async throws {
        let driver = InterruptingDriver(appearances: 30)
        _ = await executor(driver).execute(waitForTarget(timeout: 30))

        // **定数ではなく実数で固定する**: 定数で書くと、上限を上げる変異でテストの期待値も
        // 一緒に動いて素通しする(2026-08-20 の変異テストで実際に生き残った)。
        // 上限を変えるときはここも意識して直すこと
        XCTAssertLessThanOrEqual(driver.taps, 10, "上限を超えて閉じている(\(driver.taps) 回)")
        XCTAssertEqual(StepExecutor.maxInterruptDismissalsPerStep, 10, "上限の既定が変わっている")
    }
}
