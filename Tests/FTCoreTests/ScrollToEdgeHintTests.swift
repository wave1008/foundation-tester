// `scrollToEdge` の端の確定を、**ヒントがある画面だけ**「不変1回」に下げることを固定する。
//
// 端は「署名が2回続けて不変」で判定していた。2回なのは Android では次のスワイプがフリングの
// 停止だけに消費されて1回空振りするため(2026-07-27 実測)。その保険の代償として、
// **端に着いてからスワイプを2回撃って捨てている**。iOS xcuitest の1スワイプは約2.5秒
// (うち1.6秒が XCTest の quiescence)なので、WebView の scrollToTop 中央値 12.1s の主成分だった
// (実測は docs/performance-tuning.md §8)。
//
// `SnapshotResponse.offscreen` はその方向にまだ内容があるかの**肯定的な証拠**なので、
// 供給がある画面では不変を2回重ねる必要がない。供給が無い画面(ネイティブ・旧ブリッジ・
// hybrid の WebViewDelegatingDriver)は従来どおり = 挙動を変えない、が要件。

import XCTest
@testable import FTCore

private final class EdgeDriver: AppDriver {
    /// 全周で同じ木を返す(= 署名は常に不変 = 端に着いている状態)
    let elements: [ElementInfo]
    var offscreen: [ElementInfo]?
    private(set) var swipeCount = 0

    init(elements: [ElementInfo], offscreen: [ElementInfo]?) {
        self.elements = elements
        self.offscreen = offscreen
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
    func swipe(_ direction: FTSwipeDirection) async throws { swipeCount += 1 }

    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0, offscreen: offscreen)
    }
}

final class ScrollToEdgeHintTests: XCTestCase {

    private static let visible = [
        ElementInfo(ref: 1, type: "staticText", identifier: "line_01", label: "行 01", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 100, width: 300, height: 24), depth: 1),
    ]

    /// 画面より下にだけ内容がある = 上端(scrollToTop の行き先)に着いている
    private static func hintsBelow() -> [ElementInfo] {
        [ElementInfo(ref: 0, type: "staticText", identifier: nil, label: "行 40", value: nil,
                     placeholder: nil, enabled: true,
                     frame: FTRect(x: 16, y: 1000, width: 300, height: 24), depth: 1)]
    }

    /// 画面より上にまだ内容がある = 上端に着いていない
    private static func hintsAbove() -> [ElementInfo] {
        [ElementInfo(ref: 0, type: "staticText", identifier: nil, label: "行 01", value: nil,
                     placeholder: nil, enabled: true,
                     frame: FTRect(x: 16, y: -500, width: 300, height: 24), depth: 1)]
    }

    // MARK: - 判定そのもの(純粋関数)

    func testHintlessScreensStillNeedTwoUnchangedRounds() {
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: Self.visible, truncatedCount: 0, offscreen: nil)
        XCTAssertEqual(StepExecutor.unchangedRoundsForEdge(snapshot: snapshot, remainingJump: nil), 2,
                       "ヒントを供給しない画面の挙動は変えない(Android のフリング停止の保険)")
    }

    func testHintedScreenAtTheEdgeNeedsOneUnchangedRound() {
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: Self.visible, truncatedCount: 0,
                                        offscreen: Self.hintsBelow())
        XCTAssertEqual(StepExecutor.unchangedRoundsForEdge(snapshot: snapshot, remainingJump: nil), 1,
                       "「その方向にもう内容が無い」は端の肯定的な証拠")
    }

    func testHintedScreenWithRemainingDistanceStillNeedsTwo() {
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: Self.visible, truncatedCount: 0,
                                        offscreen: Self.hintsAbove())
        XCTAssertEqual(StepExecutor.unchangedRoundsForEdge(snapshot: snapshot, remainingJump: -500), 2,
                       "まだ先があるなら短絡しない")
    }

    // MARK: - 配線(実際にスワイプが減ること)

    /// ヒントが「もう先が無い」と言っている画面では、端に着いた後の捨てスワイプが 2 回 → 1 回になる
    func testEdgeIsConfirmedWithOneFewerSwipeWhenHintsSayThereIsNothingBeyond() async throws {
        let hinted = EdgeDriver(elements: Self.visible, offscreen: Self.hintsBelow())
        let plain = EdgeDriver(elements: Self.visible, offscreen: nil)
        let step = FlowStep(action: "scrollToEdge", direction: "down")

        guard case .passed = await StepExecutor(driver: hinted).execute(step).status,
              case .passed = await StepExecutor(driver: plain).execute(step).status else {
            XCTFail("端に着いていれば scrollToEdge は成功する"); return
        }
        XCTAssertEqual(plain.swipeCount, 2, "供給が無い画面は従来どおり(不変2回)")
        XCTAssertEqual(hinted.swipeCount, 1, "ヒントがあるなら捨てのスワイプは1回で済む")
    }

    /// まだ先があるうちは短絡しない(= 途中で端と誤認して止まらない)。
    /// 上にヒントがある画面は WebView コンテナが無いので長距離ドラッグは撃てず、通常スワイプに落ちる
    func testDoesNotStopEarlyWhileHintsShowContentBeyond() async throws {
        let driver = EdgeDriver(elements: Self.visible, offscreen: Self.hintsAbove())
        let step = FlowStep(action: "scrollToEdge", direction: "down")

        guard case .passed = await StepExecutor(driver: driver).execute(step).status else {
            XCTFail("上限で抜けても scrollToEdge は成功扱い(注記だけ付く)"); return
        }
        XCTAssertEqual(driver.swipeCount, 2, "まだ先があるなら不変2回を待つ")
    }
}
