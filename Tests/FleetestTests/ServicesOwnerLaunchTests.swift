import FTServices
import Foundation
import XCTest
@testable import fleetest

/// `fleetest services up` が所有者を起こす引数と、上がったかの判定(純粋関数)。プロセスは起こさない。
final class ServicesOwnerLaunchTests: XCTestCase {
    private func lease(pid: Int32, kind: ServicesLease.Kind, phase: ServicesLease.Phase) -> ServicesLease {
        ServicesLease(pid: pid, pidStartedAt: "2026-10-14T00:00:00Z", kind: kind, runtime: "apple", endpoint: "apple",
                      prefix: "fleetest-ab", generation: "g", workspace: "/ws", project: "p", profile: "r", phase: phase)
    }

    private func entry(_ lease: ServicesLease) -> ServicesLeaseEntry {
        ServicesLeaseEntry(url: URL(fileURLWithPath: "/lease.json"), pid: lease.pid, prefix: lease.prefix, state: .readable(lease))
    }

    func testOwnerArguments() {
        let log = URL(fileURLWithPath: "/x/a.log")
        XCTAssertEqual(ServicesOwnerLaunch.arguments(project: "P", profile: "ios-1", physical: false, serials: [], logFile: log),
                       ["api", "services-owner", "--project", "P", "--profile", "ios-1", "--log-file", "/x/a.log"])
        XCTAssertEqual(ServicesOwnerLaunch.arguments(project: "P", profile: "r", physical: true, serials: ["A1", "B2"], logFile: log),
                       ["api", "services-owner", "--project", "P", "--profile", "r", "--physical", "--serial", "A1", "--serial", "B2",
                        "--log-file", "/x/a.log"])
        // 所有者が受け取れる形(引数の名前の食い違いは起動時の失敗でしか出ない)
        let parsed = try? ApiServicesOwnerCommand.parse(Array(ServicesOwnerLaunch.arguments(
            project: "P", profile: "r", physical: false, serials: [], logFile: log).dropFirst(2)))
        XCTAssertEqual(parsed?.logFile, "/x/a.log")
    }

    func testLogPath() {
        XCTAssertEqual(ServicesOwnerLaunch.logURL(stateDir: URL(fileURLWithPath: "/x/.fleetest"), prefix: "fleetest-ab").path,
                       "/x/.fleetest/services/fleetest-ab.log")
    }

    /// 起こす側が開くのは試みごとのログだけ。同じ場所を開くと、同時の `up` で負けた側が勝った側のログを空にする
    func testAttemptLogsAreDistinctFromTheOwnerLogAndFromEachOther() {
        let stateDir = URL(fileURLWithPath: "/x/.fleetest")
        let stable = ServicesOwnerLaunch.logURL(stateDir: stateDir, prefix: "fleetest-ab")
        let first = ServicesOwnerLaunch.attemptLogURL(stateDir: stateDir, prefix: "fleetest-ab")
        let second = ServicesOwnerLaunch.attemptLogURL(stateDir: stateDir, prefix: "fleetest-ab")
        XCTAssertNotEqual(first, stable)
        XCTAssertNotEqual(first, second)
        // 改名は同じディレクトリの中(別のファイルシステムへの rename は失敗する)
        XCTAssertEqual(first.deletingLastPathComponent(), stable.deletingLastPathComponent())
    }

    /// 勝った所有者の改名は前の所有者のログを置き換え、負けた試みのログには触れない。開いている読み口は改名の後も読める
    func testClaimLogReplacesTheOwnerLogAndLeavesOtherAttemptsAlone() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("services-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stable = dir.appendingPathComponent("p.log")
        let winner = dir.appendingPathComponent("p.attempt-1.log")
        let loser = dir.appendingPathComponent("p.attempt-2.log")
        try "previous\n".write(to: stable, atomically: true, encoding: .utf8)
        try "winner\n".write(to: winner, atomically: true, encoding: .utf8)
        try "loser: already up\n".write(to: loser, atomically: true, encoding: .utf8)
        let reader = try FileHandle(forReadingFrom: winner)
        defer { try? reader.close() }
        var warnings: [String] = []

        ServicesOwnerLaunch.claimLog(attempt: winner, stable: stable, log: { warnings.append($0) })

        XCTAssertEqual(warnings, [])
        XCTAssertEqual(try String(contentsOf: stable, encoding: .utf8), "winner\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: winner.path))
        XCTAssertEqual(try String(contentsOf: loser, encoding: .utf8), "loser: already up\n")
        XCTAssertEqual(ServicesOwnerLaunch.logTail(reader, lines: 5), ["winner"])
    }

    func testClaimLogFailureOnlyWarns() {
        var warnings: [String] = []
        ServicesOwnerLaunch.claimLog(attempt: URL(fileURLWithPath: "/nonexistent/a.log"),
                                     stable: URL(fileURLWithPath: "/nonexistent/b.log"), log: { warnings.append($0) })
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.hasPrefix("⚠️ services: cannot move the log /nonexistent/a.log to /nonexistent/b.log") == true)
    }

    func testReadinessNeedsARunningOwnerLeaseOfThatPid() {
        let running = lease(pid: 7, kind: .owner, phase: .running)
        XCTAssertEqual(ServicesOwnerLaunch.readiness(entries: [entry(running)], ownerPid: 7, ownerRunning: true), .running(running))
        // 所有者が死んでいれば控えが running でも exited(死んだ後の控えは孤児)
        XCTAssertEqual(ServicesOwnerLaunch.readiness(entries: [entry(running)], ownerPid: 7, ownerRunning: false), .exited)
        XCTAssertEqual(ServicesOwnerLaunch.readiness(entries: [entry(lease(pid: 7, kind: .owner, phase: .starting))], ownerPid: 7, ownerRunning: true), .waiting)
        XCTAssertEqual(ServicesOwnerLaunch.readiness(entries: [entry(running)], ownerPid: 8, ownerRunning: true), .waiting)
        XCTAssertEqual(ServicesOwnerLaunch.readiness(entries: [entry(lease(pid: 7, kind: .run, phase: .running))], ownerPid: 7, ownerRunning: true), .waiting)
        XCTAssertEqual(ServicesOwnerLaunch.readiness(entries: [], ownerPid: 7, ownerRunning: true), .waiting)
    }

    func testLogTailReturnsTheLastLines() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("owner-\(UUID().uuidString).log")
        try "a\nb\nc\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = try handle.readToEnd()   // 読み終えた後でも先頭から読み直す
        XCTAssertEqual(ServicesOwnerLaunch.logTail(handle, lines: 2), ["b", "c"])
    }
}

/// `services up` が生きている控えを見たときの判断(純粋)。phase を見ずに「already up」と言わない
final class ServicesUpExistingDecisionTests: XCTestCase {
    private func lease(kind: ServicesLease.Kind, phase: ServicesLease.Phase) -> ServicesLease {
        ServicesLease(pid: 9, pidStartedAt: "2026-10-14T00:00:00Z", kind: kind, runtime: "apple", endpoint: "apple",
                      prefix: "fleetest-ab", generation: "g", workspace: "/ws", project: "p", profile: "r", phase: phase)
    }

    func testDecisionByKindAndPhase() {
        XCTAssertEqual(ServicesCommand.Up.decision(for: lease(kind: .owner, phase: .running)), .alreadyUp)
        XCTAssertEqual(ServicesCommand.Up.decision(for: lease(kind: .owner, phase: .starting)),
                       .wait("→ services: `fleetest services up` (pid 9) is still starting; waiting for it"))
        XCTAssertEqual(ServicesCommand.Up.decision(for: lease(kind: .owner, phase: .tearingDown)),
                       .wait("→ services: `fleetest services up` (pid 9) is stopping; waiting for it to finish before starting again"))
        for phase in [ServicesLease.Phase.starting, .running, .tearingDown] {
            XCTAssertEqual(ServicesCommand.Up.decision(for: lease(kind: .run, phase: phase)),
                           .refuse("run pid 9 holds these services; wait for that run to finish"))
        }
    }
}
