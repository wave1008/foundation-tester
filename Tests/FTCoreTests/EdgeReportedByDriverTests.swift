// ドライバが「もう端」と言えるときは、ホストが署名の2回不変を待たずに切り上げることの固定
//。位置を直接動かせる経路(Android の CDP・in-app の contentOffset)は
// 「余地が無い」を**事実として**知っており、こちらの推測(木の署名)より強い。
//
// **確認の読みは1回だけ残す**: 端に着いた後に内容が伸びる画面(遅延読み込み)があるので、
// 木が変わっていたらループへ戻る。ここが落ちると「端まで行ったつもりで途中で止まる」。

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

    /// 申告があれば**確認の読み1回**で終わる。従来は「不変が2回」まで振り続けていた
    func testStopsAsSoonAsTheDriverReportsTheEdge() async throws {
        let driver = EdgeReportingDriver(edgeAfter: 2)
        let outcome = await StepExecutor(driver: driver).execute(edgeStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertNil(outcome.driverFallback,
                     "上限打ち切りの注記が出ている = 端と認識できていない: \(outcome.driverFallback ?? "-")")
        XCTAssertLessThanOrEqual(driver.snapshotCount, 8,
                                 "申告を受けても読み続けている(\(driver.snapshotCount) 枚)")
    }

    /// **申告の後に内容が伸びたらループへ戻る**(遅延読み込みの画面で途中で止まらない)。
    /// ここが無いと「端に着いた」と言われた時点で終わり、続きを見ない
    func testKeepsGoingWhenTheTreeChangedAfterTheReportedEdge() async throws {
        let driver = EdgeReportingDriver(edgeAfter: 2, growsAfterEdge: true)
        let outcome = await StepExecutor(driver: driver).execute(edgeStep())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertGreaterThan(driver.snapshotCount, 4,
                             "伸びた木を見ずに終わっている(\(driver.snapshotCount) 枚)")
        // **申告の後に木が変わったらループへ戻る**こと。比較の向きが逆だと、変わった時点で
        // 「端に着いた」と決めて止まる = 伸びたぶんを送らないまま終わる
        XCTAssertGreaterThanOrEqual(driver.swipeCount, 3,
                                    "申告の直後に止まっている(\(driver.swipeCount) 本)"
                                    + " —— 伸びたぶんを送らないまま終わる")
    }
}
