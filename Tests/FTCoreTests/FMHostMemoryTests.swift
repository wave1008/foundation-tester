// FMHostMemory(FM の死の切り分け用のメモリ推移)の検証。純粋関数(top の解析・証拠の間引き・JetsamEvent の要約)と、
// リングの書き込み(古い行の破棄・リンクを辿らない)、サンプラの周期。置き場は FT_FM_LIVENESS_DIR へ逃がす。

import FTTestSupport
import XCTest
@testable import FTCore

final class FMHostMemoryTests: XCTestCase {
    private var dir: URL!
    private var savedEnv: String?

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FMHostMemoryTests-\(UUID().uuidString)")
        savedEnv = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"]
        setenv("FT_FM_LIVENESS_DIR", dir.path, 1)
    }

    override func tearDownWithError() throws {
        FMHostMemory.waitForPendingSample()
        FMHostMemory.captureHook.withLock { $0 = { FMHostMemory.capture(now: $0) } }
        FMHostMemory.appendHook.withLock { $0 = { FMHostMemory.append($0, now: $1) } }
        FMHostMemory.resetSamplerState()
        if let savedEnv { setenv("FT_FM_LIVENESS_DIR", savedEnv, 1) } else { unsetenv("FT_FM_LIVENESS_DIR") }
        try? FileManager.default.removeItem(at: dir)
    }

    private var ringURL: URL { dir.appendingPathComponent("fm-host-memory.ndjson") }

    func testConstantsArePinned() {
        XCTAssertEqual(FMHostMemory.sampleIntervalSeconds, 60)
        XCTAssertEqual(FMHostMemory.ringMaxAgeSeconds, 24 * 3600)
        XCTAssertEqual(FMHostMemory.evidenceRecentSeconds, 30 * 60)
        XCTAssertEqual(FMHostMemory.jetsamWindowSeconds, 30 * 60)
        XCTAssertEqual(FMHostMemory.jetsamMaxKilledLines, 5)
    }

    func testParseTopMemory() {
        XCTAssertEqual(FMHostMemory.parseTopMemory("7249K"), 7249 * 1024)
        XCTAssertEqual(FMHostMemory.parseTopMemory("15M+"), 15 * 1_048_576)
        XCTAssertEqual(FMHostMemory.parseTopMemory("1.5G"), Int64(1.5 * 1_073_741_824))
        XCTAssertEqual(FMHostMemory.parseTopMemory("512B-"), 512)
        XCTAssertEqual(FMHostMemory.parseTopMemory("Processes: 1\nMEM\n  7249K  \n\n"), 7249 * 1024)
        XCTAssertNil(FMHostMemory.parseTopMemory(""))
        XCTAssertNil(FMHostMemory.parseTopMemory("\n  \n"))
        XCTAssertNil(FMHostMemory.parseTopMemory("MEM"))
        XCTAssertNil(FMHostMemory.parseTopMemory("12X"))
    }

    func testSelectForEvidenceBoundaries() {
        let now = 1_000_000.0
        func s(_ age: Double) -> FMHostMemory.Sample { FMHostMemory.Sample(at: now - age) }
        // 30 分ちょうどは全部の側
        let recent = [s(1800), s(60)]
        XCTAssertEqual(FMHostMemory.selectForEvidence(recent, now: now), recent)
        // 同じ 1 時間枠にもっと古い点を置く: ちょうど 30 分の点が間引きの側へ落ちると、枠の先頭(古い点)だけが残る
        XCTAssertEqual(Int((now - 1830) / 3600), Int((now - 1800) / 3600), "前提: 2 点は同じ枠")
        XCTAssertEqual(FMHostMemory.selectForEvidence([s(1830), s(1800)], now: now), [s(1830), s(1800)])
        // 1 時間枠: 同じ枠の古い側は先頭の1点だけ
        let bucketStart = (now - 7200 - 100) / 3600
        let first = Double(Int(bucketStart)) * 3600
        let early = FMHostMemory.Sample(at: first + 5)
        let later = FMHostMemory.Sample(at: first + 65)
        XCTAssertEqual(FMHostMemory.selectForEvidence([later, early], now: now), [early])
        // 24 時間を超えたものは除外、ちょうどは残る
        let tooOld = s(24 * 3600 + 1)
        let edge = s(24 * 3600)
        XCTAssertEqual(FMHostMemory.selectForEvidence([tooOld, edge], now: now), [edge])
    }

    func testDescribeOmitsMissingFields() {
        let now = Date()
        let full = FMHostMemory.Sample(at: now.timeIntervalSince1970, freeBytes: Int64(2.4 * 1_073_741_824),
                                       compressedBytes: Int64(71.1 * 1_073_741_824),
                                       compressedSourceBytes: Int64(155.1 * 1_073_741_824), swapUsedBytes: 0,
                                       modelmanagerdFootprintBytes: 16_650_000)
        let text = FMHostMemory.describe(full, now: now)
        XCTAssertTrue(text.contains("free=2.4GiB compressed=71.1GiB of 155.1GiB swap=0.0GiB modelmanagerd=15.9MiB"), text)
        let sparse = FMHostMemory.describe(FMHostMemory.Sample(at: now.timeIntervalSince1970, freeBytes: 1_073_741_824), now: now)
        XCTAssertTrue(sparse.hasSuffix("free=1.0GiB"), sparse)
        let old = FMHostMemory.describe(FMHostMemory.Sample(at: now.timeIntervalSince1970 - 3 * 86_400), now: now)
        XCTAssertEqual(old.split(separator: " ").count, 2, "今日でなければ日付が前に付く: \(old)")
    }

    private func ips(killed: Int, withBadReasonless: Bool = true) -> String {
        var processes = (0..<killed).map {
            #"{"name":"proc\#($0)","pid":\#(100 + $0),"reason":"per-process-limit","rpages":968,"lifetimeMax":968}"#
        }
        if withBadReasonless { processes.append(#"{"name":"alive","pid":1,"rpages":5}"#) }
        return """
        {"bug_type":"298","timestamp":"2026-10-17 13:05:09.00 +0900"}
        {"pageSize":16384,"largestProcess":"qemu-system-aarch64-headless","memoryStatus":{"memoryPages":{"free":157286},"compressorSize":4660000,"uncompressed":10165000},"processes":[\(processes.joined(separator: ","))]}
        """
    }

    func testJetsamLines() throws {
        let lines = try XCTUnwrap(FMHostMemory.jetsamLines(fileName: "JetsamEvent-x.ips", contents: ips(killed: 1)))
        XCTAssertEqual(lines.count, 2, "reason の無いプロセスは出ない")
        XCTAssertTrue(lines[0].hasPrefix("JetsamEvent-x.ips 2026-10-17 13:05:09 free=2.4GiB compressed="), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("largest=qemu-system-aarch64-headless"), lines[0])
        XCTAssertEqual(lines[1], "killed proc0[100] reason=per-process-limit resident=15.1MiB lifetimeMax=15.1MiB")
        let capped = try XCTUnwrap(FMHostMemory.jetsamLines(fileName: "a.ips", contents: ips(killed: 9)))
        XCTAssertEqual(capped.count, 1 + 5)
        XCTAssertNil(FMHostMemory.jetsamLines(fileName: "a.ips", contents: "{\"timestamp\":\"x\"}\n{broken"))
        XCTAssertNil(FMHostMemory.jetsamLines(fileName: "a.ips", contents: "not json at all"))
    }

    func testJetsamEvidenceReadsRecentFilesNewestFirstAndSkipsUnderTestDir() throws {
        let reports = dir.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let now = Date()
        for (name, age) in [("JetsamEvent-a.ips", 60.0), ("JetsamEvent-b.ips", 120.0), ("JetsamEvent-c.ips", 180.0),
                            ("JetsamEvent-old.ips", 4000.0)] {
            let url = reports.appendingPathComponent(name)
            try Data(ips(killed: 1).utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        // FT_FM_LIVENESS_DIR が設定されている間は撃たない
        XCTAssertNil(FMHostMemory.jetsamEvidence(now: now, directories: [reports]))
        unsetenv("FT_FM_LIVENESS_DIR")
        defer { setenv("FT_FM_LIVENESS_DIR", dir.path, 1) }
        let lines = try XCTUnwrap(FMHostMemory.jetsamEvidence(now: now, directories: [reports]))
        XCTAssertEqual(lines.count, 4, "2 件 × (要約 + killed)")
        XCTAssertTrue(lines[0].hasPrefix("JetsamEvent-a.ips"))
        XCTAssertTrue(lines[2].hasPrefix("JetsamEvent-b.ips"))
    }

    func testAppendDropsOldAndUnreadableLinesAndKeepsNew() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let now = Date()
            let old = FMHostMemory.Sample(at: now.timeIntervalSince1970 - 25 * 3600, freeBytes: 1)
            let kept = FMHostMemory.Sample(at: now.timeIntervalSince1970 - 100, freeBytes: 2)
            var data = Data()
            for sample in [old, kept] { data.append(try JSONEncoder().encode(sample)); data.append(0x0A) }
            data.append(Data("garbage\n".utf8))
            try data.write(to: ringURL)
            let fresh = FMHostMemory.Sample(at: now.timeIntervalSince1970, freeBytes: 3)
            FMHostMemory.append(fresh, now: now)
            XCTAssertEqual(FMHostMemory.recent(now: now).map(\.freeBytes), [2, 3])
            let lines = try String(contentsOf: ringURL, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(lines.count, 2, "壊れた行も捨てる")
        }
    }

    func testAppendDoesNotFollowASymlink() throws {
        try SharedResource.hostCaches.locked {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("outside.txt")
            try Data("keep".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: ringURL, withDestinationURL: target)
            FMHostMemory.append(FMHostMemory.Sample(at: Date().timeIntervalSince1970, freeBytes: 1), now: Date())
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
            // 書き直しは rename なのでリンク先は元々書かれない。見るべきは「リンクに手を出さない」= リンクのまま残る
            let type = try FileManager.default.attributesOfItem(atPath: ringURL.path)[.type] as? FileAttributeType
            XCTAssertEqual(type, .typeSymbolicLink)
        }
    }

    func testSamplerFiresOncePerInterval() {
        let calls = LockedCounter()
        FMHostMemory.captureHook.withLock { $0 = { FMHostMemory.Sample(at: $0.timeIntervalSince1970) } }
        FMHostMemory.appendHook.withLock { $0 = { _, _ in calls.increment() } }
        FMHostMemory.resetSamplerState()
        let t0 = Date()
        FMHostMemory.sampleIfDue(now: t0)
        FMHostMemory.waitForPendingSample()
        FMHostMemory.sampleIfDue(now: t0.addingTimeInterval(59))
        FMHostMemory.waitForPendingSample()
        XCTAssertEqual(calls.value, 1)
        FMHostMemory.sampleIfDue(now: t0.addingTimeInterval(60))
        FMHostMemory.waitForPendingSample()
        XCTAssertEqual(calls.value, 2)
    }
}

private final class LockedCounter: @unchecked Sendable {
    // 守る不変条件: value は lock の内側でだけ読み書きする
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
