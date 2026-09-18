// ドライバが「もう端」と言えるときは、ホストが署名の2回不変を待たずに切り上げることの固定
//。位置を直接動かせる経路(Android の CDP・in-app の contentOffset)は
// 「余地が無い」を**事実として**知っており、こちらの推測(木の署名)より強い。
//
// **申告は最後に動いた送りから `edgeClaimGraceAfterMove` 経つまで確定しない**: 端へ飛ぶと窓の外に続きを
// 非同期に描き足す仮想化リスト(RN の FlatList)では、飛んだ直後の申告は描き足す前の「今は余地が無い」で
// しかなく、見えている署名も変わらない。猶予を待ってもう1本送る。木が変わっていたらループへ戻る。
// ここが落ちると「端まで行ったつもりで途中で止まる」。

import XCTest
@testable import FTCore

/// `atEdge` を申告するドライバ。`growsAfterEdge` = 端に着いた後に内容が増える画面の再現
private final class EdgeReportingDriver: AppDriver {
    private let edgeAfter: Int
    private let growsAfterEdge: Bool
    private var swipes = 0
    private var extraRows = 0
    private(set) var snapshotCount = 0
    var swipeCount: Int { swipes }
    var reachedEdgeOnLastSwipe: Bool? { swipes >= edgeAfter }

    init(edgeAfter: Int, growsAfterEdge: Bool = false) {
        self.edgeAfter = edgeAfter
        self.growsAfterEdge = growsAfterEdge
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
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipes += 1
        // 端に着いた後に1回だけ内容が伸びる(遅延読み込みの再現)
        if growsAfterEdge, swipes == edgeAfter + 1 { extraRows += 1 }
    }
    func snapshot() async throws -> SnapshotResponse {
        snapshotCount += 1
        let offset = Double(min(swipes, edgeAfter)) * 100 - Double(extraRows) * 10
        let row = ElementInfo(ref: 1, type: "text", identifier: "body", label: nil, value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 500 - offset, width: 300, height: 40), depth: 1)
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: [row], truncatedCount: 0)
    }
}

final class EdgeReportedByDriverTests: XCTestCase {

    private func edgeStep() -> FlowStep {
        FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 20)
    }

    /// 申告が続けば読み続けずに終わる(猶予の後の申告 + 確認の読み)
    func testStopsAsSoonAsTheDriverReportsTheEdge() async throws {
        let driver = EdgeReportingDriver(edgeAfter: 2)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(edgeStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertNil(outcome.driverFallback,
                     "上限打ち切りの注記が出ている = 端と認識できていない: \(outcome.driverFallback ?? "-")")
        // 10 = 読み5回 × 2 枚(猶予の前後の確認を含む)。申告を無視して「不変2回」まで振ると 12 枚
        XCTAssertLessThanOrEqual(driver.snapshotCount, 10,
                                 "申告を受けても読み続けている(\(driver.snapshotCount) 枚)")
    }

    /// **申告の後に内容が伸びたらループへ戻る**(遅延読み込みの画面で途中で止まらない)。
    /// ここが無いと「端に着いた」と言われた時点で終わり、続きを見ない
    func testKeepsGoingWhenTheTreeChangedAfterTheReportedEdge() async throws {
        let driver = EdgeReportingDriver(edgeAfter: 2, growsAfterEdge: true)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(edgeStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertGreaterThan(driver.snapshotCount, 4,
                             "伸びた木を見ずに終わっている(\(driver.snapshotCount) 枚)")
        // **申告の後に木が変わったらループへ戻る**こと。比較の向きが逆だと、変わった時点で
        // 「端に着いた」と決めて止まる = 伸びたぶんを送らないまま終わる
        XCTAssertGreaterThanOrEqual(driver.swipeCount, 3,
                                    "申告の直後に止まっている(\(driver.swipeCount) 本)"
                                    + " —— 伸びたぶんを送らないまま終わる")
    }

    /// **窓の外で描き足す仮想化リスト**: 端へ飛んだ直後の送りは余地が無い(申告)が、続きは窓の外に
    /// 描き足されるので見えている署名は変わらない。猶予の後の送りは描き足された先へ進む。
    /// 飛んだ直後の申告で確定すると、最初の窓の末尾より先を送らない(RN の scrollToRightEdge で実測)
    func testDoesNotSettleOnTheFirstClaimWhenTheListGrowsOutsideTheWindow() async throws {
        let driver = ScriptedEdgeDriver(moves: [true, false, true, false, false, false])
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(edgeStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertNil(outcome.driverFallback, "端と認識できていない: \(outcome.driverFallback ?? "-")")
        XCTAssertEqual(driver.moved, 2,
                       "最初の申告で止まり、描き足された先を送っていない(進んだ送り \(driver.moved) 本)")
    }

    /// **申告しない経路でも同じ**: ヒントが載っていると「不変1回」で端と読むので、飛んだ直後の
    /// 不変(描き足す前)で確定していた。RN の scrollToRightEdge(in-app)で実際に止まったのはこちら
    func testUnchangedRuleAlsoWaitsForTheGraceWhenTheListGrowsOutsideTheWindow() async throws {
        let driver = ScriptedEdgeDriver(moves: [true, false, true, false, false, false],
                                        claims: false, hints: true)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(edgeStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertNil(outcome.driverFallback, "端と認識できていない: \(outcome.driverFallback ?? "-")")
        XCTAssertEqual(driver.moved, 2,
                       "飛んだ直後の不変で止まり、描き足された先を送っていない(進んだ送り \(driver.moved) 本)")
    }

    /// **動いても署名が変わらない画面**: 端へ飛ぶたびにセルが同じ座標に並ぶと、型と座標の署名では
    /// 「不変」に見える。ドライバの「確かに動かした」(false)を動いたと数えないと、2回目の跳躍の後で止まる
    /// (RN の scrollToRightEdge で #tag_13〜16 に止まった実測)
    func testCountsTheDriversMoveWhenTheLayoutLooksTheSameAfterEachJump() async throws {
        let driver = ScriptedEdgeDriver(moves: [true, false, true, false, true, false, false],
                                        hints: true, sameLayout: true)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(edgeStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertNil(outcome.driverFallback, "端と認識できていない: \(outcome.driverFallback ?? "-")")
        XCTAssertEqual(driver.moved, 3,
                       "動いたのに不変と読んで止まっている(進んだ送り \(driver.moved) 本)")
    }

    /// 本当の端では**猶予1回 + 空振り1回**で終わる(申告を待ち続けて上限まで振らない)
    func testATrueEdgeCostsOneExtraSwipe() async throws {
        let driver = ScriptedEdgeDriver(moves: [true, false, false, false, false, false])
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(edgeStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertNil(outcome.driverFallback, "端と認識できていない: \(outcome.driverFallback ?? "-")")
        XCTAssertEqual(driver.swipeCount, 3, "動いた1本 + 申告2本(猶予の前後)で終わるはず(\(driver.swipeCount) 本)")
    }

    /// 猶予の既定値の固定(根拠は定義元のコメント。変えるなら RN の描き足しの実測を取り直す)
    func testGraceAfterMoveIsPinned() {
        XCTAssertEqual(StepExecutor.edgeClaimGraceAfterMove, .milliseconds(1000))
    }

    /// **送る前から端だった(一度も動いていない)ときは猶予を待たない**(待つ理由 = 飛んだ直後の描き足しが無い)
    func testNoGraceWhenAlreadyAtTheEdge() async throws {
        let driver = ScriptedEdgeDriver(moves: [false, false, false])
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(edgeStep())
        let elapsed = clock.now - start

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.swipeCount, 1, "最初の申告で終わるはず(\(driver.swipeCount) 本)")
        XCTAssertLessThan(elapsed, .milliseconds(900), "動いていないのに猶予を待っている(\(elapsed))")
    }
}

/// 送りごとに「動いた / 余地が無かった(= 端の申告)」を台本で返すドライバ。
/// 余地が無かった送りでも木は変えない(描き足しは窓の外 = 見えている署名に出ない)
private final class ScriptedEdgeDriver: AppDriver {
    private let moves: [Bool]
    private let claims: Bool
    private let hints: Bool
    private let sameLayout: Bool
    private(set) var swipeCount = 0
    private(set) var moved = 0
    private var lastMoved = true
    var reachedEdgeOnLastSwipe: Bool? { !claims || swipeCount == 0 ? nil : !lastMoved }

    /// claims = 端を申告するか(false = XCUITest のように申告しないドライバ)。
    /// hints = 窓の外のヒントを載せるか(載っていると「不変1回」で端と読む = RN の in-app で実際に通った経路)
    /// sameLayout = 動いても見えている配置が変わらない(端へ飛ぶたびにセルが同じ座標に並ぶ RN の FlatList)
    init(moves: [Bool], claims: Bool = true, hints: Bool = false, sameLayout: Bool = false) {
        self.moves = moves
        self.claims = claims
        self.hints = hints
        self.sameLayout = sameLayout
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
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {
        try await swipe(direction, intent: .edge, path: nil)
    }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        lastMoved = swipeCount < moves.count ? moves[swipeCount] : false
        swipeCount += 1
        if lastMoved { moved += 1 }
    }
    func snapshot() async throws -> SnapshotResponse {
        let row = ElementInfo(ref: 1, type: "text", identifier: "body", label: nil, value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: sameLayout ? 500 : 500 - Double(moved) * 100,
                                            width: 300, height: 40), depth: 1)
        let hint = ElementInfo(ref: 2, type: "text", identifier: "hint", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 800, width: 300, height: 40), depth: 1)
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: [row], truncatedCount: 0, offscreen: hints ? [hint] : nil)
    }
}
