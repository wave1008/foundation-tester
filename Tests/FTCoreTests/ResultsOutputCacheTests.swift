import XCTest
@testable import FTCore

final class ResultsOutputCacheTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ResultsOutputCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func entry(key: String = "k", digest: String = "d", sinceKey: String = "2026-06-01T00:00:00Z",
                       oldest: String? = "2026-06-10T00:00:00Z", body: String = #"{"a":1}"#,
                       formatVersion: Int = ResultsOutputCache.formatVersion) -> ResultsOutputCache.Entry {
        ResultsOutputCache.Entry(formatVersion: formatVersion, key: key, scanDigest: digest, sinceKey: sinceKey,
                                 oldestIncludedStartedAt: oldest, body: body)
    }

    // MARK: - 有効判定

    func testValidWhenEverythingMatchesAndSinceIsWithinBounds() {
        XCTAssertNil(ResultsOutputCache.validate(entry(), key: "k", scanDigest: "d", sinceKey: "2026-06-01T00:00:00Z"))
        // since が進んでも、含めた最古の記録より手前なら有効(境界は含む)
        XCTAssertNil(ResultsOutputCache.validate(entry(), key: "k", scanDigest: "d", sinceKey: "2026-06-05T12:00:00Z"))
        XCTAssertNil(ResultsOutputCache.validate(entry(), key: "k", scanDigest: "d", sinceKey: "2026-06-10T00:00:00Z"))
        // 空の窓(oldest nil)は since が進んでも空のまま
        XCTAssertNil(ResultsOutputCache.validate(entry(oldest: nil), key: "k", scanDigest: "d", sinceKey: "2027-01-01T00:00:00Z"))
    }

    func testMissReasons() {
        XCTAssertEqual(ResultsOutputCache.validate(nil, key: "k", scanDigest: "d", sinceKey: "2026-06-01T00:00:00Z"), .noEntry)
        XCTAssertEqual(ResultsOutputCache.validate(nil, readable: false, key: "k", scanDigest: "d", sinceKey: "2026-06-01T00:00:00Z"), .unreadable)
        XCTAssertEqual(ResultsOutputCache.validate(entry(formatVersion: ResultsOutputCache.formatVersion + 1),
                                                   key: "k", scanDigest: "d", sinceKey: "2026-06-01T00:00:00Z"), .formatVersion)
        XCTAssertEqual(ResultsOutputCache.validate(entry(), key: "other", scanDigest: "d", sinceKey: "2026-06-01T00:00:00Z"), .key)
        XCTAssertEqual(ResultsOutputCache.validate(entry(), key: "k", scanDigest: "changed", sinceKey: "2026-06-01T00:00:00Z"), .scanDigest)
        XCTAssertEqual(ResultsOutputCache.validate(entry(), key: "k", scanDigest: "d", sinceKey: "2026-05-31T23:59:59Z"), .sinceMovedBackward)
        // 最古の記録より1秒でも先に進んだら、その記録が窓から落ちている
        XCTAssertEqual(ResultsOutputCache.validate(entry(), key: "k", scanDigest: "d", sinceKey: "2026-06-10T00:00:01Z"), .recordAgedOut)
    }

    // MARK: - 合成

    func testComposeProducesOneJSONObjectWithSinceAndGeneratedAtInserted() throws {
        let body = #"{"project":"P","runs":[],"z":{"n":1}}"#
        let output = try XCTUnwrap(ResultsOutputCache.compose(
            generatedAt: "2026-09-01T00:00:00Z", since: "2026-06-03T00:00:00Z", trendJSON: nil, body: body))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["generatedAt"] as? String, "2026-09-01T00:00:00Z")
        XCTAssertEqual(object["since"] as? String, "2026-06-03T00:00:00Z")
        XCTAssertEqual(object["project"] as? String, "P")
        XCTAssertNil(object["trend"])
        XCTAssertEqual(Set(object.keys), ["generatedAt", "since", "project", "runs", "z"])
    }

    func testComposeInsertsTrendWhenGiven() throws {
        let output = try XCTUnwrap(ResultsOutputCache.compose(
            generatedAt: "g", since: "s", trendJSON: #"[{"scenarioID":"X"}]"#, body: #"{"a":1}"#))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let trend = try XCTUnwrap(object["trend"] as? [[String: Any]])
        XCTAssertEqual(trend.first?["scenarioID"] as? String, "X")
        XCTAssertEqual(object["a"] as? Int, 1)
    }

    func testComposeRefusesBodiesThatWouldNotFormAnObject() {
        XCTAssertNil(ResultsOutputCache.compose(generatedAt: "g", since: "s", trendJSON: nil, body: "{}"))
        XCTAssertNil(ResultsOutputCache.compose(generatedAt: "g", since: "s", trendJSON: nil, body: "[1]"))
        XCTAssertNil(ResultsOutputCache.compose(generatedAt: "g", since: "s", trendJSON: nil, body: ""))
    }

    func testJSONStringEscapes() throws {
        let raw = "a\"b\\c\nd\u{01}"
        let literal = ResultsOutputCache.jsonString(raw)
        let decoded = try JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
        XCTAssertEqual(decoded, [raw])
    }

    // MARK: - 鍵

    func testArgumentsKeyChangesWithArgumentsAndExecutableStamp() throws {
        let exe = stateDir.appendingPathComponent("exe")
        try Data("x".utf8).write(to: exe)
        let a = ResultsOutputCache.argumentsKey(arguments: ["P", "90d"], executable: exe)
        XCTAssertEqual(a, ResultsOutputCache.argumentsKey(arguments: ["P", "90d"], executable: exe))
        XCTAssertNotEqual(a, ResultsOutputCache.argumentsKey(arguments: ["P", "30d"], executable: exe))
        try Data("xy".utf8).write(to: exe)
        XCTAssertNotEqual(a, ResultsOutputCache.argumentsKey(arguments: ["P", "90d"], executable: exe),
                          "a rebuilt executable must invalidate the cache")
        // 実行ファイルを特定できないときは同じ引数でも一致させない(常にミス側)
        XCTAssertNotEqual(ResultsOutputCache.argumentsKey(arguments: ["P"], executable: nil),
                          ResultsOutputCache.argumentsKey(arguments: ["P"], executable: nil))
    }

    // MARK: - 読み書き

    func testWriteThenReadRoundTrip() {
        let written = entry(body: #"{"summary":[]}"#)
        let index = ResultsOutputCache.TrendIndex(scanDigest: "d", files: ["Foo.bar": ["runs/2026-06/r1/scenarios/Foo.bar.json"]])
        ResultsOutputCache.write(written, trendIndex: index, stateDir: stateDir)

        let read = ResultsOutputCache.readEntry(stateDir: stateDir)
        XCTAssertTrue(read.readable)
        XCTAssertEqual(read.entry, written)
        XCTAssertEqual(ResultsOutputCache.readTrendIndex(stateDir: stateDir), index)
    }

    func testMissingAndCorruptFilesAreDistinguished() throws {
        let missing = ResultsOutputCache.readEntry(stateDir: stateDir)
        XCTAssertNil(missing.entry)
        XCTAssertTrue(missing.readable)

        try FileManager.default.createDirectory(at: ResultsOutputCache.dir(stateDir: stateDir), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: ResultsOutputCache.entryURL(stateDir: stateDir))
        let corrupt = ResultsOutputCache.readEntry(stateDir: stateDir)
        XCTAssertNil(corrupt.entry)
        XCTAssertFalse(corrupt.readable)
        XCTAssertEqual(ResultsOutputCache.validate(corrupt.entry, readable: corrupt.readable, key: "k",
                                                   scanDigest: "d", sinceKey: "s"), .unreadable)
    }
}
