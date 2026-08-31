// **容器の縁にまたがった要素は、触る前に容器の中へ寄せる**ことを固定する。
//
// 見えている部分を撃つだけでは足りない: Compose は focus 時に bringIntoView で内容を動かすので、
// 離すまでに隣の行が指の下へ来る(Emulator で約 50%・実測 135〜179px ずれて隣が反応した)。
//
// **2026-08-05 に撤回した「またぎも掴み直しの対象へ広げる」との違いは送り方**。あちらは
// 全画面スワイプで行き過ぎて自傷した(S0110 が 2/10 → 5/10)。ここは recoveryJump(距離)+
// slowDrag(フリングを出さない)なので行き過ぎない —— 実測でも S0110 は 32/32 のまま。

import XCTest
@testable import FTCore

/// 縁にまたがった行を返すドライバ。ドラッグを受けたら中へ入れる(寄せが効いたことを表現する)
private final class StraddlingDriver: AppDriver {
    static let container = FTRect(x: 16, y: 300, width: 370, height: 300)
    /// 容器の上端をまたぐ位置(交差はするが完全には入っていない)
    private var rowY: Double
    private(set) var drags = 0
    private(set) var taps: [(x: Double, y: Double)] = []
    private(set) var refTaps = 0

    /// straddling: 縁をまたぐ(交差はする) / ghost: 完全に容器の外
    init(straddling: Bool, ghost: Bool = false) {
        rowY = ghost ? Self.container.y - 200
            : (straddling ? Self.container.y - 30 : Self.container.y + 100)
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
    func tap(ref: Int) async throws { refTaps += 1 }
    func tap(x: Double, y: Double) async throws { taps.append((x, y)) }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        drags += 1
        rowY += (toY - fromY)   // 指の動きぶん内容が動く(フリング無し)
    }

    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [
                ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil,
                            placeholder: nil, enabled: true, frame: Self.container, depth: 1),
                ElementInfo(ref: 2, type: "clickable", identifier: "other_01", label: "他 01",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: Self.container.y + 160, width: 370, height: 56),
                            depth: 2),
                ElementInfo(ref: 3, type: "clickable", identifier: "other_02", label: "他 02",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: Self.container.y + 220, width: 370, height: 56),
                            depth: 2),
                ElementInfo(ref: 4, type: "clickable", identifier: "target", label: "対象",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: rowY, width: 370, height: 56), depth: 2),
            ],
            truncatedCount: 0)
    }
}

final class StraddleNudgeTests: XCTestCase {

    private func tapStep(containerInference: Bool? = nil) -> FlowStep {
        FlowStep(action: "tap", locator: FlowLocator(id: "target"),
                 containerInference: containerInference)
    }

    /// **またいでいるなら寄せてから撃つ**
    func testStraddlingElementIsNudgedInsideBeforeTapping() async throws {
        let driver = StraddlingDriver(straddling: true)

        _ = await StepExecutor(driver: driver, isAndroid: false).execute(tapStep())

        XCTAssertGreaterThan(driver.drags, 0,
                             "縁にまたがった要素をそのまま撃っている(寄せが発火していない)")
    }

    /// **容器の中に収まっているなら余計なドラッグを撃たない**(正常系のコストを増やさない)
    func testFullyVisibleElementIsTappedDirectly() async throws {
        let driver = StraddlingDriver(straddling: false)

        _ = await StepExecutor(driver: driver, isAndroid: false).execute(tapStep())

        XCTAssertEqual(driver.drags, 0, "容器の中に居るのに寄せている")
        XCTAssertEqual(driver.refTaps, 1, "ref でそのままタップしていない")
    }

    /// **完全に容器の外(ghost)は寄せの経路で処理しない** —— あちらは掴み直し(grabbedGhost)の担当。
    ///
    /// **これは意図の記録で、変異では落ちない**: ghost は寄せの手前(解決ループ)で掴み直され、
    /// ここへ来る時点では既に容器の中に居るため、交差条件を外しても外から観測できない。
    /// 条件を残しているのは「掴み直しが救えなかった ghost に、別機構を二重に当てない」ため
    func testPureGhostIsNotHandledByTheNudge() async throws {
        let driver = StraddlingDriver(straddling: true, ghost: true)

        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(tapStep())

        XCTAssertFalse(outcome.driverFallback?.contains("nudged") ?? false,
                       "完全に外の要素を寄せの経路で処理している: \(outcome.driverFallback ?? "-")")
    }

    /// **`containerInference: false` では寄せない**(容器の推測に依存する補正なので)
    func testNudgeIsSkippedWhenContainerInferenceIsOff() async throws {
        let driver = StraddlingDriver(straddling: true)

        _ = await StepExecutor(driver: driver, isAndroid: false).execute(tapStep(containerInference: false))

        XCTAssertEqual(driver.drags, 0, "補正を切ったのに寄せている")
    }

    // MARK: - straddleJump(寄せ量は最小 + 実行下限の床上げ)

    private func element(y: Double, height: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "b", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 100, height: height), depth: 1)
    }
    private let container = FTRect(x: 0, y: 100, width: 402, height: 600)

    /// 下端またぎ: 必要量が床(60)未満なら 60 へ床上げ(dragGesture の実行下限 50 を割ると
    /// 寄せ自体が不発になり、Compose の小さいまたぎで元の対策が効かなくなる)
    func testStraddleJumpFloorsSmallBottomOverflow() {
        // 下端 700 に対し要素の下端 720 = はみ出し 20 + margin 12 = 32 → 床上げで 60
        XCTAssertEqual(StepExecutor.straddleJump(for: element(y: 660, height: 60),
                                                 container: container), 60)
    }

    /// 大きいはみ出しは実量 + margin(40% 位置への寄せ = 観測対象まで流す量にしない。
    /// 2026-08-08 実害: E2E-iOS で echo ラベルが仮想化の外へ流れた)
    func testStraddleJumpUsesActualOverflowWhenLarge() {
        // 要素の下端 900 - 容器の下端 700 = 200 + margin 12 = 212
        XCTAssertEqual(StepExecutor.straddleJump(for: element(y: 840, height: 60),
                                                 container: container), 212)
    }

    /// 上端またぎは負(内容を下へ)
    func testStraddleJumpIsNegativeForTopOverflow() {
        // 上端 100 - 要素の上端 70 = 30 + margin 12 = 42 → 床上げで -60
        XCTAssertEqual(StepExecutor.straddleJump(for: element(y: 70, height: 60),
                                                 container: container), -60)
    }

    /// 完全に中なら nil(寄せない)
    func testStraddleJumpIsNilWhenFullyInside() {
        XCTAssertNil(StepExecutor.straddleJump(for: element(y: 300, height: 60),
                                               container: container))
    }
}
