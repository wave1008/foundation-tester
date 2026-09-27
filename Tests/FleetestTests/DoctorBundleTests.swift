// `fleetest doctor --bundle` が集める診断ログの選定(DoctorBundle の純粋関数)。
// zip 化・doctor 本体の再実行・バージョン照会(git/sw_vers/xcodebuild/adb)は外部コマンドを撃つので
// ここでは検証しない(選定ロジックだけを一時フォルダの偽ファイルで固定する)。

import FTCore
import XCTest
@testable import fleetest

final class DoctorBundleTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let captured = root!
        addTeardownBlock { try? FileManager.default.removeItem(at: captured) }
    }

    private func write(_ relativePath: String, in dir: URL, contents: String = "x") throws {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - bridge-*.log

    func testBridgeLogEntriesMatchesAllThreePatternsAndSortsThem() throws {
        try write("bridge-8123.log", in: root, contents: "log")
        try write("bridge-8123.prev.log", in: root, contents: "prev")
        try write("bridge-build-8123.log", in: root, contents: "build")
        try write("bridge-8123.pid", in: root, contents: "1234")  // 対象外(拡張子違い)
        try write("other.log", in: root, contents: "irrelevant")  // 対象外(プレフィックス違い)

        let entries = DoctorBundle.bridgeLogEntries(stateDir: root)

        XCTAssertEqual(entries.map(\.archivePath),
                       ["logs/bridge-8123.log", "logs/bridge-8123.prev.log", "logs/bridge-build-8123.log"])
        for entry in entries {
            XCTAssertTrue(entry.exists)
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.sourceURL.path))
        }
    }

    func testBridgeLogEntriesEmptyWhenDirectoryMissing() {
        let entries = DoctorBundle.bridgeLogEntries(stateDir: root.appendingPathComponent("does-not-exist"))
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - cleanup.log

    func testCleanupLogEntryPresentAndMissing() throws {
        XCTAssertFalse(DoctorBundle.cleanupLogEntry(stateDir: root).exists)

        try write("cleanup.log", in: root, contents: "started\nfinished\n")
        let entry = DoctorBundle.cleanupLogEntry(stateDir: root)
        XCTAssertEqual(entry.archivePath, "logs/cleanup.log")
        XCTAssertTrue(entry.exists)
    }

    // MARK: - install-*.log(最新1本)

    func testLatestInstallLogEntryPicksTheNewestByName() throws {
        try write("install-20260101-000000.log", in: root)
        try write("install-20260928-235959.log", in: root)
        try write("install-20260615-120000.log", in: root)

        let entry = DoctorBundle.latestInstallLogEntry(stateDir: root)
        XCTAssertEqual(entry.archivePath, "logs/install-20260928-235959.log")
        XCTAssertTrue(entry.exists)
    }

    func testLatestInstallLogEntryMissingWhenNoneExist() {
        let entry = DoctorBundle.latestInstallLogEntry(stateDir: root)
        XCTAssertFalse(entry.exists)
    }

    // MARK: - emulator/*.log (+ .prev.log) / metal-history.ndjson

    func testEmulatorLogEntriesIncludesPrevLogButNotNdjson() throws {
        try write("device-avd.log", in: root)
        try write("device-avd.prev.log", in: root)
        try write("metal-history.ndjson", in: root)

        let entries = DoctorBundle.emulatorLogEntries(directory: root)
        XCTAssertEqual(entries.map(\.archivePath).sorted(),
                       ["emulator/device-avd.log", "emulator/device-avd.prev.log"])
    }

    func testMetalHistoryEntryPresentAndMissing() throws {
        XCTAssertFalse(DoctorBundle.metalHistoryEntry(directory: root).exists)

        try write("metal-history.ndjson", in: root, contents: "{}\n")
        let entry = DoctorBundle.metalHistoryEntry(directory: root)
        XCTAssertEqual(entry.archivePath, "emulator/metal-history.ndjson")
        XCTAssertTrue(entry.exists)
    }

    // MARK: - 直近 n 件の runID

    private func makeRunDir(resultsDir: URL, runID: String) throws -> URL {
        let dir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRecentRunIDsOrdersDescendingAndLimitsToCount() throws {
        let resultsDir = root.appendingPathComponent("results")
        let runIDs = [
            "20260910-100000Z-a", "20260915-100000Z-b", "20260920-100000Z-c",
            "20260925-100000Z-d", "20260928-100000Z-e",
        ]
        for runID in runIDs { try makeRunDir(resultsDir: resultsDir, runID: runID) }

        let recent = DoctorBundle.recentRunIDs(resultsDir: resultsDir, count: 3)
        XCTAssertEqual(recent, ["20260928-100000Z-e", "20260925-100000Z-d", "20260920-100000Z-c"])
    }

    func testRecentRunIDsEmptyWhenNoRunsDirectory() {
        XCTAssertEqual(DoctorBundle.recentRunIDs(resultsDir: root.appendingPathComponent("results"), count: 3), [])
    }

    func testRecentRunIDsEmptyWhenCountIsZero() throws {
        let resultsDir = root.appendingPathComponent("results")
        try makeRunDir(resultsDir: resultsDir, runID: "20260928-100000Z-a")
        XCTAssertEqual(DoctorBundle.recentRunIDs(resultsDir: resultsDir, count: 0), [])
    }

    // MARK: - 1 run 分のエントリ(recordings/ を含めない・events/ が無ければ missing)

    func testRunEntriesIncludesTheRightFiveAndExcludesRecordings() throws {
        let resultsDir = root.appendingPathComponent("results")
        let runID = "20260928-100000Z-full"
        let runDir = try makeRunDir(resultsDir: resultsDir, runID: runID)
        try "meta".write(to: runDir.appendingPathComponent("run.json"), atomically: true, encoding: .utf8)
        try write("scenarios/S0010.json", in: runDir, contents: "{}")
        try write("host-metrics.ndjson", in: runDir, contents: "{}\n")
        try write("superseded/S0010.1.json", in: runDir, contents: "{}")
        // events/ は作らない(missing を確かめる)
        try write("recordings/S0010.mp4", in: runDir, contents: "fake-video")

        let entries = DoctorBundle.runEntries(resultsDir: resultsDir, runID: runID)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.archivePath, $0) })

        XCTAssertEqual(byPath["runs/\(runID)/run.json"]?.exists, true)
        XCTAssertEqual(byPath["runs/\(runID)/scenarios"]?.exists, true)
        XCTAssertEqual(byPath["runs/\(runID)/superseded"]?.exists, true)
        XCTAssertEqual(byPath["runs/\(runID)/host-metrics.ndjson"]?.exists, true)
        XCTAssertEqual(byPath["runs/\(runID)/events"]?.exists, false, "events/ が無ければ missing")
        XCTAssertFalse(entries.contains { $0.archivePath.contains("recordings") },
                       "recordings/ は選定に含めない")
    }

    func testRunEntriesForAMissingRunDirectoryAreAllMissing() {
        let resultsDir = root.appendingPathComponent("results")
        let entries = DoctorBundle.runEntries(resultsDir: resultsDir, runID: "20260928-999999Z-none")
        XCTAssertTrue(entries.allSatisfy { !$0.exists })
    }

    // MARK: - manifest の書式

    func testManifestLinesFormatPresentAndMissing() throws {
        try write("present.log", in: root, contents: "hello")
        let present = DoctorBundle.Entry(archivePath: "logs/present.log",
                                         sourceURL: root.appendingPathComponent("present.log"), exists: true)
        let missingURL = root.appendingPathComponent("missing.log")
        let missing = DoctorBundle.Entry(archivePath: "logs/missing.log", sourceURL: missingURL, exists: false)

        let lines = DoctorBundle.manifestLines([present, missing])
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("logs/present.log\t"))
        XCTAssertTrue(lines[0].contains("bytes"))
        XCTAssertEqual(lines[1], "logs/missing.log\t\(missingURL.path)\tmissing")
    }
}
