// `ftester run --broadcast`(ブロードキャスト)の分配計画を固定する。
// デバイスが要る部分(供給・復帰)は通常 run と同じ経路なので、ここで固めるのは
// 「誰が何本回すか」「(シナリオ × デバイス) が別キーになるか」だけ。
// 破れ方はどれも**緑の run に現れない**(台が1つ抜けても残りが緑・キーが重なっても
// 最後に走った1本の結果だけが残る)ので、単体で固定する価値がある。

import XCTest
@testable import FTCore

private struct UnusedDriver: AppDriver {
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                         elements: [], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class BroadcastPlanTests: XCTestCase {

    private func item(_ id: String, platform: String? = nil) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, app: "App", platform: platform, deleted: false))
    }

    private let lanes = [
        BroadcastLane(key: "iPhone-01", platform: "ios"),
        BroadcastLane(key: "iPhone-02", platform: "ios"),
        BroadcastLane(key: "Pixel-01", platform: "android"),
    ]

    // MARK: - 配り方

    /// platform 未指定は全レーンへ、明示は同じ platform のレーンだけへ。総数 = Σ レーンの本数
    func testEveryLaneGetsItsApplicableShare() {
        let items = [item("Warm.all"), item("Warm.ios", platform: "ios"), item("Warm.android", platform: "android")]
        let plan = BroadcastPlan.make(items: items, lanes: lanes)
        XCTAssertEqual(plan.queues["iPhone-01"]?.map(\.info.id), ["Warm.all", "Warm.ios"])
        XCTAssertEqual(plan.queues["iPhone-02"]?.map(\.info.id), ["Warm.all", "Warm.ios"])
        XCTAssertEqual(plan.queues["Pixel-01"]?.map(\.info.id), ["Warm.all", "Warm.android"])
        XCTAssertEqual(plan.total, 6)
        XCTAssertTrue(plan.unassigned.isEmpty)
    }

    /// 入力の順序(LPT が並べた順)をレーン内でそのまま保つ
    func testOrderWithinALaneFollowsTheInput() {
        let items = [item("C"), item("A"), item("B")]
        let plan = BroadcastPlan.make(items: items, lanes: lanes)
        XCTAssertEqual(plan.queues["iPhone-01"]?.map(\.info.id), ["C", "A", "B"])
    }

    /// 宣言 platform のレーンが1つも無い item は unassigned(shared の「担当ワーカーなし」と同じ扱い)。
    /// 黙って落とすと「全台で走った」顔の緑になる
    func testItemWithNoLaneOfItsPlatformIsUnassigned() {
        let plan = BroadcastPlan.make(items: [item("Only.android", platform: "android")],
                                      lanes: [BroadcastLane(key: "iPhone-01", platform: "ios")])
        XCTAssertEqual(plan.unassigned.map(\.info.id), ["Only.android"])
        XCTAssertEqual(plan.total, 0)
        XCTAssertTrue(plan.queues.isEmpty, "0本のレーンはキューを作らない")
    }

    /// 同じ key のレーンは先勝ち(重ねると同じキューを2ワーカーが取り合い、片方に走らない本が出る)
    func testDuplicateLaneKeysCollapse() {
        let plan = BroadcastPlan.make(
            items: [item("X")],
            lanes: [BroadcastLane(key: "dup", platform: "ios"), BroadcastLane(key: "dup", platform: "android")])
        XCTAssertEqual(plan.queues.count, 1)
        XCTAssertEqual(plan.total, 1)
    }

    // MARK: - (シナリオ × デバイス) のキー

    /// 同じ ID でもレーンが違えば URL が違う(表示バッファ・稼働集計・requeue 回数は URL で持つ)。
    /// `lastPathComponent` は ID のまま(flowSkipped の表示が ID を出す契約)
    func testLaneIsStampedAndMakesTheURLDistinct() {
        let plan = BroadcastPlan.make(items: [item("Warm.all")], lanes: lanes)
        let a = plan.queues["iPhone-01"]!.first!
        let b = plan.queues["iPhone-02"]!.first!
        XCTAssertEqual(a.lane, "iPhone-01")
        XCTAssertEqual(b.lane, "iPhone-02")
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertNotEqual(a.url, ScenarioRunItem(info: a.info).url, "lane 無しの URL とも別キー")
        XCTAssertEqual(a.url.lastPathComponent, "Warm.all")
        XCTAssertEqual(a.url.scheme, "scenario")
    }

    /// デバイス名の記号("(" ")" ":" "&" 日本語)が URL を壊さない
    func testLaneNamesWithSymbolsStillProduceAValidURL() {
        let name = "iPhone 17 Pro(iOS 26):実機&A"
        let plan = BroadcastPlan.make(items: [item("日本語.S0010")],
                                      lanes: [BroadcastLane(key: name, platform: "ios")])
        let url = plan.queues[name]!.first!.url
        XCTAssertEqual(url.scheme, "scenario")
        XCTAssertEqual(url.lastPathComponent, "日本語.S0010")
        XCTAssertTrue(url.absoluteString.contains("?lane="))
        XCTAssertNotEqual(url, ScenarioRunItem(info: plan.queues[name]!.first!.info).url)
    }

    // MARK: - ワーカーとレーンの突き合わせ

    /// プロファイル経路は logicalName(復帰でポート=label が変わっても同じ台は同じレーン)。
    /// 非プロファイル経路は label
    func testLaneKeyUsesLogicalNameAndFallsBackToLabel() {
        let profiled = RunWorker(label: "iPhone-01(ios:8123)", platform: "ios", driver: UnusedDriver(),
                                 connection: DriverConnection(platform: "ios", physical: false),
                                 logicalName: "iPhone-01")
        let revived = RunWorker(label: "iPhone-01(ios:8140)", platform: "ios", driver: UnusedDriver(),
                                connection: DriverConnection(platform: "ios", physical: false),
                                logicalName: "iPhone-01")
        let bare = RunWorker(label: "ios:8123", platform: "ios", driver: UnusedDriver(),
                             connection: DriverConnection(platform: "ios", physical: false))
        XCTAssertEqual(BroadcastPlan.laneKey(of: profiled), "iPhone-01")
        XCTAssertEqual(BroadcastPlan.laneKey(of: revived), BroadcastPlan.laneKey(of: profiled))
        XCTAssertEqual(BroadcastPlan.laneKey(of: bare), "ios:8123")
    }

    /// discardLast(worker:) に渡す名は、記録の worker(ScenarioRecording.worker)と同じ規則
    func testRecordingWorkerMatchesTheRecordedWorkerFormat() {
        let worker = RunWorker(label: "Pixel-01(android:emulator-5554)", platform: "android",
                               driver: UnusedDriver(),
                               connection: DriverConnection(platform: "android", physical: false),
                               logicalName: "Pixel-01")
        XCTAssertEqual(ScenarioRunner.recordingWorker(worker), "android:Pixel-01")
    }
}
