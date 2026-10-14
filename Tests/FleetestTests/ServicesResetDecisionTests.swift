import FTServices
import Foundation
import XCTest
@testable import fleetest

/// `services reset --force` が控えから決めること(純粋関数)。生きている run は止めない・生きている所有者は先に止める・
/// 生きている持ち主がいなければその排他の中で消す
final class ServicesResetDecisionTests: XCTestCase {
    private func lease(pid: Int32, kind: ServicesLease.Kind) -> ServicesLease {
        ServicesLease(pid: pid, pidStartedAt: "2026-10-14T00:00:00Z", kind: kind, runtime: "apple", endpoint: "apple",
                      prefix: "fleetest-ab", generation: "g", workspace: "/ws", project: "p", profile: "r", phase: .starting)
    }

    func testLiveRunBlocksTheReset() {
        let decision = ServicesCommand.Reset.forceDecision(leases: [lease(pid: 11, kind: .owner), lease(pid: 10, kind: .run)],
                                                           isAlive: { _, _ in true })
        guard case .blockedByRun(let run) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(run.pid, 10)
    }

    func testLiveOwnersAreStoppedFirst() {
        let decision = ServicesCommand.Reset.forceDecision(leases: [lease(pid: 10, kind: .run), lease(pid: 11, kind: .owner), lease(pid: 12, kind: .owner)],
                                                           isAlive: { pid, _ in pid != 10 })
        guard case .stop(let owners) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(owners.map(\.pid), [11, 12])
    }

    func testOrphansOnlyMeansRemoveNow() {
        let orphans = ServicesCommand.Reset.forceDecision(leases: [lease(pid: 10, kind: .run), lease(pid: 11, kind: .owner)],
                                                          isAlive: { _, _ in false })
        guard case .removeNow = orphans else { return XCTFail("\(orphans)") }
        let none = ServicesCommand.Reset.forceDecision(leases: [], isAlive: { _, _ in true })
        guard case .removeNow = none else { return XCTFail("\(none)") }
    }
}
