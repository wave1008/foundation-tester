// ScenarioEventLog(events/<fileBase>.ndjson の書き手)の検証。守るもの:
// ①JSON オブジェクトとして読める stdout 行は event へ原文のまま埋まる(未知の欄も残る)
// ②読めない行(stderr は常に)は text へ正しくエスケープされる ③t/stream の形式
// ④並行書き込みで行が壊れない(stdout ループと stderr の Task が同時に append する)
// ⑤finish で <fileBase>.ndjson へ rename される ⑥finish しなければ .inflight-* のまま残る

import Foundation
import XCTest
@testable import FTCore

final class ScenarioEventLogTests: XCTestCase {
    private func tempRunDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScenarioEventLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func eventsDir(_ runDir: URL) -> URL {
        runDir.appendingPathComponent("events")
    }

    /// 1行を JSON オブジェクトへデコードする(壊れていれば nil)
    private func decodeLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    private func readLines(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - ① JSON オブジェクトの stdout 行

    func testJSONObjectStdoutLineEmbedsTheRawEventVerbatim() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        // 未知の欄(futureField)も含めて原文のまま残ることを検証する(ScenarioEvent へ
        // 再エンコードすると未知の欄は消える)
        log.appendStdout(#"{"kind":"log","message":"hi","futureField":42}"#)
        let url = try XCTUnwrap(log.finish(fileBase: "Foo.bar"))

        let lines = try readLines(url)
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(decodeLine(lines[0]))
        XCTAssertEqual(line["stream"] as? String, "stdout")
        XCTAssertNil(line["text"], "JSON オブジェクトの行は text を持たない")
        let event = try XCTUnwrap(line["event"] as? [String: Any])
        XCTAssertEqual(event["kind"] as? String, "log")
        XCTAssertEqual(event["message"] as? String, "hi")
        XCTAssertEqual(event["futureField"] as? Int, 42, "未知の欄も原文のまま残る")
    }

    // MARK: - ② JSON オブジェクトとして読めない行

    func testNonObjectStdoutLineFallsBackToText() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        // 配列・引用符・バックスラッシュ・改行以外の制御文字混じりの生テキスト
        let raw = "plain text with \"quotes\" and a \\backslash\t and [1,2,3]"
        log.appendStdout(raw)
        let url = try XCTUnwrap(log.finish(fileBase: "Foo.plain"))

        let lines = try readLines(url)
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(decodeLine(lines[0]))
        XCTAssertEqual(line["stream"] as? String, "stdout")
        XCTAssertNil(line["event"], "JSON でない行は event を持たない")
        XCTAssertEqual(line["text"] as? String, raw, "エスケープを往復してもとの文字列に戻る")
    }

    /// トップレベルが配列(JSON としては妥当)でも「オブジェクトとして読めるとき」には当たらない
    func testTopLevelJSONArrayIsTreatedAsTextNotEvent() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        log.appendStdout("[1,2,3]")
        let url = try XCTUnwrap(log.finish(fileBase: "Foo.array"))

        let line = try XCTUnwrap(decodeLine(try readLines(url)[0]))
        XCTAssertNil(line["event"])
        XCTAssertEqual(line["text"] as? String, "[1,2,3]")
    }

    // MARK: - stderr は常に text

    func testStderrLineIsAlwaysText() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        log.appendStderr(#"{"kind":"log"}"#)  // JSON っぽくても stderr は text
        let url = try XCTUnwrap(log.finish(fileBase: "Foo.stderr"))

        let line = try XCTUnwrap(decodeLine(try readLines(url)[0]))
        XCTAssertEqual(line["stream"] as? String, "stderr")
        XCTAssertNil(line["event"])
        XCTAssertEqual(line["text"] as? String, #"{"kind":"log"}"#)
    }

    // MARK: - ホスト発イベント(appendHost)

    func testHostEventEmbedsScenarioEventsOwnEncoding() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        var event = ScenarioEvent(kind: "scenarioFinished")
        event.scenario = "Foo.bar"
        event.passed = false
        log.appendHost(event)
        let url = try XCTUnwrap(log.finish(fileBase: "Foo.hostevent"))

        let line = try XCTUnwrap(decodeLine(try readLines(url)[0]))
        XCTAssertEqual(line["stream"] as? String, "host")
        let embedded = try XCTUnwrap(line["event"] as? [String: Any])
        XCTAssertEqual(embedded["kind"] as? String, "scenarioFinished")
        XCTAssertEqual(embedded["scenario"] as? String, "Foo.bar")
        XCTAssertEqual(embedded["passed"] as? Bool, false)
    }

    // MARK: - ③ t / stream の形式

    func testTimestampIsUTCMillisecondISO8601() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        let before = Date()
        log.appendStdout("hello")
        let after = Date()
        let url = try XCTUnwrap(log.finish(fileBase: "Foo.time"))

        let line = try XCTUnwrap(decodeLine(try readLines(url)[0]))
        let t = try XCTUnwrap(line["t"] as? String)
        // 形式: yyyy-MM-ddTHH:mm:ss.SSSZ(固定幅)
        XCTAssertEqual(t.count, 24, t)
        XCTAssertTrue(t.hasSuffix("Z"), t)
        XCTAssertEqual(t[t.index(t.startIndex, offsetBy: 19)], ".", "ミリ秒の区切り: \(t)")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try XCTUnwrap(formatter.date(from: t))
        // 時刻が append 呼び出しを挟む範囲に収まる(1秒の余裕を持たせる)
        XCTAssertGreaterThanOrEqual(parsed.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
        XCTAssertLessThanOrEqual(parsed.timeIntervalSince1970, after.timeIntervalSince1970 + 1)
    }

    // MARK: - ④ 並行書き込みで行が壊れない

    func testConcurrentStdoutAndStderrAppendsProduceIntactLines() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))

        let stdoutCount = 300
        let stderrCount = 300
        let group = DispatchGroup()
        let stdoutQueue = DispatchQueue(label: "stdout-writer")
        let stderrQueue = DispatchQueue(label: "stderr-writer")
        group.enter()
        stdoutQueue.async {
            for i in 0..<stdoutCount {
                log.appendStdout(#"{"kind":"step","index":\#(i)}"#)
            }
            group.leave()
        }
        group.enter()
        stderrQueue.async {
            for i in 0..<stderrCount {
                log.appendStderr("stderr line \(i)")
            }
            group.leave()
        }
        group.wait()
        let url = try XCTUnwrap(log.finish(fileBase: "Foo.concurrent"))

        let lines = try readLines(url)
        XCTAssertEqual(lines.count, stdoutCount + stderrCount, "1行も失われず・1行も裂けない")
        var seenStdoutIndices = Set<Int>()
        var seenStderrIndices = Set<Int>()
        for raw in lines {
            let line = try XCTUnwrap(decodeLine(raw), "壊れた行: \(raw)")
            switch line["stream"] as? String {
            case "stdout":
                let event = try XCTUnwrap(line["event"] as? [String: Any])
                seenStdoutIndices.insert(try XCTUnwrap(event["index"] as? Int))
            case "stderr":
                let text = try XCTUnwrap(line["text"] as? String)
                let index = try XCTUnwrap(Int(text.replacingOccurrences(of: "stderr line ", with: "")))
                seenStderrIndices.insert(index)
            default:
                XCTFail("unexpected stream: \(String(describing: line["stream"]))")
            }
        }
        XCTAssertEqual(seenStdoutIndices, Set(0..<stdoutCount))
        XCTAssertEqual(seenStderrIndices, Set(0..<stderrCount))
    }

    // MARK: - ⑤ finish で rename される

    func testFinishRenamesInflightFileToFileBase() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        let inflightPath = log.inflightURL.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: inflightPath))
        log.appendStdout("hello")

        let finalURL = try XCTUnwrap(log.finish(fileBase: "Foo.bar~2"))
        XCTAssertEqual(finalURL, eventsDir(runDir).appendingPathComponent("Foo.bar~2.ndjson"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inflightPath), ".inflight は残らない")
    }

    /// 2 回目の finish は何もしない(二重 rename でクラッシュしない)
    func testFinishIsIdempotent() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        log.appendStdout("hello")
        XCTAssertNotNil(log.finish(fileBase: "Foo.bar"))
        XCTAssertNil(log.finish(fileBase: "Foo.bar"), "2 回目は何もしない")
    }

    // MARK: - ⑥ finish しなければ .inflight が残る

    func testWithoutFinishTheInflightFileRemains() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        log.appendStdout("hello")
        // finish を呼ばない(kill されたシナリオを模す)

        let entries = try FileManager.default.contentsOfDirectory(atPath: eventsDir(runDir).path)
        XCTAssertEqual(entries.count, 1)
        let name = try XCTUnwrap(entries.first)
        XCTAssertTrue(name.hasPrefix(".inflight-"), name)
        XCTAssertTrue(name.hasSuffix(".ndjson"), name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventsDir(runDir).appendingPathComponent("Foo.bar.ndjson").path))
    }

    // MARK: - 開けない/作れないときは nil(止めない)

    func testStartReturnsNilWhenTheDirectoryCannotBeCreated() throws {
        let root = tempRunDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)  // ディレクトリになるはずの場所に普通のファイルを置く
        let runDir = blocker.appendingPathComponent("sub")

        XCTAssertNil(ScenarioEventLog.start(runDir: runDir))
    }

    // MARK: - 空行は書かない

    func testEmptyLinesAreNotWritten() throws {
        let runDir = tempRunDir()
        defer { try? FileManager.default.removeItem(at: runDir) }
        let log = try XCTUnwrap(ScenarioEventLog.start(runDir: runDir))
        log.appendStdout("")
        log.appendStderr("")
        log.appendStdout("real line")
        let url = try XCTUnwrap(log.finish(fileBase: "Foo.empty"))

        let lines = try readLines(url)
        XCTAssertEqual(lines.count, 1)
    }
}
