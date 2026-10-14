import FTServices
import Foundation
import XCTest
@testable import fleetest

/// `services reset --force` が控えから決めること(純粋関数)。生きている run は止めない・生きている所有者は先に止める・
/// 読めない控えでもその pid が生きていれば消さない・生きている持ち主がいなければその排他の中で消す
final class ServicesResetDecisionTests: XCTestCase {
    private func lease(pid: Int32, kind: ServicesLease.Kind) -> ServicesLease {
        ServicesLease(pid: pid, pidStartedAt: "2026-10-14T00:00:00Z", kind: kind, runtime: "apple", endpoint: "apple",
                      prefix: "fleetest-ab", generation: "g", workspace: "/ws", project: "p", profile: "r", phase: .starting)
    }

    private func readable(_ lease: ServicesLease) -> ServicesLeaseEntry {
        ServicesLeaseEntry(url: URL(fileURLWithPath: "/state/services/\(lease.pid)~fleetest-ab.json"), pid: lease.pid,
                           prefix: "fleetest-ab", state: .readable(lease))
    }

    private func unreadable(pid: Int32) -> ServicesLeaseEntry {
        ServicesLeaseEntry(url: URL(fileURLWithPath: "/state/services/\(pid)~fleetest-ab.json"), pid: pid,
                           prefix: "fleetest-ab", state: .unreadable(reason: "the file cannot be decoded"))
    }

    func testLiveRunBlocksTheReset() {
        let decision = ServicesCommand.Reset.forceDecision(
            entries: [readable(lease(pid: 11, kind: .owner)), readable(lease(pid: 10, kind: .run))], isAlive: { _, _ in true })
        guard case .blockedByRun(let run) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(run.pid, 10)
    }

    func testLiveOwnersAreStoppedFirst() {
        let decision = ServicesCommand.Reset.forceDecision(
            entries: [readable(lease(pid: 10, kind: .run)), readable(lease(pid: 11, kind: .owner)), readable(lease(pid: 12, kind: .owner))],
            isAlive: { pid, _ in pid != 10 })
        guard case .stop(let owners) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(owners.map(\.pid), [11, 12])
    }

    func testOrphansOnlyMeansRemoveNow() {
        let orphans = ServicesCommand.Reset.forceDecision(
            entries: [readable(lease(pid: 10, kind: .run)), readable(lease(pid: 11, kind: .owner))], isAlive: { _, _ in false })
        guard case .removeNow = orphans else { return XCTFail("\(orphans)") }
        let none = ServicesCommand.Reset.forceDecision(entries: [], isAlive: { _, _ in true })
        guard case .removeNow = none else { return XCTFail("\(none)") }
    }

    /// 読めない控え(不正な JSON 等)は種別も所有も確かめられない。ファイル名の pid が生きていれば消さない・死んでいれば孤児として消す
    func testUnreadableLeaseOfALiveProcessBlocksTheReset() {
        let blocked = ServicesCommand.Reset.forceDecision(entries: [unreadable(pid: 20)], isAlive: { pid, _ in pid == 20 })
        guard case .blockedByUnreadable(let entry) = blocked else { return XCTFail("\(blocked)") }
        XCTAssertEqual(entry.pid, 20)
        let dead = ServicesCommand.Reset.forceDecision(entries: [unreadable(pid: 20), readable(lease(pid: 11, kind: .owner))],
                                                       isAlive: { _, _ in false })
        guard case .removeNow = dead else { return XCTFail("\(dead)") }
    }
}
