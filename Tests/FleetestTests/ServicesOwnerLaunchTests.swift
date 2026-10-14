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
        XCTAssertEqual(ServicesOwnerLaunch.arguments(project: "P", profile: "ios-1", physical: false, serials: []),
                       ["api", "services-owner", "--project", "P", "--profile", "ios-1"])
        XCTAssertEqual(ServicesOwnerLaunch.arguments(project: "P", profile: "r", physical: true, serials: ["A1", "B2"]),
                       ["api", "services-owner", "--project", "P", "--profile", "r", "--physical", "--serial", "A1", "--serial", "B2"])
    }

    func testLogPath() {
        XCTAssertEqual(ServicesOwnerLaunch.logURL(stateDir: URL(fileURLWithPath: "/x/.fleetest"), prefix: "fleetest-ab").path,
                       "/x/.fleetest/services/fleetest-ab.log")
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
        XCTAssertEqual(ServicesOwnerLaunch.logTail(url, lines: 2), ["b", "c"])
        XCTAssertEqual(ServicesOwnerLaunch.logTail(URL(fileURLWithPath: "/nonexistent/owner.log"), lines: 2), [])
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
