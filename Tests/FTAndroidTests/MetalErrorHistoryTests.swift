// MetalErrorHistory の NDJSON 追記・変化時のみ記録・ローテーションを検証する。
// serial は各テストでユニークにすること(in-memory の直近値辞書は serial キーでグローバル共有)。

import XCTest
@testable import FTAndroid

final class MetalErrorHistoryTests: XCTestCase {
    var historyFile: URL!

    override func setUpWithError() throws {
        MetalErrorHistory._resetForTesting()
        historyFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MetalErrorHistoryTests-\(UUID().uuidString).ndjson")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: historyFile)
        let rotated = historyFile.deletingLastPathComponent()
            .appendingPathComponent(historyFile.lastPathComponent + ".1")
        try? FileManager.default.removeItem(at: rotated)
    }

    private func readLines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: historyFile.path) else { return [] }
        let text = try String(contentsOf: historyFile, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    func testSameCountIsNotAppendedTwice() throws {
        let serial = "emulator-\(UUID().uuidString)"
        MetalErrorHistory.record(avdID: "avd1", serial: serial, count: 5, file: historyFile)
        MetalErrorHistory.record(avdID: "avd1", serial: serial, count: 5, file: historyFile)
        let lines = try readLines()
        XCTAssertEqual(lines.count, 1)
    }

    func testChangedCountIsAppended() throws {
        let serial = "emulator-\(UUID().uuidString)"
        MetalErrorHistory.record(avdID: "avd1", serial: serial, count: 5, file: historyFile)
        MetalErrorHistory.record(avdID: "avd1", serial: serial, count: 6, file: historyFile)
        let lines = try readLines()
        XCTAssertEqual(lines.count, 2)
    }

    func testLineFormatContainsExpectedKeys() throws {
        let serial = "emulator-\(UUID().uuidString)"
        MetalErrorHistory.record(avdID: "avd-format", serial: serial, count: 42, file: historyFile)
        let lines = try readLines()
        XCTAssertEqual(lines.count, 1)
        let data = Data(lines[0].utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["avd"] as? String, "avd-format")
        XCTAssertEqual(json["serial"] as? String, serial)
        XCTAssertEqual(json["count"] as? Int, 42)
        XCTAssertNotNil(json["ts"] as? String)
    }

    func testIntMaxSentinelIsRecordedAsMinusOne() throws {
        let serial = "emulator-\(UUID().uuidString)"
        MetalErrorHistory.record(avdID: "avd1", serial: serial, count: Int.max, file: historyFile)
        let lines = try readLines()
        let data = Data(lines[0].utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["count"] as? Int, -1)
    }

    func testAvdWithQuoteAndBackslashIsEscapedValidJSON() throws {
        let serial = "emulator-\(UUID().uuidString)"
        MetalErrorHistory.record(avdID: "weird\"avd\\name", serial: serial, count: 1, file: historyFile)
        let lines = try readLines()
        let data = Data(lines[0].utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["avd"] as? String, "weird\"avd\\name")
    }

    func testRotatesToDotOneWhenOverCap() throws {
        let serial = "emulator-\(UUID().uuidString)"
        // ローテーション閾値(5MB)を超えるダミーファイルを事前に作っておく
        try Data(count: MetalErrorHistory.rotationCapBytes + 1).write(to: historyFile)

        MetalErrorHistory.record(avdID: "avd1", serial: serial, count: 7, file: historyFile)

        let rotated = historyFile.deletingLastPathComponent()
            .appendingPathComponent(historyFile.lastPathComponent + ".1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        let rotatedSize = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: rotated.path))[.size] as? Int)
        XCTAssertGreaterThan(rotatedSize, MetalErrorHistory.rotationCapBytes)

        let lines = try readLines()
        XCTAssertEqual(lines.count, 1)
        let data = Data(lines[0].utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["count"] as? Int, 7)
    }
}
