// 複数機械にまたがる実行プロファイルを `ftester api run` で走らせるときの多重化規則
// (ApiRunHostFanout.swift)。ここは HostFanoutMultiplexer(純粋・プロセス非依存)だけを叩く ——
// 子プロセスを立てずに「NDJSON の行の並びを渡すとどう変換されるか」を等号で固定する。

import XCTest
@testable import ftester

final class ApiRunHostFanoutMultiplexerTests: XCTestCase {

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
        var mux = HostFanoutMultiplexer(groupHosts: [nil])
        XCTAssertEqual(mux.ingest(childIndex: 0, line: #"{"kind":"runStarted","total":3}"#), [])
    }

    func testRunFinishedIsDroppedAndSummedAcrossHosts() {
        var mux = HostFanoutMultiplexer(groupHosts: [nil, "M1Max"])
        // 揃うまでの経路を通す(workersReady を先に両方出す)
        _ = mux.ingest(childIndex: 0, line: #"{"kind":"workersReady","workers":[]}"#)
        _ = mux.ingest(childIndex: 1, line: #"{"kind":"workersReady","workers":[]}"#)

        XCTAssertEqual(mux.ingest(childIndex: 0, line: #"{"kind":"runFinished","passed":2,"failed":1}"#), [])
        XCTAssertEqual(mux.ingest(childIndex: 1, line: #"{"kind":"runFinished","passed":5,"failed":0}"#), [])
        XCTAssertEqual(mux.totalPassed, 7)
        XCTAssertEqual(mux.totalFailed, 1)
    }

    // MARK: - workersReady は揃うまで合成しない。揃うまでの他イベントは順序を保って後に流れる

    func testWorkersReadyMergesOnceAllChildrenSettleAndFlushesBufferedLinesInOrder() {
        var mux = HostFanoutMultiplexer(groupHosts: [nil, "M1Max"])

        // child 1(M1Max)の step が child 1 の workersReady より先に届く —— まだ揃っていないので貯める
        let preReadyLine = #"{"kind":"step","worker":"android:Pixel 10","description":"tap #foo"}"#
        XCTAssertEqual(mux.ingest(childIndex: 1, line: preReadyLine), [])

        // child 0(手元)が先に揃う。まだ child 1 が来ていないので何も出さない
        let localReady = #"{"kind":"workersReady","workers":[{"name":"iPhone A","platform":"ios","detail":"port 8123"}]}"#
        XCTAssertEqual(mux.ingest(childIndex: 0, line: localReady), [])

        // child 1 が揃って初めて合成 workersReady + 貯めていた行(順序どおり)が出る
        let remoteReady = #"{"kind":"workersReady","workers":[{"name":"Pixel 10","platform":"android","detail":"serial X"}]}"#
        let flushed = mux.ingest(childIndex: 1, line: remoteReady)

        XCTAssertEqual(flushed.count, 2, "合成 workersReady 1行 + 貯めていた step 1行")
        let merged = jsonObject(flushed[0])
        XCTAssertEqual(merged["kind"] as? String, "workersReady")
        let workers = merged["workers"] as? [[String: Any]] ?? []
        XCTAssertEqual(workers.count, 2)

        let local = workers.first { ($0["platform"] as? String) == "ios" }
        XCTAssertEqual(local?["id"] as? String, "ios:iPhone A", "手元の id は host 無しのまま")
        XCTAssertNil(local?["machineHost"], "手元のワーカーに machineHost は載らない")

        let remote = workers.first { ($0["platform"] as? String) == "android" }
        XCTAssertEqual(remote?["id"] as? String, "android:M1Max/Pixel 10", "リモートの id は host 付き")
        XCTAssertEqual(remote?["machineHost"] as? String, "M1Max", "リモートのワーカーには machineHost が載る")

        let flushedStep = jsonObject(flushed[1])
        XCTAssertEqual(flushedStep["worker"] as? String, "android:M1Max/Pixel 10",
                       "貯めていた行の worker も合成の直後にホスト付きへ書き換わっている")
    }

    // MARK: - worker フィールドの書き換え

    func testWorkerFieldIsRehostedForRemoteGroup() {
        var mux = HostFanoutMultiplexer(groupHosts: ["M1Max"])
        _ = mux.ingest(childIndex: 0, line: #"{"kind":"workersReady","workers":[]}"#)  // ready にしておく
        let line = #"{"kind":"log","worker":"ios:iPhone 17 Pro","message":"hello"}"#
        let out = mux.ingest(childIndex: 0, line: line)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(jsonObject(out[0])["worker"] as? String, "ios:M1Max/iPhone 17 Pro")
    }

    /// 手元(host == nil)の id は既存契約どおり1バイトも変えない —— 行そのものが無加工で通ること
    func testWorkerFieldIsUntouchedForLocalGroup() {
        var mux = HostFanoutMultiplexer(groupHosts: [nil])
        _ = mux.ingest(childIndex: 0, line: #"{"kind":"workersReady","workers":[]}"#)
        let line = #"{"kind":"log","worker":"ios:iPhone 17 Pro","message":"hello"}"#
        let out = mux.ingest(childIndex: 0, line: line)
        XCTAssertEqual(out, [line], "手元は書き換えず元の行をそのまま通す")
    }

    /// worker を持たない行(wipeStatus 等)はそのまま素通しする
    func testLinesWithoutAWorkerFieldPassThroughUnchanged() {
        var mux = HostFanoutMultiplexer(groupHosts: ["M1Max"])
        _ = mux.ingest(childIndex: 0, line: #"{"kind":"workersReady","workers":[]}"#)
        let line = #"{"kind":"wipeStatus","device":"Pixel 10","phase":"rebooting"}"#
        XCTAssertEqual(mux.ingest(childIndex: 0, line: line), [line])
    }

    // MARK: - workersReady を出さずに終了した子で止まらない

    func testChildThatExitsWithoutWorkersReadyDoesNotBlockTheOthers() {
        var mux = HostFanoutMultiplexer(groupHosts: [nil, "M1Max"])
        XCTAssertEqual(mux.ingest(childIndex: 0, line:
            #"{"kind":"workersReady","workers":[{"name":"iPhone A","platform":"ios","detail":""}]}"#), [])

        // child 1 は起動に失敗するなどして workersReady を1度も出さずに終了する
        let out = mux.childExited(1)
        XCTAssertEqual(out.count, 1, "child 0 だけの workersReady が合成されて出る")
        let merged = jsonObject(out[0])
        let workers = merged["workers"] as? [[String: Any]] ?? []
        XCTAssertEqual(workers.count, 1)
        XCTAssertEqual(workers.first?["id"] as? String, "ios:iPhone A")
    }
}
