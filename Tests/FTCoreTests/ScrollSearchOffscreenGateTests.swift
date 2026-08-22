// スクロール探索の「見つかった」判定は、弾切れでも中心が画面外の要素まで success にしてはいけない
// (2026-08-12・Apple マップの経路候補・横ページャで実際に起きた: 24.6秒振っても1ページも動かず、
// 目的の行は ⚠️offscreen のまま "scrolled to" が返っていた)。
// 見切れ(中心は画面内・縁だけ欠けている)と、容器の外だが画面には映っている ghost は現状維持
// —— どちらもタップは通る/既存の警告つきタップで扱う設計なので、探索を failed にはしない。

import XCTest
@testable import FTCore

/// 座標を動かさない偽ドライバ。設定した frame をそのまま返し続ける。
/// maxSwipes: 0 で1周だけ確かめる(settledSignature は2回同じ木を要求するが、動かないドライバは
/// 何度読んでも同じものを返すので自然に満たす)
private final class StaticFrameDriver: AppDriver {
    private let elements: [ElementInfo]
    private let screen: FTRect

    init(frame: FTRect, screen: FTRect) {
        self.screen = screen
        elements = [ElementInfo(ref: 1, type: "cell", identifier: "target", label: "58分",
                                value: nil, placeholder: nil, enabled: true, frame: frame, depth: 1)]
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
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}

/// 中心が画面外(右)から始まり、swipe/drag を1回でも受けたら画面内へ移る偽ドライバ。
/// 「まだ振れる周回では従来どおり寄せに行く」ことの確認用(退行していないかの陰性対照)
private final class NudgeIntoViewDriver: AppDriver {
    private(set) var moves = 0
    private let screen: FTRect

    init(screen: FTRect) { self.screen = screen }

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
    func swipe(_ direction: FTSwipeDirection) async throws { moves += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        moves += 1
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        moves += 1
    }
    func snapshot() async throws -> SnapshotResponse {
        let frame = moves == 0
            ? FTRect(x: 401, y: 300, width: 234, height: 56)   // 中心が画面外(右)
            : FTRect(x: 60, y: 300, width: 234, height: 56)    // 中心が画面内
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [ElementInfo(ref: 1, type: "cell", identifier: "target",
                                                       label: "58分", value: nil, placeholder: nil,
                                                       enabled: true, frame: frame, depth: 1)],
                                truncatedCount: 0)
    }
}

/// drag を受け付けるが何も動かない偽ドライバ(逆走査 `reverseSweep` の経路専用。
/// StaticFrameDriver は drag を持たず 501 で slowDrag が false になり、逆走査に入れない)
private final class DraggableStaticFrameDriver: AppDriver {
    private let elements: [ElementInfo]
    private let screen: FTRect
    private(set) var drags = 0

    init(frame: FTRect, screen: FTRect) {
        self.screen = screen
        elements = [ElementInfo(ref: 1, type: "cell", identifier: "target", label: "58分",
                                value: nil, placeholder: nil, enabled: true, frame: frame, depth: 1)]
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
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws { drags += 1 }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}

final class ScrollSearchOffscreenGateTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func scrollTo(direction: String, maxSwipes: Int) -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"),
                 direction: direction, maxSwipes: maxSwipes)
    }

    /// **不変条件1**: 弾切れの最後の周回で、中心が画面の外の要素しか無いとき → found: false
    /// (実測どおり x=401・幅234・画面幅402 = 中心が画面外の横ページャの2枚目)
    func testLastRoundWithCentreOffscreenIsNotFound() async {
        let driver = StaticFrameDriver(
            frame: FTRect(x: 401, y: 300, width: 234, height: 56), screen: screen)

        let outcome = await StepExecutor(driver: driver)
            .execute(scrollTo(direction: "right", maxSwipes: 0))

        guard case .failed = outcome.status else {
            return XCTFail("中心が画面外のまま見つかったことにしている: \(outcome.status)")
        }
    }

    /// **不変条件2(陰性対照)**: 弾切れの最後の周回でも、中心が画面内の見切れ(縁だけ欠けている)
    /// なら現状維持で found: true(タップは通るので failed にしない)。過剰に厳しくしていないことの確認
    func testLastRoundWithClippedEdgeButCentreInsideIsStillFound() async {
        // 下端で見切れている行: y=829, 高さ56 → 下端885 は画面高874を超えるが、
        // 中心 y=857 は画面内(許容2ptを大きく下回る差)
        let driver = StaticFrameDriver(
            frame: FTRect(x: 16, y: 829, width: 370, height: 56), screen: screen)

        let outcome = await StepExecutor(driver: driver)
            .execute(scrollTo(direction: "up", maxSwipes: 0))

        guard case .passed = outcome.status else {
            return XCTFail("見切れただけの要素まで failed にしている: \(outcome.status)")
        }
    }

    /// **不変条件3**: まだ振れる周回では、中心が画面外でも従来どおり寄せに行く
    /// (この修正で「まだ振れるのに諦める」退行を起こしていないことの確認)
    func testMidRoundWithCentreOffscreenStillNudgesTowardIt() async {
        let driver = NudgeIntoViewDriver(screen: screen)

        let outcome = await StepExecutor(driver: driver)
            .execute(scrollTo(direction: "right", maxSwipes: 1))

        guard case .passed = outcome.status else {
            return XCTFail("寄せれば見つかるのに失敗にしている: \(outcome.status)"
                           + " (moves=\(driver.moves))")
        }
        XCTAssertGreaterThan(driver.moves, 0, "寄せる操作(swipe/drag)を1回も送っていない")
    }

    /// **不変条件4(回帰)**: ビューポートより大きい要素(縦3000pt・画面874pt)は、可視位置の
    /// 大半で中心が画面外になる。`isClippedByViewport` が既にこの形を「送っても収まらない」
    /// として false 扱いにしている(nudge 分岐は発火しない)ので、ゲート側も同じ免除が無いと
    /// attempt 0 から found を拒否し続ける
    func testOversizedElementIsExemptFromOffscreenGate() async {
        let driver = StaticFrameDriver(
            frame: FTRect(x: 0, y: -2500, width: 402, height: 3000), screen: screen)

        let outcome = await StepExecutor(driver: driver)
            .execute(scrollTo(direction: "down", maxSwipes: 0))

        guard case .passed = outcome.status else {
            return XCTFail("送っても収まらない巨大要素をゲートが拒否している: \(outcome.status)")
        }
    }

    /// **不変条件5(回帰)**: ゼロサイズ要素(退化 frame)も `isClippedByViewport` と同じ理由で
    /// 免除する —— 中心座標そのものが無意味なので、画面外を理由に found を拒否しない
    func testZeroSizeElementIsExemptFromOffscreenGate() async {
        let driver = StaticFrameDriver(
            frame: FTRect(x: 1000, y: 1000, width: 0, height: 0), screen: screen)

        let outcome = await StepExecutor(driver: driver)
            .execute(scrollTo(direction: "down", maxSwipes: 0))

        guard case .passed = outcome.status else {
            return XCTFail("ゼロサイズ要素をゲートが拒否している: \(outcome.status)")
        }
    }

    /// **不変条件6**: 縦が oversized(免除対象)でも、横は画面内に収まっており、その横軸で
    /// 中心が画面外(x=800、画面幅402)なら found を拒否する(要素全体を免除してはいけない)
    func testOversizedHeightDoesNotExemptOffscreenOnFittingWidthAxis() async {
        let driver = StaticFrameDriver(
            frame: FTRect(x: 800, y: -2500, width: 234, height: 3000), screen: screen)

        let outcome = await StepExecutor(driver: driver)
            .execute(scrollTo(direction: "right", maxSwipes: 0))

        guard case .failed = outcome.status else {
            return XCTFail("縦が oversized なだけで横の画面外まで免除している: \(outcome.status)")
        }
    }

    /// **不変条件7**: 横が oversized(免除対象)でも、縦は画面内に収まっており、その縦軸で
    /// 中心が画面外(y=2000、画面高874)なら found を拒否する
    func testOversizedWidthDoesNotExemptOffscreenOnFittingHeightAxis() async {
        let driver = StaticFrameDriver(
            frame: FTRect(x: -49, y: 2000, width: 500, height: 56), screen: screen)

        let outcome = await StepExecutor(driver: driver)
            .execute(scrollTo(direction: "down", maxSwipes: 0))

        guard case .failed = outcome.status else {
            return XCTFail("横が oversized なだけで縦の画面外まで免除している: \(outcome.status)")
        }
    }

    // MARK: - 逆走査(reverseSweep)にも同じゲートが要る

    /// **不変条件7**: 逆走査の拾い直しも本編と同じ画面外ゲートを通す。縦が oversized で
    /// `isClippedByViewport` の免除に当たり、横は画面の外(x=800・幅234・画面幅402)の要素を
    /// 「拾い直した」と返してはいけない(受け手報告 2026-08-20: 通り過ぎた横スクロール区画への
    /// exist(scroll:) が遅い成功になる経路)。ドライバは動かないので、ゲートが効けば
    /// 内容署名の不変で nil に到達する
    func testReverseSweepDoesNotRecoverAnElementWhoseCentreIsOffscreen() async throws {
        let driver = DraggableStaticFrameDriver(
            frame: FTRect(x: 800, y: -2500, width: 234, height: 3000), screen: screen)
        let executor = StepExecutor(driver: driver)
        var phase = StepExecutor.PhaseAccumulator()

        let recovered = try await executor.reverseSweep(
            step: scrollTo(direction: "right", maxSwipes: 0),
            container: screen, searching: .right, phase: &phase)

        XCTAssertNil(recovered, "中心が画面外の要素を逆走査が拾い直したことにしている")
        XCTAssertGreaterThan(driver.drags, 0, "逆走査のドラッグが1本も出ていない(経路に入っていない)")
    }

    /// **不変条件8(陰性対照)**: 同じ oversized の縦でも横が画面内なら、逆走査は従来どおり拾う
    /// (ゲートを足したことで逆走査そのものを潰していないことの確認)
    func testReverseSweepStillRecoversAnOversizedElementWhoseCentreIsOnscreen() async throws {
        let driver = DraggableStaticFrameDriver(
            frame: FTRect(x: 60, y: -2500, width: 234, height: 3000), screen: screen)
        let executor = StepExecutor(driver: driver)
        var phase = StepExecutor.PhaseAccumulator()

        let recovered = try await executor.reverseSweep(
            step: scrollTo(direction: "right", maxSwipes: 0),
            container: screen, searching: .right, phase: &phase)

        XCTAssertNotNil(recovered, "画面内にある要素まで逆走査が拾わなくなっている")
    }
}
