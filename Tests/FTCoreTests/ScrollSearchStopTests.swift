// スクロール探索が**もう動かない画面で上限まで振り続けない**ことを固定する。
//
// 端に着いた後のスワイプは1本も結果を変えないのに、旧実装は maxSwipes(既定 8)まで撃っていた。
// 判定は木の contentSignature が2周続けて同一(1周で切ると、遅れて描画される行を
// 「動かなかった」と誤断して取りこぼす)。

import XCTest
@testable import FTCore

/// swipe 回数と snapshot 回数だけ数える最小ドライバ
private final class CountingDriver: AppDriver {
    /// 何周目でも同じ木を返す = 「振っても動かない」画面
    let frame: [ElementInfo]
    private(set) var swipeCount = 0

    init(frame: [ElementInfo]) { self.frame = frame }

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
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: frame, truncatedCount: 0)
    }
}

/// 1周ごとに木が変わり続ける(= 動いている)画面。最後まで目標は出てこない
private final class MovingDriver: AppDriver {
    private(set) var swipeCount = 0
    private var snapshots = 0

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
        snapshots += 1
        // 整定(1周目)で同じ木を2枚要求されるので、2枚ごとに位置を動かす
        let y = 600 - Double((snapshots - 1) / 2) * 40
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: [ElementInfo(ref: 1, type: "clickable",
                                                       identifier: "anchor", label: "行",
                                                       value: nil, placeholder: nil, enabled: true,
                                                       frame: FTRect(x: 16, y: y,
                                                                     width: 370, height: 56),
                                                       depth: 1)],
                                truncatedCount: 0)
    }
}

final class ScrollSearchStopTests: XCTestCase {

    private static let still = [
        ElementInfo(ref: 1, type: "clickable", identifier: "anchor", label: "行", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 600, width: 370, height: 56), depth: 1)
    ]

    private func scrollTo(_ id: String, maxSwipes: Int) -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: id),
                 direction: "up", maxSwipes: maxSwipes)
    }

    /// **動かない画面では上限より手前で止まる**。判定は2周連続の同一なので、
    /// 撃つのは 2 本(1本目で比較材料を作り、2・3本目の比較で打ち切り)
    func testSearchStopsOnceTheContentNoLongerMoves() async throws {
        let driver = CountingDriver(frame: Self.still)

        let result = await StepExecutor(driver: driver).execute(scrollTo("missing", maxSwipes: 8))

        XCTAssertLessThan(driver.swipeCount, 8,
                          "動かない画面なのに上限まで振っている: \(driver.swipeCount) 回")
        guard case .failed(let reason) = result.status else {
            return XCTFail("見つからない探索は失敗のはず: \(result.status)")
        }
        XCTAssertTrue(reason.contains("stopped early"),
                      "打ち切ったことが理由文に出ていない: \(reason)")
        XCTAssertFalse(reason.contains("after 8 scroll(s)"),
                       "実際には振っていない回数を名乗っている: \(reason)")
    }

    /// **動いている間は打ち切らない**(上限まで使う)。ここが縮むと、
    /// 遅れて現れる行に届かなくなる
    func testSearchKeepsGoingWhileTheContentMoves() async throws {
        let driver = MovingDriver()

        _ = await StepExecutor(driver: driver).execute(scrollTo("missing", maxSwipes: 5))

        XCTAssertEqual(driver.swipeCount, 5,
                       "動いているのに打ち切った: \(driver.swipeCount) 回")
    }
}
