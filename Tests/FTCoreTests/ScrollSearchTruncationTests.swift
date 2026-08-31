// スクロール探索の**途中の周回**で木が要素上限に当たっていたことを、失敗した探索が
// 注記として持ち帰ることを固定する(2026-08-12 のブラウザ監査)。
//
// なぜ最終木では足りないか: 目的の行が画面に入っていた周回で打ち切られていても、
// 探索が通り過ぎた先の最終画面は上限に当たらないことがある。そのとき失敗文は
// 「見つからない」としか言わず、**実在する行を不在と読ませる**。実測(tenki.jp の
// 2週間天気)では、この形で同じ探索を2回撃って 101 秒を捨てた。

import XCTest
@testable import FTCore

/// 途中の周回だけ truncatedCount を立て、最後は 0 に戻すドライバ。
/// 目的の要素はどの周回にも居ない(= 探索は必ず失敗する)
private final class TruncatingMidSearchDriver: AppDriver {
    private var snapshots = 0
    /// 打ち切りを申告する snapshot の回数(先頭から数えて)
    private let truncatedUntil: Int

    init(truncatedUntil: Int) { self.truncatedUntil = truncatedUntil }

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
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}

    func snapshot() async throws -> SnapshotResponse {
        snapshots += 1
        // 木は毎周変わる(= 動いている画面。打ち切り検知に「動かないので止めた」を混ぜない)
        let y = 600 - Double((snapshots - 1) / 2) * 40
        return SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [ElementInfo(ref: 1, type: "clickable", identifier: "anchor", label: "行",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 1)],
            truncatedCount: snapshots <= truncatedUntil ? 179 : 0)
    }
}

final class ScrollSearchTruncationTests: XCTestCase {

    private func scrollTo(_ id: String) -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: id), direction: "up", maxSwipes: 3)
    }

    /// **最終木が上限内でも**、途中で打ち切られていたなら注記が付く
    func testTruncationSeenOnlyMidSearchIsReported() async {
        let driver = TruncatingMidSearchDriver(truncatedUntil: 2)
        let result = await StepExecutor(driver: driver, isAndroid: false).execute(scrollTo("missing"))
        XCTAssertTrue(result.notes.contains(.truncatedDuringSearch),
                      "途中の打ち切りが注記に出ていない: \(result.notes)")
    }

    /// 一度も打ち切られていない探索には付けない(付けると毎回出る注記になる)
    func testACleanSearchCarriesNoTruncationNote() async {
        let driver = TruncatingMidSearchDriver(truncatedUntil: 0)
        let result = await StepExecutor(driver: driver, isAndroid: false).execute(scrollTo("missing"))
        XCTAssertFalse(result.notes.contains(.truncatedDuringSearch),
                       "打ち切っていないのに注記が出ている: \(result.notes)")
    }
}
