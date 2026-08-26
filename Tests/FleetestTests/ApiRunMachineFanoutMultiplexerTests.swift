// 複数機械にまたがる実行プロファイルを `fleetest api run` で走らせるときの多重化規則
// (ApiRunMachineFanout.swift)。ここは MachineFanoutMultiplexer(純粋・プロセス非依存)だけを叩く ——
// 子プロセスを立てずに「NDJSON の行の並びを渡すとどう変換されるか」を等号で固定する。
// workersReady はバッファせず子ごとに累積再送・他のイベントも即時中継(2026-08-18 契約変更)。

import XCTest
@testable import fleetest

final class ApiRunMachineFanoutMultiplexerTests: XCTestCase {

    private func jsonObject(_ line: String, file: StaticString = #filePath, testLine: UInt = #line) -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("not a JSON object: \(line)", file: file, line: testLine)
            return [:]
        }
        return obj
    }

    // MARK: - runStarted/runFinished は捨てて集計する

    func testRunStartedIsAlwaysDropped() {
        var mux = MachineFanoutMultiplexer(groupMachines: [nil])
        XCTAssertEqual(mux.ingest(childIndex: 0, line: #"{"kind":"runStarted","total":3}"#), [])
    }

    func testRunFinishedIsDroppedAndSummedAcrossHosts() {
        var mux = MachineFanoutMultiplexer(groupMachines: [nil, "M1Max"])
        XCTAssertEqual(mux.ingest(childIndex: 0, line: #"{"kind":"runFinished","passed":2,"failed":1}"#), [])
        XCTAssertEqual(mux.ingest(childIndex: 1, line: #"{"kind":"runFinished","passed":5,"failed":0}"#), [])
        XCTAssertEqual(mux.totalPassed, 7)
        XCTAssertEqual(mux.totalFailed, 1)
    }

    // MARK: - workersReady は子ごとに届くたび累積で再送する(バッファしない)

    func testWorkersReadyResendsCumulativelyPerChild() {
        var mux = MachineFanoutMultiplexer(groupMachines: [nil, "M1Max"])

        let localReady = #"{"kind":"workersReady","workers":[{"name":"iPhone A","platform":"ios","detail":"port 8123"}]}"#
        let first = mux.ingest(childIndex: 0, line: localReady)
        XCTAssertEqual(first.count, 1)
        let firstWorkers = jsonObject(first[0])["workers"] as? [[String: Any]] ?? []
        XCTAssertEqual(firstWorkers.count, 1, "child0 だけの再送(child1 はまだ届いていない)")
        XCTAssertEqual(firstWorkers.first?["id"] as? String, "ios:iPhone A")

        let remoteReady = #"{"kind":"workersReady","workers":[{"name":"Pixel 10","platform":"android","detail":"serial X"}]}"#
        let second = mux.ingest(childIndex: 1, line: remoteReady)
        XCTAssertEqual(second.count, 1)
        let secondObj = jsonObject(second[0])
        XCTAssertEqual(secondObj["kind"] as? String, "workersReady")
        let secondWorkers = secondObj["workers"] as? [[String: Any]] ?? []
        XCTAssertEqual(secondWorkers.count, 2, "child0 + child1 の累積(子 index 順)")

        let local = secondWorkers.first { ($0["platform"] as? String) == "ios" }
        XCTAssertEqual(local?["id"] as? String, "ios:iPhone A", "手元の id は host 無しのまま")
        XCTAssertNil(local?["machine"], "手元のワーカーに machine は載らない")

        let remote = secondWorkers.first { ($0["platform"] as? String) == "android" }
        XCTAssertEqual(remote?["id"] as? String, "android:M1Max/Pixel 10", "リモートの id は host 付き")
        XCTAssertEqual(remote?["machine"] as? String, "M1Max", "リモートのワーカーには machine が載る")
    }

    /// workersReady を出していない子の行も待たせず、その場で(rehost だけして)返る
    func testOtherEventsAreRelayedImmediatelyWithoutWaitingForWorkersReady() {
        var mux = MachineFanoutMultiplexer(groupMachines: [nil, "M1Max"])
        let line = #"{"kind":"step","worker":"android:Pixel 10","description":"tap #foo"}"#
        let out = mux.ingest(childIndex: 1, line: line)
        XCTAssertEqual(out.count, 1, "workersReady を待たず即時に返る")
        XCTAssertEqual(jsonObject(out[0])["worker"] as? String, "android:M1Max/Pixel 10")
    }

    // MARK: - worker フィールドの書き換え

    func testWorkerFieldIsRehostedForRemoteGroup() {
        var mux = MachineFanoutMultiplexer(groupMachines: ["M1Max"])
        let line = #"{"kind":"log","worker":"ios:iPhone 17 Pro","message":"hello"}"#
        let out = mux.ingest(childIndex: 0, line: line)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(jsonObject(out[0])["worker"] as? String, "ios:M1Max/iPhone 17 Pro")
    }

    /// 手元(host == nil)の id は既存契約どおり1バイトも変えない —— 行そのものが無加工で通ること
    func testWorkerFieldIsUntouchedForLocalGroup() {
        var mux = MachineFanoutMultiplexer(groupMachines: [nil])
        let line = #"{"kind":"log","worker":"ios:iPhone 17 Pro","message":"hello"}"#
        XCTAssertEqual(mux.ingest(childIndex: 0, line: line), [line], "手元は書き換えず元の行をそのまま通す")
    }

    /// worker を持たない行(wipeStatus 等)はそのまま素通しする
    func testLinesWithoutAWorkerFieldPassThroughUnchanged() {
        var mux = MachineFanoutMultiplexer(groupMachines: ["M1Max"])
        let line = #"{"kind":"wipeStatus","device":"Pixel 10","phase":"rebooting"}"#
        XCTAssertEqual(mux.ingest(childIndex: 0, line: line), [line])
    }

    // MARK: - 子が担当シナリオを残して終了したら failed を合成する

    func testChildExitLeavesUnfinishedScenariosSynthesizedAsFailed() {
        var mux = MachineFanoutMultiplexer(
            groupMachines: [nil, "M1Max"],
            assignedScenarioIDs: [["A.S1"], ["B.S1", "B.S2"]])

        XCTAssertEqual(mux.ingest(childIndex: 1, line:
            #"{"kind":"scenarioFinished","scenario":"B.S1","passed":true}"#).count, 1)

        let out = mux.childExited(1, exitCode: 1)
        XCTAssertEqual(out.count, 3, "log 1 + B.S2 の step failed + scenarioFinished passed:false")

        let log = jsonObject(out[0])
        XCTAssertEqual(log["kind"] as? String, "log")

        let step = jsonObject(out[1])
        XCTAssertEqual(step["kind"] as? String, "step")
        XCTAssertEqual(step["scenario"] as? String, "B.S2")
        XCTAssertEqual(step["status"] as? String, "failed")

        let finished = jsonObject(out[2])
        XCTAssertEqual(finished["kind"] as? String, "scenarioFinished")
        XCTAssertEqual(finished["scenario"] as? String, "B.S2")
        XCTAssertEqual(finished["passed"] as? Bool, false)

        XCTAssertEqual(mux.totalFailed, 1, "B.S1 は完了済みなので合成されない")
    }

    func testChildExitWithAllScenariosFinishedSynthesizesNothing() {
        var mux = MachineFanoutMultiplexer(groupMachines: [nil], assignedScenarioIDs: [["A.S1"]])
        _ = mux.ingest(childIndex: 0, line: #"{"kind":"scenarioFinished","scenario":"A.S1","passed":true}"#)
        XCTAssertEqual(mux.childExited(0, exitCode: 0), [])
        XCTAssertEqual(mux.totalFailed, 0)
    }
}
