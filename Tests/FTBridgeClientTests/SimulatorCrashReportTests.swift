// SimulatorCrashReport の要約(summarize)とディレクトリ走査(findRecent)を検証する。
// findRecent は実ファイルを一時ディレクトリに書き、dir/now を注入して時刻・順序を制御する。

import XCTest
@testable import FTBridgeClient

final class SimulatorCrashReportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftbridge-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - summarize

    func testSummarizeExtractsBundleIDAndExceptionReason() {
        let header = #"{"bundleID":"com.sutec.mobile","app_name":"SampleApp","timestamp":"2026-07-20 10:00:00"}"#
        let payload = #"{"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"indicator":"Namespace SIGNAL, Code 6"}}"#

        let result = SimulatorCrashReport.summarize(headerLine: header, payload: payload)

        XCTAssertEqual(result?.bundleID, "com.sutec.mobile")
        XCTAssertEqual(result?.reason, "EXC_CRASH SIGABRT")
        XCTAssertFalse(result?.reason?.contains("\n") ?? true)
    }

    func testSummarizeFallsBackToTerminationWhenNoException() {
        let header = #"{"bundleID":"com.sutec.mobile"}"#
        let payload = #"{"termination":{"indicator":"Namespace SIGNAL","name":"SIGKILL"}}"#

        let result = SimulatorCrashReport.summarize(headerLine: header, payload: payload)

        XCTAssertEqual(result?.bundleID, "com.sutec.mobile")
        XCTAssertEqual(result?.reason, "Namespace SIGNAL SIGKILL")
    }

    func testSummarizeReturnsNilForMalformedHeader() {
        let result = SimulatorCrashReport.summarize(headerLine: "not json", payload: #"{"exception":{"type":"EXC_CRASH"}}"#)
        XCTAssertNil(result)
    }

    func testSummarizeReturnsNilForMalformedPayload() {
        let result = SimulatorCrashReport.summarize(headerLine: #"{"bundleID":"com.sutec.mobile"}"#, payload: "not json")
        XCTAssertNil(result)
    }

    // MARK: - summarizeTextFormat(旧テキスト形式 .ips フォールバック)

    func testSummarizeTextFormatExtractsBundleIDAndReason() {
        let text = """
        Incident Identifier: 12345
        Identifier:            com.sutec.mobile
        Version:               1.0
        Exception Type:  EXC_BAD_ACCESS (SIGSEGV)
        Exception Codes: KERN_INVALID_ADDRESS at 0x0
        Termination Reason: Namespace SIGNAL, Code 11 Segmentation fault
        """

        let result = SimulatorCrashReport.summarizeTextFormat(text)

        XCTAssertEqual(result?.bundleID, "com.sutec.mobile")
        XCTAssertEqual(result?.reason, "EXC_BAD_ACCESS (SIGSEGV) / Namespace SIGNAL, Code 11 Segmentation fault")
    }

    func testSummarizeTextFormatWithoutTerminationReasonStillExtractsException() {
        let text = """
        Identifier:            com.sutec.mobile
        Exception Type:  EXC_CRASH (SIGABRT)
        """

        let result = SimulatorCrashReport.summarizeTextFormat(text)

        XCTAssertEqual(result?.bundleID, "com.sutec.mobile")
        XCTAssertEqual(result?.reason, "EXC_CRASH (SIGABRT)")
    }

    func testSummarizeTextFormatReturnsNilWhenNeitherLabelPresent() {
        let text = """
        Hardware Model:      iPhone14,2
        OS Version:          iPhone OS 17.0
        """

        let result = SimulatorCrashReport.summarizeTextFormat(text)

        XCTAssertNil(result)
    }

    // MARK: - findRecent

    // temporaryDirectory は /var/folders/…、contentsOfDirectory が返す URL は /private/var/… に
    // 解決される(/var→/private/var の symlink)。両辺を解決して比較する。
    private func resolved(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private func writeIPS(name: String, bundleID: String, mtime: Date) throws -> URL {
        let header = #"{"bundleID":"\#(bundleID)","app_name":"SampleApp"}"#
        let payload = #"{"exception":{"type":"EXC_CRASH","signal":"SIGABRT"}}"#
        let url = dir.appendingPathComponent(name)
        try "\(header)\n\(payload)".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    func testFindRecentMatchesByBundleID() throws {
        let now = Date()
        let target = try writeIPS(name: "a.ips", bundleID: "com.sutec.mobile", mtime: now)
        _ = try writeIPS(name: "b.ips", bundleID: "com.other.app", mtime: now)

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", dir: dir, now: now)

        XCTAssertEqual(resolved(hit?.path), resolved(target.path))
        XCTAssertEqual(hit?.reason, "EXC_CRASH SIGABRT")
    }

    func testFindRecentExcludesFilesOutsideWindow() throws {
        let now = Date()
        _ = try writeIPS(name: "old.ips", bundleID: "com.sutec.mobile", mtime: now.addingTimeInterval(-300))

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", within: 120, dir: dir, now: now)

        XCTAssertNil(hit)
    }

    func testFindRecentReturnsNewestWhenMultipleMatch() throws {
        let now = Date()
        _ = try writeIPS(name: "older.ips", bundleID: "com.sutec.mobile", mtime: now.addingTimeInterval(-60))
        let newest = try writeIPS(name: "newer.ips", bundleID: "com.sutec.mobile", mtime: now.addingTimeInterval(-1))

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", dir: dir, now: now)

        XCTAssertEqual(resolved(hit?.path), resolved(newest.path))
    }

    func testFindRecentReturnsNilForNonMatchingBundleID() throws {
        let now = Date()
        _ = try writeIPS(name: "a.ips", bundleID: "com.other.app", mtime: now)

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", dir: dir, now: now)

        XCTAssertNil(hit)
    }
}
