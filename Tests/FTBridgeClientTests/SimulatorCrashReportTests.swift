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

    // dyld 即死(例: ランタイム共有キャッシュ破損)は exception が EXC_CRASH SIGABRT にしか
    // ならず、読めなかった dylib と理由は termination(namespace=DYLD)の reasons にだけ出る。
    // 受け手報告 2026-08-24: この欄を落とすと「did not respond in time」の一次原因が消える
    func testSummarizeAppendsDyldTerminationDetail() {
        let header = #"{"bundleID":"com.sutec.mobile"}"#
        let payload = #"{"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"namespace":"DYLD","indicator":"Library missing","reasons":["Library not loaded: /usr/lib/libSystem.B.dylib","Reason: no dyld cache"]}}"#

        let result = SimulatorCrashReport.summarize(headerLine: header, payload: payload)

        XCTAssertEqual(result?.reason,
            "EXC_CRASH SIGABRT / DYLD Library missing:"
            + " Library not loaded: /usr/lib/libSystem.B.dylib; Reason: no dyld cache")
    }

    // 通常のクラッシュ(namespace が DYLD でなく reasons も無い)では従来の文言を変えない
    func testSummarizeKeepsPlainExceptionReasonWithoutDyld() {
        let header = #"{"bundleID":"com.sutec.mobile"}"#
        let payload = #"{"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"namespace":"SIGNAL","indicator":"Namespace SIGNAL, Code 6"}}"#

        let result = SimulatorCrashReport.summarize(headerLine: header, payload: payload)

        XCTAssertEqual(result?.reason, "EXC_CRASH SIGABRT")
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

    /// `device`: 実物の .ips(macOS 27・シミュレータのアプリを SIGSEGV で落として採取)と同じ形で
    /// coalitionName / procPath を書く。`procPathOnly` は coalitionName を欠いた形
    private func writeIPS(name: String, bundleID: String, mtime: Date,
                          device: String? = nil, procPathOnly: Bool = false) throws -> URL {
        let header = #"{"bundleID":"\#(bundleID)","app_name":"SampleApp"}"#
        var fields = [#""exception" : {"type":"EXC_CRASH","signal":"SIGABRT"}"#]
        if let device {
            fields.append(#""procPath" : "\/Users\/USER\/Library\/Developer\/CoreSimulator\/Devices\/\#(device)\/data\/Containers\/Bundle\/Application\/89E82350-5D56-4D3F-B9B3-2D33677A45F0\/SampleApp.app\/SampleApp""#)
            if !procPathOnly {
                fields.append(#""coalitionName" : "com.apple.CoreSimulator.SimDevice.\#(device)""#)
            }
        }
        let payload = "{\n  " + fields.joined(separator: ",\n  ") + "\n}"
        let url = dir.appendingPathComponent(name)
        try "\(header)\n\(payload)".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    func testFindRecentMatchesByBundleID() throws {
        let now = Date()
        let target = try writeIPS(name: "a.ips", bundleID: "com.sutec.mobile", mtime: now)
        _ = try writeIPS(name: "b.ips", bundleID: "com.other.app", mtime: now)

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", udid: nil, dir: dir, now: now)

        XCTAssertEqual(resolved(hit?.path), resolved(target.path))
        XCTAssertEqual(hit?.reason, "EXC_CRASH SIGABRT")
    }

    func testFindRecentExcludesFilesOutsideWindow() throws {
        let now = Date()
        _ = try writeIPS(name: "old.ips", bundleID: "com.sutec.mobile", mtime: now.addingTimeInterval(-300))

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", udid: nil, within: 120, dir: dir, now: now)

        XCTAssertNil(hit)
    }

    func testFindRecentReturnsNewestWhenMultipleMatch() throws {
        let now = Date()
        _ = try writeIPS(name: "older.ips", bundleID: "com.sutec.mobile", mtime: now.addingTimeInterval(-60))
        let newest = try writeIPS(name: "newer.ips", bundleID: "com.sutec.mobile", mtime: now.addingTimeInterval(-1))

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", udid: nil, dir: dir, now: now)

        XCTAssertEqual(resolved(hit?.path), resolved(newest.path))
    }

    func testFindRecentReturnsNilForNonMatchingBundleID() throws {
        let now = Date()
        _ = try writeIPS(name: "a.ips", bundleID: "com.other.app", mtime: now)

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", udid: nil, dir: dir, now: now)

        XCTAssertNil(hit)
    }

    // MARK: - デバイスで絞る(同じアプリを並行で回すと別デバイスの .ips が同じ窓に入る)

    private let deviceA = "0B7E3ADA-B0E7-4A5B-99A7-B29091AE547A"
    private let deviceB = "257324AF-D10D-42DE-AD7D-ADB682E8365F"

    func testFindRecentWithUDIDSkipsNewerReportFromAnotherDevice() throws {
        let now = Date()
        let own = try writeIPS(name: "own.ips", bundleID: "com.sutec.mobile",
                               mtime: now.addingTimeInterval(-5), device: deviceA)
        _ = try writeIPS(name: "other.ips", bundleID: "com.sutec.mobile",
                         mtime: now.addingTimeInterval(-1), device: deviceB)

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", udid: deviceA,
                                                  dir: dir, now: now)

        XCTAssertEqual(resolved(hit?.path), resolved(own.path))
    }

    func testFindRecentWithUDIDReturnsNilWhenOnlyAnotherDeviceCrashed() throws {
        let now = Date()
        _ = try writeIPS(name: "other.ips", bundleID: "com.sutec.mobile", mtime: now, device: deviceB)

        XCTAssertNil(SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", udid: deviceA,
                                                     dir: dir, now: now))
    }

    func testFindRecentWithUDIDDoesNotAttributeReportWithoutDevice() throws {
        let now = Date()
        _ = try writeIPS(name: "unknown.ips", bundleID: "com.sutec.mobile", mtime: now)

        XCTAssertNil(SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", udid: deviceA,
                                                     dir: dir, now: now))
    }

    func testFindRecentWithoutUDIDAcceptsAnyDevice() throws {
        let now = Date()
        let other = try writeIPS(name: "other.ips", bundleID: "com.sutec.mobile", mtime: now, device: deviceB)

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", udid: nil, dir: dir, now: now)

        XCTAssertEqual(resolved(hit?.path), resolved(other.path))
    }

    func testFindRecentWithUDIDMatchesCaseInsensitively() throws {
        let now = Date()
        let own = try writeIPS(name: "own.ips", bundleID: "com.sutec.mobile", mtime: now, device: deviceA)

        let hit = SimulatorCrashReport.findRecent(bundleID: "com.sutec.mobile", udid: deviceA.lowercased(),
                                                  dir: dir, now: now)

        XCTAssertEqual(resolved(hit?.path), resolved(own.path))
    }

    func testDeviceUDIDReadsEscapedProcPathWhenCoalitionIsMissing() throws {
        let url = try writeIPS(name: "p.ips", bundleID: "com.sutec.mobile", mtime: Date(),
                               device: deviceB, procPathOnly: true)
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(SimulatorCrashReport.deviceUDID(inReport: content), deviceB)
    }

    func testDeviceUDIDReadsTextFormatCoalitionLine() {
        let text = """
        Identifier:            com.sutec.mobile
        Coalition:             com.apple.CoreSimulator.SimDevice.\(deviceA) [1234]
        """

        XCTAssertEqual(SimulatorCrashReport.deviceUDID(inReport: text), deviceA)
    }
}
