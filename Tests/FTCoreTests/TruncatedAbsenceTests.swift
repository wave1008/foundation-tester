// 要素数の上限で切り詰められた木から「不在」「件数」を結論しないこと。
//
// **この群の失敗モードは沈黙(誤った成功)**なので、緑は証拠にならない。各テストは
// 「切り詰められた木なら通ってしまう盤面」を作り、**通らないこと**を見る。逆方向
// (完全な木では従来どおり通る・撮り直しの固定費を増やさない)も同数だけ掛ける。

import XCTest
@testable import FTCore

/// 要素数上限を模すドライバ。`snapshot()` は `frames` の n 回目を「本当の木」とし、
/// 既定では先頭 `defaultLimit` 件だけ返して残りを `truncatedCount` として申告する。
/// `raiseElementLimitOnNextSnapshot` を受けた**次の1回だけ** `raisedLimit` 件まで返す
/// (ブリッジの `?max=` と同じ一発限りの契約)。
private final class TruncatingDriver: AppDriver {
    private let frames: [[ElementInfo]]
    private let defaultLimit: Int
    private let raisedLimit: Int
    /// `raiseElementLimitOnNextSnapshot` に渡された値(何回・いくつ要求したか)
    private(set) var requestedLimits: [Int?] = []
    private(set) var snapshotCount = 0
    private var pending: Int?

    init(frames: [[ElementInfo]], defaultLimit: Int, raisedLimit: Int) {
        self.frames = frames
        self.defaultLimit = defaultLimit
        self.raisedLimit = raisedLimit
    }

    func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        requestedLimits.append(max)
        pending = max
    }

    func snapshot() async throws -> SnapshotResponse {
        snapshotCount += 1
        let limit = pending == nil ? defaultLimit : raisedLimit
        pending = nil
        // **frames は「n 枚目の snapshot が見る画面」**(撮り直しも1枚として数える)。
        // 撮り直しで画面が進む/進まないをドライバ側の規則にすると、テストが読めなくなる
        let full = frames.isEmpty ? [] : frames[min(snapshotCount - 1, frames.count - 1)]
        let kept = Array(full.prefix(limit))
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: kept,
                                truncatedCount: full.count - kept.count)
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// スクロール探索の**途中の周回**で上限に当たるドライバ(目的の要素はどの周にも居ない)。
/// 木は毎周変わる = 「動かないので止めた」を混ぜない
private final class TruncatingSearchDriver: AppDriver {
    private let truncatedUntil: Int
    private var snapshots = 0

    init(truncatedUntil: Int) { self.truncatedUntil = truncatedUntil }

    func snapshot() async throws -> SnapshotResponse {
        snapshots += 1
        let y = 600 - Double((snapshots - 1) / 2) * 40
        return SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [ElementInfo(ref: 1, type: "clickable", identifier: "anchor", label: "行",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 1)],
            truncatedCount: snapshots <= truncatedUntil ? 179 : 0)
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
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class TruncatedAbsenceTests: XCTestCase {

    private func node(_ ref: Int, id: String, type: String = "button") -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: id, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: Double(ref) * 20, width: 100, height: 18), depth: 1)
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

    private func notExist(_ id: String, timeout: Double = 0) -> FlowStep {
        FlowStep(assert: "notExists", locator: FlowLocator(id: id),
                 timeout: timeout, occlusionGuard: false)
    }

    // MARK: - notExists

    /// 実在するのに上限で間引かれた要素。**上限を上げなければ「不在」で通ってしまう**
    func testNotExistDoesNotPassWhenTheTargetWasTruncatedAway() async {
        let full = [node(1, id: "filler_a"), node(2, id: "filler_b"), node(3, id: "dialog")]
        let driver = TruncatingDriver(frames: [full], defaultLimit: 2, raisedLimit: 3)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(notExist("dialog"))
        XCTAssertNotNil(failureReason(outcome.status),
                        "間引かれただけの要素を不在と通した(誤った成功): \(outcome.status)")
        XCTAssertEqual(driver.requestedLimits.count, 1, "上限を上げた撮り直しが撃たれていない")
    }

    /// 天井まで上げても収まらない木では、**本当に不在でも**「不在」と言い切らない
    /// (「無い」と「送られていない」を分けられないため)
    func testNotExistDoesNotPassWhileTheTreeIsStillTruncated() async {
        let full = [node(1, id: "filler_a"), node(2, id: "filler_b"), node(3, id: "filler_c")]
        let driver = TruncatingDriver(frames: [full], defaultLimit: 2, raisedLimit: 2)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(notExist("dialog"))
        let reason = failureReason(outcome.status)
        XCTAssertNotNil(reason, "切り詰められた木で不在を結論した: \(outcome.status)")
        XCTAssertTrue(reason?.contains("cannot decide absence") == true,
                      "判定不能ではなく別の理由で落ちている: \(reason ?? "-")")
    }

    /// 逆方向: 木が完全なら従来どおり通る。**撮り直しは撃たない**(通る側の固定費ゼロ)
    func testNotExistStillPassesOnACompleteTree() async {
        let full = [node(1, id: "filler_a"), node(2, id: "filler_b")]
        let driver = TruncatingDriver(frames: [full], defaultLimit: 5, raisedLimit: 5)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(notExist("dialog"))
        XCTAssertTrue(isPassed(outcome.status), "不在なのに落ちた: \(outcome.status)")
        XCTAssertEqual(driver.snapshotCount, 1)
        XCTAssertTrue(driver.requestedLimits.isEmpty,
                      "切り詰められていない木で撮り直した: \(driver.requestedLimits)")
    }

    /// 引き上げ先は**天井**(BridgeAPI.maxSnapshotElementsCeiling)。既定のままだと同じ木が返り、
    /// 撮り直しが1枚の丸損になる
    func testTheRetakeAsksForTheCeiling() async {
        let full = [node(1, id: "filler_a"), node(2, id: "dialog")]
        let driver = TruncatingDriver(frames: [full], defaultLimit: 1, raisedLimit: 2)
        _ = await StepExecutor(driver: driver, isAndroid: false).execute(notExist("dialog"))
        XCTAssertEqual(driver.requestedLimits, [BridgeAPI.maxSnapshotElementsCeiling])
    }

    /// 一度上限に当たったら、**以後の周は最初から天井で撮る**(2枚目を毎周払わない)。
    /// 判定に使う木が常に天井のものになるので、「天井でも足りない」という文言も嘘にならない
    func testTheCeilingIsLatchedForTheRestOfTheAssertion() async {
        // 1周目: 目的の要素は上限の裏(= 実在)。2周目: 本当に消える
        let present = [node(1, id: "filler_a"), node(2, id: "filler_b"), node(3, id: "dialog")]
        let gone = [node(1, id: "filler_a"), node(2, id: "filler_b"), node(4, id: "filler_c")]
        // 3枚目 = latch 後の周(1枚目=既定の上限・2枚目=撮り直し)
        let driver = TruncatingDriver(frames: [present, present, gone],
                                      defaultLimit: 2, raisedLimit: 3)
        let outcome = await StepExecutor(driver: driver, isAndroid: false)
            .execute(notExist("dialog", timeout: 0.4))
        XCTAssertEqual(driver.snapshotCount, 3,
                       "撮り直しの2枚目を毎周払っている: \(driver.snapshotCount) 枚")
        XCTAssertEqual(driver.requestedLimits,
                       [BridgeAPI.maxSnapshotElementsCeiling, BridgeAPI.maxSnapshotElementsCeiling],
                       "2周目が既定の上限に戻っている: \(driver.requestedLimits)")
        XCTAssertTrue(isPassed(outcome.status),
                      "天井の木で不在を確かめたのに落ちた: \(outcome.status)")
    }

    /// latch が効いた後の周でも、**切り詰められた木の不在は結論にしない**
    /// (要素が天井に収まらない画面では、消えたように見えても判定不能のまま)
    func testLatchedPollsStillRefuseATruncatedAbsence() async {
        let present = [node(1, id: "filler_a"), node(2, id: "dialog"), node(3, id: "filler_c")]
        let driver = TruncatingDriver(frames: [present], defaultLimit: 1, raisedLimit: 2)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(notExist("filler_c"))
        let reason = failureReason(outcome.status)
        XCTAssertNotNil(reason, "天井でも足りない木で不在を結論した: \(outcome.status)")
        XCTAssertTrue(reason?.contains("cannot decide absence") == true, reason ?? "-")
    }

    /// `notExist(scroll:)`: 探索中の周回で上限に当たっていたら、通り過ぎた行が
    /// 「無い」のか「送られなかった」のか分けられない = 不在を結論にしない。
    /// 注記(truncatedDuringSearch)だけでは**検証は通ってしまう**
    func testScrollSearchAbsenceIsNotConcludedAfterMidSearchTruncation() async {
        let driver = TruncatingSearchDriver(truncatedUntil: 2)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "missing"),
                            direction: "up", timeout: 0, maxSwipes: 3, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        let reason = failureReason(outcome.status)
        XCTAssertNotNil(reason, "探索中に切り詰められた木で不在を結論した: \(outcome.status)")
        XCTAssertTrue(reason?.contains("cannot decide absence") == true,
                      "判定不能ではなく別の理由で落ちている: \(reason ?? "-")")
    }

    /// 逆方向: 一度も切り詰められていない探索は従来どおり通る
    func testScrollSearchAbsenceStillPassesWithoutTruncation() async {
        let driver = TruncatingSearchDriver(truncatedUntil: 0)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "missing"),
                            direction: "up", timeout: 0, maxSwipes: 3, occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        XCTAssertTrue(isPassed(outcome.status), "不在なのに落ちた: \(outcome.status)")
    }

    /// 撮り直し自体の境界: **切り詰められていない木では1枚も撮らない**。
    /// 呼び手のゲート(`truncatedCount > 0` を見てから呼ぶ)とは別に、この関数だけで
    /// 安全に呼べることを保証する —— でないと呼び手を1つ足しただけで全周2枚になる
    func testTheRetakeIsSkippedForACompleteTree() async throws {
        let driver = TruncatingDriver(frames: [[node(1, id: "a")]], defaultLimit: 5, raisedLimit: 5)
        let complete = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [node(1, id: "a")], truncatedCount: 0)
        var phase = StepExecutor.PhaseAccumulator()
        let same = try await StepExecutor(driver: driver, isAndroid: false)
            .retakenAtElementLimitCeiling(complete, phase: &phase)
        XCTAssertEqual(driver.snapshotCount, 0, "切り詰められていない木を撮り直した")
        XCTAssertTrue(driver.requestedLimits.isEmpty)
        XCTAssertEqual(same.elements.count, 1, "渡された木をそのまま返すこと")
    }

    // MARK: - count

    private func count(_ type: String, _ expected: Int) -> FlowStep {
        FlowStep(assert: "count", locator: FlowLocator(type: type),
                 timeout: 0, expectedCount: expected)
    }

    /// 間引かれた分だけ少なく数えた結果が期待値と一致すると**誤った成功**になる。
    /// 上限を上げれば実際は3件
    func testCountDoesNotPassOnATruncatedTree() async {
        let full = [node(1, id: "cell_a", type: "clickable"), node(2, id: "cell_b", type: "clickable"),
                    node(3, id: "cell_c", type: "clickable")]
        let driver = TruncatingDriver(frames: [full], defaultLimit: 2, raisedLimit: 3)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(count("clickable", 2))
        XCTAssertNotNil(failureReason(outcome.status),
                        "間引かれた木で数えた一致を通した(誤った成功): \(outcome.status)")
        XCTAssertEqual(driver.requestedLimits.count, 1, "上限を上げた数え直しが撃たれていない")
    }

    /// 天井まで上げても収まらない木で数えた一致は根拠にならない
    func testCountDoesNotPassWhileTheTreeIsStillTruncated() async {
        let full = [node(1, id: "cell_a", type: "clickable"), node(2, id: "cell_b", type: "clickable"),
                    node(3, id: "cell_c", type: "clickable")]
        let driver = TruncatingDriver(frames: [full], defaultLimit: 2, raisedLimit: 2)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(count("clickable", 2))
        let reason = failureReason(outcome.status)
        XCTAssertNotNil(reason, "切り詰められた木で件数を結論した: \(outcome.status)")
        XCTAssertTrue(reason?.contains("cannot decide the count") == true,
                      "判定不能ではなく別の理由で落ちている: \(reason ?? "-")")
    }

    /// 逆方向: 木が完全なら従来どおり通る。撮り直しも撃たない
    func testCountStillPassesOnACompleteTree() async {
        let full = [node(1, id: "cell_a", type: "clickable"), node(2, id: "cell_b", type: "clickable")]
        let driver = TruncatingDriver(frames: [full], defaultLimit: 5, raisedLimit: 5)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(count("clickable", 2))
        XCTAssertTrue(isPassed(outcome.status), "件数が合っているのに落ちた: \(outcome.status)")
        XCTAssertEqual(driver.snapshotCount, 1)
        XCTAssertTrue(driver.requestedLimits.isEmpty)
    }

    /// count も latch する: 一度上限に当たったら、**リストが埋まるのを待つ周も天井で撮る**。
    /// 既定へ戻ると2周目以降がまた間引かれ、埋まっても数えられない
    func testCountLatchesTheCeilingForLaterPolls() async {
        let base = [node(1, id: "filler_a"), node(2, id: "filler_b"),
                    node(3, id: "cell_a", type: "clickable"), node(4, id: "cell_b", type: "clickable")]
        let filled = base + [node(5, id: "cell_c", type: "clickable")]
        // 1枚目=既定の上限(2件) / 2枚目=撮り直し(まだ2件しか無い) / 3枚目以降=埋まった木
        let driver = TruncatingDriver(frames: [base, base, filled],
                                      defaultLimit: 2, raisedLimit: 5)
        let step = FlowStep(assert: "count", locator: FlowLocator(type: "clickable"),
                            timeout: 0.5, expectedCount: 3)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        XCTAssertTrue(isPassed(outcome.status),
                      "埋まった木を天井で数えられていない: \(outcome.status)")
    }

    /// 不一致で落ちるときも**上限に当たっていたこと**を添える(件数が足りない理由が
    /// セレクタではなく上限のことがある)
    func testCountMismatchMentionsTruncation() async {
        let full = [node(1, id: "cell_a", type: "clickable"), node(2, id: "cell_b", type: "clickable"),
                    node(3, id: "cell_c", type: "clickable")]
        let driver = TruncatingDriver(frames: [full], defaultLimit: 2, raisedLimit: 2)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(count("clickable", 5))
        let reason = failureReason(outcome.status)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("truncated") == true,
                      "切り詰めに触れていない: \(reason ?? "-")")
    }
}
