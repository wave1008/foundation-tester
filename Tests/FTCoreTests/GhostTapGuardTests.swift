// **容器の外に報告された要素(ghost)へのタップを、探索を伴わないステップでも守る**ことを固定する。
//
// iOS(Compose)は可視域の外へ出た行も木に残し、frame は容器の外を指す。掴んだままタップすると
// 容器の外を撃って**画面が何も変わらないまま成功として記録**され、後段の検証だけが落ちる。
// 旧実装は「そのステップ自身が探索した(searchSwiped)」ときだけ守っていたため、
// `scrollTo` と `tap` を別ステップで書く自然な書き方では**防御がまるごと素通り**していた。

import XCTest
@testable import FTCore

/// 容器(#list)と、その**外**に報告される行(ghost)を返すドライバ。
/// 木は動かないので、掴み直しの追加スワイプが撃たれたかだけを観測する
private final class GhostTreeDriver: AppDriver {
    private(set) var swipes = 0
    private(set) var taps = 0
    /// true = 行を容器の中に置く(健全な木)
    let healthy: Bool

    init(healthy: Bool) { self.healthy = healthy }

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
    func tap(ref: Int) async throws { taps += 1 }
    func tap(x: Double, y: Double) async throws { taps += 1 }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipes += 1
    }

    func snapshot() async throws -> SnapshotResponse {
        // 容器 y 400..560。ghost は容器の**完全に外**(y=100)に報告される
        let container = FTRect(x: 16, y: 400, width: 370, height: 160)
        let targetY: Double = healthy ? 420 : 100
        return SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [
                ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil,
                            placeholder: nil, enabled: true, frame: container, depth: 1),
                ElementInfo(ref: 2, type: "clickable", identifier: "row_01", label: "行 01",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: 410, width: 370, height: 56), depth: 2),
                ElementInfo(ref: 3, type: "clickable", identifier: "row_02", label: "行 02",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: 470, width: 370, height: 56), depth: 2),
                ElementInfo(ref: 4, type: "clickable", identifier: "target", label: "対象",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 16, y: targetY, width: 370, height: 56), depth: 2),
            ],
            truncatedCount: 0)
    }
}

final class GhostTapGuardTests: XCTestCase {

    /// **探索していないステップでも ghost を検出して掴み直す**(追加スワイプが出る)。
    /// `searchSwiped` を条件に戻すと、ここは 0 スワイプになって落ちる
    func testGhostIsGuardedEvenWithoutASearchInTheSameStep() async throws {
        let driver = GhostTreeDriver(healthy: false)
        // **timeout は付けない**: DSL の素の `tap` と同じ形。timeout があると再解決だけの
        // 分岐に入り、掴み直し(送り直し)の経路を通らない
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"))

        _ = await StepExecutor(driver: driver).execute(step)

        XCTAssertGreaterThan(driver.swipes, 0,
                             "容器の外に報告された要素をそのままタップしている(掴み直しが発火していない)")
    }

    /// **健全な木では掴み直さない**(容器の中に居る要素に余計なスワイプを撃たない)
    func testHealthyTreeIsTappedWithoutExtraSwipes() async throws {
        let driver = GhostTreeDriver(healthy: true)
        // **timeout は付けない**: DSL の素の `tap` と同じ形。timeout があると再解決だけの
        // 分岐に入り、掴み直し(送り直し)の経路を通らない
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"))

        _ = await StepExecutor(driver: driver).execute(step)

        XCTAssertEqual(driver.swipes, 0, "容器の中に居るのに掴み直している")
        XCTAssertGreaterThan(driver.taps, 0, "タップされていない")
    }

    /// **`containerInference: false` では守らない**(容器の推測に依存する補正なので)
    func testGuardIsSkippedWhenContainerInferenceIsOff() async throws {
        let driver = GhostTreeDriver(healthy: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"),
                            containerInference: false)

        _ = await StepExecutor(driver: driver).execute(step)

        XCTAssertEqual(driver.swipes, 0, "補正を切ったのに掴み直している")
    }
}
