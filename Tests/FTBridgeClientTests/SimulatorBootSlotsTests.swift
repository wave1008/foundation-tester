// 機械全体で同時2台の起動枠(SimulatorBootSlots)と、枠の判断(SimulatorBoot.run)を固定する。
// 枠は静的な状態なので、両方を1つのクラスに置いて直列に回す(テスト専用の置き場を指す)。

import XCTest
import FTCore
import Foundation
@testable import FTBridgeClient

final class SimulatorBootSlotsTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-boot-slots-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SimulatorBootSlots.lockDirectoryForTesting = directory
        SimulatorBootSlots.resetForTesting()
    }

    override func tearDown() {
        SimulatorBootSlots.resetForTesting()
        SimulatorBootSlots.lockDirectoryForTesting = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func okResult() -> Shell.Result { Shell.Result(status: 0, output: "") }

    func testConcurrencyIsPinnedToTwo() {
        XCTAssertEqual(SimulatorBootSlots.concurrency, 2)
    }

    func testThirdSlotIsNotGrantedUntilOneIsReleased() {
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "A"))
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "B"))
        XCTAssertFalse(SimulatorBootSlots.acquireWithoutWaiting(udid: "C"))
        SimulatorBootSlots.release(udid: "A")
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "C"))
    }

    func testOwnersAreWrittenToTheLockFiles() {
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "UDID-1"))
        XCTAssertEqual(SimulatorBootSlots.owners(), ["\(getpid()) UDID-1"])
        SimulatorBootSlots.release(udid: "UDID-1")
        XCTAssertEqual(SimulatorBootSlots.owners(), [])
    }

    /// 同じプロセスで2台が起動中に片方が終わったら、その udid の枠を返す(残った持ち主の表示がずれない)
    func testReleaseReturnsTheSlotOfThatUDID() {
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "FIRST"))
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "SECOND"))
        SimulatorBootSlots.release(udid: "FIRST")
        XCTAssertEqual(SimulatorBootSlots.owners(), ["\(getpid()) SECOND"])
        SimulatorBootSlots.release(udid: "NEVER-TOOK")
        XCTAssertEqual(SimulatorBootSlots.owners(), ["\(getpid()) SECOND"], "released a slot it never took")
    }

    func testFreeSlotBootsWithoutReadingState() throws {
        var booted = 0
        try SimulatorBoot.run(
            udid: "U",
            tryAcquire: { SimulatorBootSlots.acquireWithoutWaiting(udid: "U") },
            acquireWaiting: { XCTFail("must not wait") },
            release: { SimulatorBootSlots.release(udid: "U") },
            readBootedOrTransitioning: { XCTFail("must not read state"); return false },
            boot: { booted += 1; return self.okResult() })
        XCTAssertEqual(booted, 1)
        // 枠は返っている
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "x"))
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "y"))
    }

    func testBootedDeviceBootsWithoutWaitingWhenSlotsAreFull() throws {
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "A"))
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "B"))
        var booted = 0
        try SimulatorBoot.run(
            udid: "U",
            tryAcquire: { SimulatorBootSlots.acquireWithoutWaiting(udid: "U") },
            acquireWaiting: { XCTFail("must not wait") },
            release: { XCTFail("must not release a slot it never took") },
            readBootedOrTransitioning: { true },
            boot: { booted += 1; return self.okResult() })
        XCTAssertEqual(booted, 1)
    }

    func testShutdownDeviceWaitsForASlot() throws {
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "A"))
        XCTAssertTrue(SimulatorBootSlots.acquireWithoutWaiting(udid: "B"))
        // 順序は時刻でなく「boot の時点で枠が返されていたか」を直接記録して見る
        let released = LockedValue(false)
        let bootSawRelease = LockedValue<Bool?>(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            released.withLock { $0 = true }
            SimulatorBootSlots.release(udid: "A")
        }
        try SimulatorBoot.run(
            udid: "U",
            tryAcquire: { SimulatorBootSlots.acquireWithoutWaiting(udid: "U") },
            acquireWaiting: { SimulatorBootSlots.acquire(udid: "U", log: { _ in }) },
            release: { SimulatorBootSlots.release(udid: "U") },
            readBootedOrTransitioning: { false },
            boot: { bootSawRelease.withLock { $0 = released.withLock { $0 } }; return self.okResult() })
        XCTAssertEqual(bootSawRelease.withLock { $0 }, true, "booted a shutdown simulator before a slot was freed")
    }

    func testNonZeroStatusThrowsFailed() {
        XCTAssertThrowsError(try SimulatorBoot.run(
            udid: "U",
            tryAcquire: { true },
            acquireWaiting: {},
            release: {},
            readBootedOrTransitioning: { false },
            boot: { Shell.Result(status: 1, output: "boom") })) { error in
            guard case SimulatorBoot.Error.failed(let udid, let detail) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(udid, "U")
            XCTAssertTrue(detail.contains("boom"))
        }
    }
}
