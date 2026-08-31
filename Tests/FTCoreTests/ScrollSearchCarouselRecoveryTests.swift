// exist(scroll: .right) で、対象が**木には居るが横カルーセルの右縁で見切れている**形の探索。
// 受け手の最小再現 R0020(2026-08-23): 容器推定がカードを選んでいたため見切れ判定が免除され、
// 回復ドラッグに入らないまま全画面スワイプ(縦容器基準)が横カルーセルに届かず not-found になった。
// 容器推定が scrollable 申告の祖先(カルーセル)を選べば、右縁の見切れ → 必要量だけ左へ遅いドラッグ →
// 次の周回で画面内 → found になる。

import XCTest
@testable import FTCore

/// 横カルーセルを模した偽ドライバ。**drag だけが中身を動かす**(全画面スワイプは縦容器基準なので
/// カルーセルには届かない = 受け手の実測どおり何も動かない)。drag の移動量ぶんカードを左へずらす
private final class CarouselDriver: AppDriver {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    private(set) var swipes = 0
    private(set) var drags: [(fromX: Double, fromY: Double, toX: Double, toY: Double)] = []
    private var offset: Double = 0   // カルーセルの内容オフセット(左へ送った量)

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
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        drags.append((fromX, fromY, toX, toY))
        // カルーセルの帯(y 432..631)の上で横に動かしたときだけ中身が動く
        if fromY >= 432, fromY <= 631 { offset += (fromX - toX) }
    }
    func snapshot() async throws -> SnapshotResponse {
        func el(_ ref: Int, _ type: String, _ depth: Int, _ x: Double, _ y: Double,
                _ w: Double, _ h: Double, label: String? = nil, scrollable: Bool? = nil) -> ElementInfo {
            ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: x, y: y, width: w, height: h), depth: depth,
                        scrollable: scrollable)
        }
        let o = offset
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [
            el(1, "other", 10, 0, 62, 402, 729, scrollable: true),          // 縦のページ
            el(20, "other", 12, 0, 432, 402, 199, scrollable: true),         // 横カルーセル
            el(21, "clickable", 13, 16 - o, 432, 164, 199),
            el(22, "staticText", 16, 16 - o, 563, 111, 20, label: "レシートスタンプ"),
            el(23, "staticText", 16, 16 - o, 614, 30, 17, label: "未読"),
            el(24, "clickable", 13, 188 - o, 432, 164, 199),
            el(25, "staticText", 16, 188 - o, 563, 70, 20, label: "スマホくじ"),
            el(26, "staticText", 16, 188 - o, 614, 30, 17, label: "未読"),
            el(27, "clickable", 13, 360 - o, 432, 164, 199),
            el(28, "staticText", 16, 360 - o, 563, 98, 20, label: "スタンプラリー"),
            el(29, "staticText", 16, 360 - o, 614, 30, 17, label: "未読"),
        ], truncatedCount: 0)
    }
}

/// in-app エンジンの形: **drag を実装しない**(501)主ドライバ。木は共有の CarouselDriver から読む
private final class NoDragPrimary: AppDriver {
    let inner: CarouselDriver
    private(set) var dragAttempts = 0
    init(inner: CarouselDriver) { self.inner = inner }
    func status() async throws -> StatusResponse { try await inner.status() }
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
    func swipe(_ direction: FTSwipeDirection) async throws { try await inner.swipe(direction) }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        try await inner.swipe(direction, intent: intent, path: path)
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        dragAttempts += 1
        throw DriverError.badResponse(status: 501, body: "This driver does not support point-to-point drag")
    }
    func snapshot() async throws -> SnapshotResponse { try await inner.snapshot() }
}

final class ScrollSearchCarouselRecoveryTests: XCTestCase {

    /// **hybrid(in-app 主 + XCUITest typeDriver)でも同じ**: 主ドライバが drag を 501 で断っても
    /// 回復ドラッグは typeDriver から出て通る。2026-08-23 まで slowDrag は `driver.drag` を直に呼び
    /// 501 を失敗扱いにしていた = 利用者の既定エンジンでは見切れ回復が一度も出ていなかった
    func testRecoveryDragFallsBackToTheTypeDriverWhenThePrimaryCannotDrag() async {
        let carousel = CarouselDriver()
        let primary = NoDragPrimary(inner: carousel)
        let executor = StepExecutor(driver: primary, typeDriver: carousel, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(label: "スタンプラリー"),
                            direction: "right", timeout: 1, maxSwipes: 3)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            return XCTFail("typeDriver へ回せば通るはず: \(outcome.status)"
                           + " (primary drag attempts=\(primary.dragAttempts), typeDriver drags=\(carousel.drags.count))")
        }
        XCTAssertGreaterThan(primary.dragAttempts, 0, "主ドライバにまず撃っていない")
        XCTAssertGreaterThan(carousel.drags.count, 0, "501 の後に typeDriver から撃っていない")
    }

    /// 右縁で見切れた3枚目のラベルへの exist(scroll: .right) は、カルーセルを必要量だけ左へ
    /// 送って通る(以前はカードを容器と取り違えて送れず not-found)
    func testExistWithScrollRecoversAClippedCarouselItemByDraggingItsContainer() async {
        let driver = CarouselDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(label: "スタンプラリー"),
                            direction: "right", timeout: 1, maxSwipes: 3)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            return XCTFail("見切れた項目を送って通るはず: \(outcome.status)"
                           + " (drags=\(driver.drags.count) swipes=\(driver.swipes))")
        }
        XCTAssertGreaterThan(driver.drags.count, 0, "回復ドラッグが1本も出ていない")
        // ドラッグはカルーセルの帯の上(y 432..631)で横に動かしていること
        let first = driver.drags[0]
        XCTAssertTrue(first.fromY >= 432 && first.fromY <= 631, "カルーセルの外を引いている: \(first)")
        XCTAssertLessThan(first.toX, first.fromX, "左へ送っていない: \(first)")
    }
}
