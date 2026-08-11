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
}
