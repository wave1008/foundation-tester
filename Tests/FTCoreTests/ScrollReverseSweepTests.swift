// 端まで送っても見つからなかったときの**逆走査による拾い直し**を固定する。
//
// デバイス上の witness(E2E-CMP の「飛び越し」画面)と同じ形をドライバで再現する:
// 容器 160pt に 56pt の行が 10 個(内容 560 = 容器 160 + スクロール範囲 400)。
// 既定のスワイプ(path なし)は範囲 400 を1回で走り切るので、木を撮れるのは**両端だけ**——
// 上端で jrow_01..03・下端で jrow_08..10 しか出ず、`#jrow_05` は一度もツリーに現れない。

import XCTest
@testable import FTCore

/// スクロール位置を持つ偽ドライバ。**path の有無で移動量が変わる**のが肝:
///  - path なし(= エンジン既定・`scrollFrame` 未指定)は範囲を1回で走り切る
///  - path あり(= 容器基準の刻み)は path の長さだけ動く
private final class JumpScreenDriver: AppDriver {
    static let containerY: Double = 357
    static let containerHeight: Double = 160
    static let rowHeight: Double = 56
    static let rowCount = 10
    /// 内容 560 - 容器 160
    static let scrollRange: Double = 400

    private(set) var offset: Double = 0
    private(set) var swipes = 0

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
        try await swipe(direction, intent: .search, path: nil)
    }

    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipes += 1
        // 指が上 = 内容は下へ進む(offset 増)
        let sign: Double = direction == .up ? 1 : (direction == .down ? -1 : 0)
        let travel = path.map { abs($0.toY - $0.fromY) } ?? Self.scrollRange
        offset = min(Self.scrollRange, max(0, offset + sign * travel))
    }

    /// 逆走査は**ドラッグ**で戻す(フリングを避けるため)。距離ぶんだけ動かす
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        swipes += 1
        offset = min(Self.scrollRange, max(0, offset + (fromY - toY)))
    }

    func snapshot() async throws -> SnapshotResponse {
        let container = FTRect(x: 16, y: Self.containerY, width: 370, height: Self.containerHeight)
        var elements = [
            ElementInfo(ref: 1, type: "other", identifier: "list_jump", label: nil, value: nil,
                        placeholder: nil, enabled: true, frame: container, depth: 1)
        ]
        // 容器と交差する行だけを木に出す(lazy list = 見えていない行は存在しない)
        for n in 1...Self.rowCount {
            let top = Self.containerY + Double(n - 1) * Self.rowHeight - offset
            let frame = FTRect(x: 16, y: top, width: 370, height: Self.rowHeight)
            guard ScrollGeometry.intersection(frame, container) != nil else { continue }
            elements.append(ElementInfo(ref: 10 + n, type: "clickable",
                                        identifier: String(format: "jrow_%02d", n),
                                        label: "跳 \(n)", value: nil, placeholder: nil,
                                        enabled: true, frame: frame, depth: 2))
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class ScrollReverseSweepTests: XCTestCase {

    private func scrollTo(_ id: String, containerInference: Bool? = nil) -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: id), direction: "up", maxSwipes: 8,
                 containerInference: containerInference)
    }

    /// witness の前提: 既定のスワイプでは `#jrow_05` は**両端のどちらでも木に出ない**
    func testTheTargetIsNeverVisibleAtEitherEnd() async throws {
        let driver = JumpScreenDriver()
        let top = try await driver.snapshot().elements.compactMap(\.identifier)
        try await driver.swipe(.up)
        let bottom = try await driver.snapshot().elements.compactMap(\.identifier)

        XCTAssertFalse(top.contains("jrow_05"), "上端で見えてはいけない: \(top)")
        XCTAssertFalse(bottom.contains("jrow_05"), "下端で見えてはいけない: \(bottom)")
        XCTAssertEqual(driver.offset, JumpScreenDriver.scrollRange, "1回で端まで行き切る前提")
    }

    /// **飛び越しても逆走査で拾い直せる**(この witness が今回の修正の実体)
    func testReverseSweepFindsTheOvershotElement() async throws {
        let driver = JumpScreenDriver()

        let outcome = await StepExecutor(driver: driver).execute(scrollTo("jrow_05"))

        guard case .passed = outcome.status else {
            return XCTFail("飛び越した要素を拾い直せていない: \(outcome.status)"
                           + " (swipes=\(driver.swipes) offset=\(driver.offset))")
        }
    }

    /// **`containerInference: false` では拾い直さない**(容器の推測に依存する補正なので、
    /// 切ったら止まるのが契約)
    func testReverseSweepIsSkippedWhenContainerInferenceIsOff() async throws {
        let driver = JumpScreenDriver()

        let outcome = await StepExecutor(driver: driver)
            .execute(scrollTo("jrow_05", containerInference: false))

        guard case .failed = outcome.status else {
            return XCTFail("補正を切ったのに拾い直している: \(outcome.status)")
        }
    }
}
