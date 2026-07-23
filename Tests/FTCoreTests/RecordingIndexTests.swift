import XCTest
@testable import FTCore

final class RecordingIndexTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let index = RecordingIndex(recordings: [
            RecordingIndexEntry(
                worker: "ios:iPhone 16", platform: "ios", file: "recordings/ios-iPhone-16.mp4",
                segments: [RecordingIndexSegment(startedAt: "2026-07-23T12:34:56.789Z", durationMs: 180_000)]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(index)
        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.recordings.count, 1)
        XCTAssertEqual(decoded.recordings[0].worker, "ios:iPhone 16")
        XCTAssertEqual(decoded.recordings[0].platform, "ios")
        XCTAssertEqual(decoded.recordings[0].file, "recordings/ios-iPhone-16.mp4")
        XCTAssertEqual(decoded.recordings[0].segments.count, 1)
        XCTAssertEqual(decoded.recordings[0].segments[0].startedAt, "2026-07-23T12:34:56.789Z")
        XCTAssertEqual(decoded.recordings[0].segments[0].durationMs, 180_000)
    }

    func testSanitizedFileNameReplacesNonAlphanumerics() {
        XCTAssertEqual(RecordingIndexIO.sanitizedFileName(for: "ios:iPhone 16"), "ios-iPhone-16")
        XCTAssertEqual(RecordingIndexIO.sanitizedFileName(for: "android:エミュ1"), "android----1",
                       "非 ASCII 文字も '-' に置換される")
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
                       "空のエントリでは index.json を書かず、空ディレクトリも消すはず")
    }

    func testWriteProducesReadableIndex() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-recording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entries = [
            RecordingIndexEntry(worker: "android:エミュ1", platform: "android",
                                file: "recordings/android---1.mp4",
                                segments: [RecordingIndexSegment(startedAt: "2026-07-23T00:00:00.000Z",
                                                                 durationMs: 60_000)]),
        ]
        RecordingIndexIO.write(entries, runDir: tempDir)

        let indexURL = tempDir.appendingPathComponent("recordings/index.json")
        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: data)
        XCTAssertEqual(decoded.recordings.count, 1)
        XCTAssertEqual(decoded.recordings[0].worker, "android:エミュ1")
    }
}
