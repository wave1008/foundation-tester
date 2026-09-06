// runScrollSearch の**見切れ寄せ(clip recovery)の周回**が、未検出側の周回と同じ会計を
// 通ることを固定する: 明示 scrollFrame の fail-fast / `swipes` の計上 / previousSnapshot の更新。
//
// 旧実装は寄せの `continue` が3つとも飛ばしていた —— 解決できない scrollFrame のまま
// 全画面スワイプが1本出る・MCP の内訳に swipes=0 と報告される・「2周不変」の打ち切りが
// 寄せの周回では効かない

import XCTest
@testable import FTCore

/// snapshot() 呼び出しごとに台本の次の木を返す最小ドライバ(尽きたら最後を繰り返す)。
/// drag は AppDriver の既定(501)のまま = slowDrag は失敗して従来スワイプへ落ちる
private final class ScriptedSwipeDriver: AppDriver {
    private let scripted: [[ElementInfo]]
    private var index = 0
    private(set) var swipeCount = 0

    init(scripted: [[ElementInfo]]) { self.scripted = scripted }

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
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipeCount += 1
    }
    func snapshot() async throws -> SnapshotResponse {
        let elements = scripted[min(index, scripted.count - 1)]
        index += 1
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class ScrollSearchClipRecoveryTests: XCTestCase {

    /// 画面 874pt。下端で見切れる行(下端 906 > 874)
    private func row(ref: Int, id: String, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "clickable", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 2)
    }

    /// 申告のある容器(y 100..800)
    private func list() -> ElementInfo {
        ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1,
                    scrollable: true)
    }

    /// **見つかったが見切れている**ときも、解決できない明示 scrollFrame なら1本も振らない。
    /// 旧実装は未検出側でしか判定せず、寄せの1本が全画面スワイプになっていた
    func testClippedTargetWithUnresolvableScrollFrameFailsWithoutSwiping() async throws {
        let clipped = [row(ref: 2, id: "target", y: 850)]
        let driver = ScriptedSwipeDriver(scripted: [clipped])
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"),
                            direction: "up", maxSwipes: 8)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)

        XCTAssertEqual(driver.swipeCount, 0, "scrollFrame が解決できないなら寄せの1本も振らないこと")
        guard case .failed(let reason) = outcome.status else {
            return XCTFail("scrollFrame 未解決は失敗のはず: \(outcome.status)")
        }
        XCTAssertTrue(reason.contains("search was not run"), reason)
        XCTAssertTrue(outcome.notes.contains(.scrollFrameMissing),
                      "MCP が分岐に使う機械可読コードが立っていない: \(outcome.notes)")
    }

    /// 寄せの1本も **`swipes` に載る**(MCP の ft_scroll_to が内訳に出す値)。
    /// 台本: 見切れ(整定の2枚)→ 寄せ → 3枚目で完全に見える
    func testRecoverySwipeIsCountedInSwipes() async throws {
        let clipped = [list(), row(ref: 2, id: "target", y: 780)]   // 下端 836 > 容器下端 800
        let visible = [list(), row(ref: 2, id: "target", y: 700)]
        let driver = ScriptedSwipeDriver(scripted: [clipped, clipped, visible])
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"),
                            direction: "up", maxSwipes: 8)
        step.scrollFrame = FlowLocator(id: "list")

        let outcome = await StepExecutor(driver: driver, releasesScrollTouch: true,
                                         isAndroid: false).execute(step)

        guard case .passed = outcome.status else {
            return XCTFail("寄せた後に見つかるはずなので pass: \(outcome.status)")
        }
        XCTAssertGreaterThanOrEqual(driver.swipeCount, 1, "寄せの1本が撃たれていない")
        XCTAssertEqual(outcome.scrollSwipes, driver.swipeCount,
                       "寄せの1本が swipes に載っていない(旧実装は 0 と報告した)")
    }
}
