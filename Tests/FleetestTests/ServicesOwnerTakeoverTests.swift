import FTServices
import FTTestSupport
import Foundation
import XCTest
@testable import fleetest

/// run による `services up` の所有者の引き取り(`ServicesSession.takeOverOwners`)。生存判定と SIGTERM は差し替え口で受ける
/// = プロセスを殺さない・ランタイムに触れない。
final class ServicesOwnerTakeoverTests: XCTestCase {
    private var stateDir: URL!
    private let prefix = "fleetest-0123456789ab"

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("services-takeover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ServicesLeaseFile.directory(stateDir: stateDir), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func place(_ lease: ServicesLease) throws {
        try ServicesLeaseStore.write(lease, to: ServicesLeaseFile.directory(stateDir: stateDir)
            .appendingPathComponent(ServicesLeaseFile.fileName(pid: lease.pid, prefix: prefix)))
    }

    private func lease(pid: Int32, kind: ServicesLease.Kind) -> ServicesLease {
        ServicesLease(pid: pid, pidStartedAt: "2026-10-14T00:00:00Z", kind: kind, runtime: "docker", endpoint: "/sock",
                      prefix: prefix, generation: "g", workspace: "/ws", project: "p", profile: "r",
                      containers: ["\(prefix)-db": "c1"], phase: .running)
    }

    private var lockDir: URL { stateDir.appendingPathComponent("services.lock").appendingPathComponent(prefix) }

    func testLiveOwnerIsSignalledThenWaitedFor() throws {
        try place(lease(pid: 5001, kind: .owner))
        var signalled: [Int32] = []
        var pollsAfterSignal = 0
        var logs: [String] = []
        try ServicesSession.takeOverOwners(
            prefix: prefix, stateDir: stateDir,
            isAlive: { _, _ in
                guard !signalled.isEmpty else { return true }
                pollsAfterSignal += 1
                return pollsAfterSignal < 3   // 合図のあと 2 回は生きていて 3 回目で死ぬ
            },
            terminate: { signalled.append($0) },
            log: { logs.append($0) })
        XCTAssertEqual(signalled, [5001])
        XCTAssertEqual(pollsAfterSignal, 3, "the run waits for the owner to exit")
        XCTAssertTrue(logs.contains { $0.contains("taking over the services started by `fleetest services up` (pid 5001)") }, "\(logs)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path), "the lock is released before waiting")
    }

    func testLiveRunLeaseIsNotSignalled() throws {
        try place(lease(pid: 5002, kind: .run))
        var signalled: [Int32] = []
        try ServicesSession.takeOverOwners(prefix: prefix, stateDir: stateDir, isAlive: { _, _ in true },
                                           terminate: { signalled.append($0) }, log: { _ in })
        XCTAssertEqual(signalled, [], "a run's lease is left to claimPrefix (refused there)")
    }

    func testOrphanOwnerLeaseIsNotSignalled() throws {
        try place(lease(pid: 5003, kind: .owner))
        var signalled: [Int32] = []
        try ServicesSession.takeOverOwners(prefix: prefix, stateDir: stateDir, isAlive: { _, _ in false },
                                           terminate: { signalled.append($0) }, log: { _ in })
        XCTAssertEqual(signalled, [], "a dead owner's lease is reaped by claimPrefix, not signalled")
    }

    func testOwnerThatDoesNotExitIsReportedWithItsPid() throws {
        try place(lease(pid: 5004, kind: .owner))
        XCTAssertThrowsError(try ServicesSession.takeOverOwners(
            prefix: prefix, stateDir: stateDir, budgetOverrideSeconds: 0.3,
            isAlive: { _, _ in true }, terminate: { _ in }, log: { _ in })) { error in
            let detail = (error as? ServicesError)?.detail ?? ""
            XCTAssertTrue(detail.contains("(`fleetest services up`, pid 5004) has not exited"), detail)
            XCTAssertTrue(detail.contains("stop it, then retry"), detail)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path))
    }

    func testHeldByOtherWording() {
        let run = lease(pid: 1, kind: .run)
        let owner = lease(pid: 2, kind: .owner)
        XCTAssertEqual(ServicesSession.heldByOther(run, mine: .run), "run pid 1 holds these services; wait for that run to finish")
        XCTAssertEqual(ServicesSession.heldByOther(run, mine: .owner), "run pid 1 holds these services; wait for that run to finish")
        XCTAssertEqual(ServicesSession.heldByOther(owner, mine: .owner),
                       "these services are already up (`fleetest services up` (pid 2)); use them, or run `fleetest services down` first")
        XCTAssertEqual(ServicesSession.heldByOther(owner, mine: .run),
                       "`fleetest services up` (pid 2) holds these services; stop them with `fleetest services down` first")
    }
}
