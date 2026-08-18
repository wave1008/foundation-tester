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
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
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
                             machine: String = "TEST",
                             runID: String = "20260729-000000Z-TEST-0001") throws {
        let runDir = project.rootURL
            .appendingPathComponent("results/runs/2026-07/\(runID)/scenarios")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "schemaVersion": 1, "scenarioID": scenarioID, "title": scenarioID,
            "durationMs": durationMs, "passed": true, "timedOut": false,
            "platform": platform, "profile": "android", "machine": machine,
            "worker": "エミュ1(android:emulator-5554)",
            "runID": runID, "startedAt": startedAt,
            "reportPath": "reports/x.md", "scenes": [],
            "steps": ["passed": 1, "failed": 0, "healed": 0,
                      "passedViaFallback": 0, "skipped": 0, "total": 1],
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: runDir.appendingPathComponent("\(scenarioID).json"))
    }

    /// machine は既定で RunRecorder.currentMachine()(このテスト実行機のホスト名相当)。
    /// writeRecord の既定 machine は "TEST" なので、machine を明示しないテストは
    /// 「同一 machine の実績なし → 混合中央値へフォールバック」を通る(従来と同一の並び)。
    private func apply(_ items: [ScenarioRunItem], enabled: Bool = true,
                       historyRuns: Int = LPTOrdering.defaultHistoryRuns,
                       machine: String = RunRecorder.currentMachine()) -> (
        items: [ScenarioRunItem], logs: [String]
    ) {
        var logs: [String] = []
        let result = LPTOrdering.apply(items, project: project, defaultPlatform: "android",
                                       enabled: enabled, historyRuns: historyRuns,
                                       machine: machine, log: { logs.append($0) })
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
        // 同じ results/ に iOS と Android の記録が混ざる構成(TestProjects/E2E-CMP 等)。
        // android の run で ios の実績を使うと、遅い iOS 実測で並べてしまう
        try writeRecord(scenarioID: "両対応", durationMs: 30_000, platform: "ios")
        try writeRecord(scenarioID: "Android専用", durationMs: 5_000, platform: "android")

        let (result, logs) = apply([item("Android専用"), item("両対応")])
        XCTAssertEqual(ids(result), ["両対応", "Android専用"],
                       "android の実績が無い「両対応」は実績なし扱いで先頭")
        XCTAssertTrue(logs[0].contains("1/2"), "android の実績があるのは1件: \(logs[0])")
    }

    /// 窓は**シナリオごとの観測数**なので、他のシナリオだけを含む run が何本挟まっても
    /// 実績は残る。**これが 2026-08-11 に直した実害** —— 調査中の1シナリオ実行を数本走らせただけで、
    /// 直前のフル run の実績が全部消えていた(フル E2E で iOS 側が軒並み `1/N with history`)
    func testHistorySurvivesRunsThatContainOtherScenariosOnly() throws {
        try writeRecord(scenarioID: "たまにしか回らない", durationMs: 1_000,
                        runID: "20260729-000000Z-TEST-0000")
        for i in 1...25 {
            try writeRecord(scenarioID: "毎回", durationMs: 5_000,
                            runID: String(format: "20260729-%06dZ-TEST-%04d", i, i))
        }

        let (result, logs) = apply([item("毎回"), item("たまにしか回らない")])
        XCTAssertEqual(ids(result), ["毎回", "たまにしか回らない"], "実績どおり長い方が先")
        XCTAssertTrue(logs[0].contains("2/2"), "両方に実績があること: \(logs[0])")
    }

    /// 遡りは無制限ではない。結果 JSON は run × シナリオ数で増え続ける(実測で 1 プロジェクト
    /// 3,500〜4,500 件)ので、走査する run ディレクトリ数に上限を置く
    /// (`RunResultsStore.observationScanLimitFactor` 倍)。上限の外にしか実績が無いものは
    /// 「実績なし」= 先頭へ
    func testScanBacksOffAtTheDirectoryLimit() throws {
        try writeRecord(scenarioID: "古いだけ", durationMs: 1_000,
                        runID: "20260729-000000Z-TEST-0000")
        let beyondLimit = LPTOrdering.defaultHistoryRuns * RunResultsStore.observationScanLimitFactor + 5
        for i in 1...beyondLimit {
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

    func testOtherPlatformRunsDoNotConsumeTheWindow() throws {
        // 実害(2026-07-30): E2E / E2E-Flutter は iOS と Android を別プロファイルで回すので
        // 同じ results/ に両 platform の run が溜まる。履歴枠を platform 非対応で数えていたため
        // iOS の run と 1 シナリオだけの run で窓が埋まり、android の直近フル run が押し出されて
        // 実績 1/31・2/29 まで落ち、投入順が ID 順同然へ戻った(実行スパン +6s / +10s)。
        try writeRecord(scenarioID: "長", durationMs: 30_000, platform: "android",
                        runID: "20260729-000001Z-TEST-0001")
        try writeRecord(scenarioID: "短", durationMs: 1_000, platform: "android",
                        runID: "20260729-000001Z-TEST-0001")
        // android の run より新しい ios の run を、既定の枠数ちょうど積む(枠を食う条件の境界)
        for i in 1...LPTOrdering.defaultHistoryRuns {
            try writeRecord(scenarioID: "長", durationMs: 90_000, platform: "ios",
                            runID: String(format: "20260729-10%04dZ-TEST-1%03d", i, i))
        }

        let (result, logs) = apply([item("短"), item("長")])
        XCTAssertEqual(ids(result), ["長", "短"], "ios の run で窓を埋めても android の実績で並べる")
        XCTAssertTrue(logs[0].contains("2/2"),
                      "android の実績が2件とも窓に入っている: \(logs[0])")
    }

    func testWindowScanIsBoundedWhenPlatformHasNoRecentRuns() throws {
        // 対象 platform を遡る走査は maxRuns の8倍で打ち切る(片 platform だけ長期間回していない
        // プロジェクトで窓の全 run を読まないための頭打ち)。打ち切ったら実績なし = 元の順序へ
        // 安全側に倒れる。上限を外すとこのテストは「実績あり」に変わって落ちる。
        try writeRecord(scenarioID: "長", durationMs: 30_000, platform: "android",
                        runID: "20260729-000001Z-TEST-0001")
        try writeRecord(scenarioID: "短", durationMs: 1_000, platform: "android",
                        runID: "20260729-000001Z-TEST-0001")
        for i in 1...(LPTOrdering.defaultHistoryRuns * 8 + 1) {
            try writeRecord(scenarioID: "ios専用", durationMs: 90_000, platform: "ios",
                            runID: String(format: "20260729-10%04dZ-TEST-1%03d", i, i))
        }

        let (result, logs) = apply([item("短"), item("長")])
        XCTAssertEqual(ids(result), ["短", "長"], "打ち切ったら並べ替えない(元の順序)")
        XCTAssertTrue(logs[0].contains("0/2"), "android の実績は窓に入らない: \(logs[0])")
    }

    func testOldRecordsOutsideTheWindowAreIgnored() throws {
        // 直近30日の外の実績は代表値にならない(アプリもシナリオも変わっている)
        try writeRecord(scenarioID: "長", durationMs: 30_000, startedAt: "2020-01-01T00:00:00Z")
        try writeRecord(scenarioID: "短", durationMs: 1_000, startedAt: "2020-01-01T00:00:00Z")

        let (result, logs) = apply([item("短"), item("長")])
        XCTAssertEqual(ids(result), ["短", "長"], "古い実績は使わないので元の順序のまま")
        XCTAssertTrue(logs.isEmpty)
    }

    // MARK: - machine 優先(2026-08-18・リモート実行の回収記録との混在)

    /// 同一 machine の実績があればそれだけで並べる。他機のほうが件数が多くても混ざらない
    func testSameMachinePreferredOverMixedHistory() throws {
        try writeRecord(scenarioID: "S", durationMs: 1_000, machine: "この機械",
                        runID: "20260729-000001Z-TEST-0001")
        try writeRecord(scenarioID: "S", durationMs: 90_000, machine: "リモート機",
                        runID: "20260729-000002Z-TEST-0002")
        try writeRecord(scenarioID: "T", durationMs: 5_000, machine: "リモート機",
                        runID: "20260729-000002Z-TEST-0002")

        let (result, logs) = apply([item("T"), item("S")], machine: "この機械")
        XCTAssertEqual(ids(result), ["T", "S"],
                       "S は同一機の実績(1,000ms)で評価され、リモート機の90,000msに引きずられない")
        XCTAssertTrue(logs[0].contains("(same-machine runs preferred)"))
    }

    /// 同一 machine の実績が無いシナリオは全 machine 混合の中央値へフォールバックする
    func testFallsBackToMixedHistoryWhenNoSameMachineRecords() throws {
        try writeRecord(scenarioID: "S", durationMs: 30_000, machine: "リモート機")
        try writeRecord(scenarioID: "T", durationMs: 1_000, machine: "リモート機")

        let (result, logs) = apply([item("T"), item("S")], machine: "この機械")
        XCTAssertEqual(ids(result), ["S", "T"], "この機械の実績が無いので混合(リモート機)の中央値で並ぶ")
        XCTAssertTrue(logs[0].contains("2/2"))
    }
}
