import XCTest
@testable import FTCore

final class RecordingIndexTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let index = RecordingIndex(recordings: [
            RecordingIndexEntry(
                scenarioID: "LoginTests.S0010", worker: "ios:iPhone 16", platform: "ios",
                file: "recordings/LoginTests-S0010.mp4",
                segments: [RecordingIndexSegment(startedAt: "2026-07-23T12:34:56.789Z", durationMs: 12_345)]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(index)
        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 2, "既定は schemaVersion 2(拡張側は 2 のみ受け付ける)")
        XCTAssertEqual(decoded.recordings.count, 1)
        XCTAssertEqual(decoded.recordings[0].scenarioID, "LoginTests.S0010")
        XCTAssertEqual(decoded.recordings[0].worker, "ios:iPhone 16")
        XCTAssertEqual(decoded.recordings[0].platform, "ios")
        XCTAssertEqual(decoded.recordings[0].file, "recordings/LoginTests-S0010.mp4")
        XCTAssertEqual(decoded.recordings[0].segments.count, 1)
        XCTAssertEqual(decoded.recordings[0].segments[0].startedAt, "2026-07-23T12:34:56.789Z")
        XCTAssertEqual(decoded.recordings[0].segments[0].durationMs, 12_345)
        XCTAssertNil(decoded.clipsAttempted, "指定しなければ nil のはず")
        XCTAssertNil(decoded.clipsFailed)
        XCTAssertNil(decoded.encoderFallback)
    }

    func testEncodeDecodeRoundTripWithCounters() throws {
        let index = RecordingIndex(recordings: [], clipsAttempted: 5, clipsFailed: 2, encoderFallback: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(index)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["clipsAttempted"] as? Int, 5, "拡張側との契約キー名は camelCase のまま")
        XCTAssertEqual(json["clipsFailed"] as? Int, 2)
        XCTAssertEqual(json["encoderFallback"] as? Bool, true)

        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: data)
        XCTAssertEqual(decoded.clipsAttempted, 5)
        XCTAssertEqual(decoded.clipsFailed, 2)
        XCTAssertEqual(decoded.encoderFallback, true)
    }

    func testSanitizedFileNameReplacesNonAlphanumerics() {
        XCTAssertEqual(RecordingIndexIO.sanitizedFileName(for: "LoginTests.S0010"), "LoginTests-S0010")
        XCTAssertEqual(RecordingIndexIO.sanitizedFileName(for: "条件分岐が働くこと.S0020"), "条件分岐が働くこと-S0020",
                       "日本語(非 ASCII の文字)は保持される")
        XCTAssertEqual(RecordingIndexIO.sanitizedFileName(for: "android:エミュ/1"), "android-エミュ-1",
                       "記号(':' '/' 等)は '-' に置換される")
        XCTAssertEqual(RecordingIndexIO.sanitizedFileName(for: "abcXYZ012"), "abcXYZ012")
    }

    func testWriteSkipsEmptyEntriesAndRemovesEmptyDirectory() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-recording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let recordingsDir = tempDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        RecordingIndexIO.write([], runDir: tempDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingsDir.path),
                       "空のエントリかつ clipsAttempted==0 では index.json を書かず、空ディレクトリも消すはず")
    }

    func testWriteWithAttemptedButEmptyEntriesStillWritesIndex() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-recording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        RecordingIndexIO.write([], runDir: tempDir, clipsAttempted: 3, clipsFailed: 3, encoderFallback: true)

        let indexURL = tempDir.appendingPathComponent("recordings/index.json")
        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: data)
        XCTAssertEqual(decoded.recordings.count, 0,
                       "切り出しが全滅しても attempted > 0 なら recordings 空のまま書くはず")
        XCTAssertEqual(decoded.clipsAttempted, 3)
        XCTAssertEqual(decoded.clipsFailed, 3)
        XCTAssertEqual(decoded.encoderFallback, true)
    }

    /// **録画ソースが1本も使えなかった run も index を残す**(2026-08-26)。
    /// 消すと「録画していない run」と見分けが付かず、録画タブから黙って消える
    /// (実害: simctl が 0 バイトの .mov を作る Mac で、その機械のセッションだけ一覧から消えた)
    func testWriteWithFailedSourcesStillWritesIndex() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-recording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        RecordingIndexIO.write([], runDir: tempDir, sourcesFailed: 2)

        let indexURL = tempDir.appendingPathComponent("recordings/index.json")
        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(decoded.recordings.count, 0)
        XCTAssertEqual(decoded.sourcesFailed, 2, "何台で録画が取れなかったかを残す")
        XCTAssertNil(decoded.clipsAttempted, "切り出しまで到達していないので attempted は書かない")
    }

    func testWriteProducesReadableIndex() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-recording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries = [
            RecordingIndexEntry(scenarioID: "LoginTests.S0020", worker: "android:エミュ1", platform: "android",
                                file: "recordings/LoginTests-S0020.mp4",
                                segments: [RecordingIndexSegment(startedAt: "2026-07-23T00:00:00.000Z",
                                                                 durationMs: 60_000)]),
        ]
        RecordingIndexIO.write(entries, runDir: tempDir)

        let indexURL = tempDir.appendingPathComponent("recordings/index.json")
        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.recordings.count, 1)
        XCTAssertEqual(decoded.recordings[0].scenarioID, "LoginTests.S0020")
        XCTAssertEqual(decoded.recordings[0].worker, "android:エミュ1")
    }
}
