// LPT 投入順の適用(実績の読み込み側)。
//
// **導入直後(結果 JSON が 1 件も無い)状態で壊れないこと**が最重要。受け手は必ずその状態から
// 始まるので、ここで throw したり順序が壊れたりすると初回実行が丸ごと失敗する。
// 並べ替えの規則そのものは FTCore の LPTSchedulerTests 側で固めている。

import XCTest
import FTCore
@testable import ftester

final class LPTOrderingTests: XCTestCase {

    private var tempDir: URL!
    private var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTesterTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("Projects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ id: String) -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, app: "SampleApp",
                                           platform: nil, deleted: false))
    }

    private func ids(_ items: [ScenarioRunItem]) -> [String] { items.map(\.info.id) }

    /// 実際のレイアウト results/runs/<YYYY-MM>/<runID>/scenarios/<id>.json に1件書く。
    private func writeRecord(scenarioID: String, durationMs: Int,
                             startedAt: String = "2026-07-29T00:00:00Z",
                             platform: String = "android",
                             runID: String = "20260729-000000Z-TEST-0001") throws {
        let runDir = project.rootURL
            .appendingPathComponent("results/runs/2026-07/\(runID)/scenarios")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "schemaVersion": 1, "scenarioID": scenarioID, "title": scenarioID,
            "durationMs": durationMs, "passed": true, "timedOut": false,
            "platform": platform, "profile": "android", "machine": "TEST",
            "worker": "エミュ1(android:emulator-5554)",
            "runID": runID, "startedAt": startedAt,
            "reportPath": "reports/x.md", "scenes": [],
            "steps": ["passed": 1, "failed": 0, "healed": 0,
                      "passedViaFallback": 0, "skipped": 0, "total": 1],
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: runDir.appendingPathComponent("\(scenarioID).json"))
    }

    private func apply(_ items: [ScenarioRunItem], enabled: Bool = true,
                       historyRuns: Int = LPTOrdering.defaultHistoryRuns) -> (
        items: [ScenarioRunItem], logs: [String]
    ) {
        var logs: [String] = []
        let result = LPTOrdering.apply(items, project: project, defaultPlatform: "android",
                                       enabled: enabled, historyRuns: historyRuns,
                                       log: { logs.append($0) })
        return (result, logs)
    }

    // MARK: - 導入直後(実績なし)

    func testNoResultsDirectoryKeepsOriginalOrder() {
        // 受け手が必ず通る状態: results/ がまだ存在しない
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.rootURL.appendingPathComponent("results").path))

        let (result, logs) = apply([item("B"), item("A"), item("C")])
        XCTAssertEqual(ids(result), ["B", "A", "C"], "並べ替えず元の順序のまま返す")
        XCTAssertTrue(logs.isEmpty, "実績が無いときに紛らわしいログを出さない")
    }

    func testEmptyResultsDirectoryKeepsOriginalOrder() throws {
        try FileManager.default.createDirectory(
            at: project.rootURL.appendingPathComponent("results/runs"),
            withIntermediateDirectories: true)

        let (result, logs) = apply([item("B"), item("A")])
        XCTAssertEqual(ids(result), ["B", "A"])
        XCTAssertTrue(logs.isEmpty)
    }

    func testRecordsWithoutUsableDurationKeepOriginalOrder() throws {
        // platform 不一致の skipped 合成レコードだけがある状態(durationMs=0)
        try writeRecord(scenarioID: "A", durationMs: 0)
        try writeRecord(scenarioID: "B", durationMs: 0)

        let (result, logs) = apply([item("B"), item("A")])
        XCTAssertEqual(ids(result), ["B", "A"])
        XCTAssertTrue(logs.isEmpty)
    }

    func testCorruptRecordIsIgnoredNotFatal() throws {
        // 書き込み途中・別スキーマの JSON が混ざっても実行を止めない
        let runDir = project.rootURL
            .appendingPathComponent("results/runs/2026-07/20260729-000000Z-TEST-0001/scenarios")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try Data("{ 壊れている".utf8).write(to: runDir.appendingPathComponent("broken.json"))

        let (result, _) = apply([item("B"), item("A")])
        XCTAssertEqual(ids(result), ["B", "A"])
    }

    // MARK: - 適用しない条件

    func testDisabledKeepsOriginalOrderEvenWithHistory() throws {
        try writeRecord(scenarioID: "A", durationMs: 30_000)
        try writeRecord(scenarioID: "B", durationMs: 1_000)

        let (result, logs) = apply([item("B"), item("A")], enabled: false)
        XCTAssertEqual(ids(result), ["B", "A"], "--no-lpt / 設定 OFF では触らない")
        XCTAssertTrue(logs.isEmpty)
    }

    func testSingleItemIsUntouched() throws {
        try writeRecord(scenarioID: "A", durationMs: 30_000)
        let (result, logs) = apply([item("A")])
        XCTAssertEqual(ids(result), ["A"])
        XCTAssertTrue(logs.isEmpty, "1件なら並べ替えの余地が無いので走査もログも不要")
    }

    // MARK: - 実績がある場合

    func testOrdersByHistoryAndLogsCoverage() throws {
        try writeRecord(scenarioID: "短", durationMs: 1_000)
        try writeRecord(scenarioID: "長", durationMs: 30_000)

        // "新規" は実績なし。先頭に来る
        let (result, logs) = apply([item("短"), item("新規"), item("長")])
        XCTAssertEqual(ids(result), ["新規", "長", "短"])
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("2/3"), "実績のあった件数を出す: \(logs[0])")
    }

    func testHistoryFromAnotherPlatformIsNotUsed() throws {
        // 同じ results/ に iOS と Android の記録が混ざる構成(Projects/E2E 等)。
        // android の run で ios の実績を使うと、遅い iOS 実測で並べてしまう
        try writeRecord(scenarioID: "両対応", durationMs: 30_000, platform: "ios")
        try writeRecord(scenarioID: "Android専用", durationMs: 5_000, platform: "android")

        let (result, logs) = apply([item("Android専用"), item("両対応")])
        XCTAssertEqual(ids(result), ["両対応", "Android専用"],
                       "android の実績が無い「両対応」は実績なし扱いで先頭")
        XCTAssertTrue(logs[0].contains("1/2"), "android の実績があるのは1件: \(logs[0])")
    }

    func testOnlyTheNewestRunsAreScanned() throws {
        // 結果 JSON は run × シナリオ数で増え続ける(実測で 1 プロジェクト 3,500〜4,500 件)。
        // 毎 run 全件読むと run の固定費になるので新しい方から上限件数だけ読む。
        // 「古い run にしか実績が無いシナリオ」は実績なし扱いになることで上限が効いていると分かる。
        try writeRecord(scenarioID: "古いだけ", durationMs: 1_000,
                        runID: "20260701-000000Z-TEST-0000")
        for i in 1...25 {
            try writeRecord(scenarioID: "毎回", durationMs: 5_000,
                            runID: String(format: "20260729-%06dZ-TEST-%04d", i, i))
        }

        let (result, logs) = apply([item("毎回"), item("古いだけ")])
        XCTAssertEqual(ids(result), ["古いだけ", "毎回"],
                       "上限外の run しか実績が無いものは「実績なし」= 先頭")
        XCTAssertTrue(logs[0].contains("1/2"), "実績ありは「毎回」だけ: \(logs[0])")
    }

    func testEmptyRunDirectoryDoesNotConsumeTheWindow() throws {
        // 実行中の run のディレクトリは scanRecords の時点でまだ空(RunRecorder.begin が先に作る)。
        // これを1件と数えると履歴枠を食い、極端には maxRuns=1 で実績ゼロになって LPT が効かなくなる。
        try writeRecord(scenarioID: "長", durationMs: 30_000, runID: "20260729-000001Z-TEST-0001")
        try writeRecord(scenarioID: "短", durationMs: 1_000, runID: "20260729-000001Z-TEST-0001")
        // 実行中の run(空)。名前が新しいので走査は先にこちらへ当たる
        try FileManager.default.createDirectory(
            at: project.rootURL.appendingPathComponent(
                "results/runs/2026-07/20260729-999999Z-TEST-9999/scenarios"),
            withIntermediateDirectories: true)

        // historyRuns=1 が最も厳しい: 空ディレクトリを1件と数えると枠が尽きて実績ゼロになる
        let (result, logs) = apply([item("短"), item("長")], historyRuns: 1)
        XCTAssertEqual(ids(result), ["長", "短"], "空ディレクトリを飛ばして実績のある run を読む")
        XCTAssertEqual(logs.count, 1)
    }

    func testOldRecordsOutsideTheWindowAreIgnored() throws {
        // 直近30日の外の実績は代表値にならない(アプリもシナリオも変わっている)
        try writeRecord(scenarioID: "長", durationMs: 30_000, startedAt: "2020-01-01T00:00:00Z")
        try writeRecord(scenarioID: "短", durationMs: 1_000, startedAt: "2020-01-01T00:00:00Z")

        let (result, logs) = apply([item("短"), item("長")])
        XCTAssertEqual(ids(result), ["短", "長"], "古い実績は使わないので元の順序のまま")
        XCTAssertTrue(logs.isEmpty)
    }
}
