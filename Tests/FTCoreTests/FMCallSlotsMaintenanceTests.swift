import Darwin
import FTTestSupport
import XCTest
@testable import FTCore

final class FMCallSlotsMaintenanceTests: XCTestCase {
    private func withLockDirectory(_ body: (URL) throws -> Void) throws {
        try SharedResource.hostCaches.locked {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("fm-maintenance-test-\(UUID().uuidString)")
            let previousDirectory = FMCallSlots.lockDirectoryForTesting
            let previousConcurrency = FMCallSlots.concurrencyForTesting
            FMCallSlots.resetForTesting()
            FMCallSlots.lockDirectoryForTesting = directory
            FMCallSlots.concurrencyForTesting = 1
            defer {
                FMCallSlots.resetForTesting()
                FMCallSlots.lockDirectoryForTesting = previousDirectory
                FMCallSlots.concurrencyForTesting = previousConcurrency
                try? FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body(directory)
        }
    }

    private func openLock(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return fd
    }

    private func canAcquire(_ url: URL) throws -> Bool {
        let fd = try openLock(url)
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    func testMaintenanceRejectsAnOrdinarySlotHeldByTheSameProcess() throws {
        guard FMCallSlots.isEnabled else { throw XCTSkip("Ordinary slot serialization is disabled") }
        try withLockDirectory { directory in
            XCTAssertTrue(FMCallSlots.acquireWithoutWaiting())
            defer { FMCallSlots.release() }

            XCTAssertThrowsError(try FMCallSlots.acquireForMaintenance())
            XCTAssertFalse(try canAcquire(directory.appendingPathComponent("fm.lock.0")))
            XCTAssertFalse(FMCallSlots.acquireWithoutWaiting())
        }
    }

    func testLeaseHoldsConfiguredAndExistingSlotsAndReleasesWithoutUnlinking() throws {
        try withLockDirectory { directory in
            FMCallSlots.concurrencyForTesting = 3
            let names = ["fm.lock.0", "fm.lock.1", "fm.lock.2", "fm.lock.9",
                         "fm.lock.09", "fm.lock.18446744073709551616"]
            for name in names.dropFirst(3) {
                try Data().write(to: directory.appendingPathComponent(name))
            }
            for ignored in ["fm.lock.", "fm.lock.-1", "fm.lock.+1", "fm.lock.other"] {
                try FileManager.default.createDirectory(
                    at: directory.appendingPathComponent(ignored), withIntermediateDirectories: false)
            }

            do {
                let lease = try FMCallSlots.acquireForMaintenance()
                try withExtendedLifetime(lease) {
                    for name in names {
                        XCTAssertFalse(try canAcquire(directory.appendingPathComponent(name)), name)
                    }
                }
            }

            for name in names {
                let url = directory.appendingPathComponent(name)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
                XCTAssertTrue(try canAcquire(url), name)
            }
            let secondLease = try FMCallSlots.acquireForMaintenance()
            try withExtendedLifetime(secondLease) {
                XCTAssertFalse(try canAcquire(directory.appendingPathComponent("fm.lock.9")))
            }
        }
    }

    func testKillSwitchStillLocksAtLeastOneSlotAndExistingSlots() throws {
        try withLockDirectory { directory in
            let saved = ProcessInfo.processInfo.environment["FT_FM_CALL_SLOTS"]
            setenv("FT_FM_CALL_SLOTS", "0", 1)
            defer {
                if let saved { setenv("FT_FM_CALL_SLOTS", saved, 1) }
                else { unsetenv("FT_FM_CALL_SLOTS") }
            }
            FMCallSlots.concurrencyForTesting = 0
            try Data().write(to: directory.appendingPathComponent("fm.lock.4"))

            let lease = try FMCallSlots.acquireForMaintenance()
            try withExtendedLifetime(lease) {
                XCTAssertFalse(try canAcquire(directory.appendingPathComponent("fm.lock.0")))
                XCTAssertFalse(try canAcquire(directory.appendingPathComponent("fm.lock.4")))
            }
        }
    }

    func testBusyHighSlotReleasesEveryPartiallyAcquiredSlot() throws {
        try withLockDirectory { directory in
            let high = try openLock(directory.appendingPathComponent("fm.lock.9"))
            defer { close(high) }
            XCTAssertEqual(flock(high, LOCK_EX | LOCK_NB), 0)

            XCTAssertThrowsError(try FMCallSlots.acquireForMaintenance())
            XCTAssertTrue(try canAcquire(directory.appendingPathComponent("fm.lock.0")))
            XCTAssertFalse(try canAcquire(directory.appendingPathComponent("fm.lock.9")))
        }
    }

    func testUnopenableSlotFailsClosedAndReleasesPartialLease() throws {
        try withLockDirectory { directory in
            FMCallSlots.concurrencyForTesting = 2
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("fm.lock.1"), withIntermediateDirectories: false)

            XCTAssertThrowsError(try FMCallSlots.acquireForMaintenance())
            XCTAssertTrue(try canAcquire(directory.appendingPathComponent("fm.lock.0")))
        }
    }

    func testSymlinkSlotIsRejectedAndReleasesPartialLease() throws {
        try withLockDirectory { directory in
            FMCallSlots.concurrencyForTesting = 2
            let target = directory.appendingPathComponent("target")
            try Data("preserve".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent("fm.lock.1"), withDestinationURL: target)

            XCTAssertThrowsError(try FMCallSlots.acquireForMaintenance())
            XCTAssertTrue(try canAcquire(directory.appendingPathComponent("fm.lock.0")))
            XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
            XCTAssertTrue(try canAcquire(target))
        }
    }

    func testNonRegularSlotIsRejectedWithoutBlocking() throws {
        try withLockDirectory { directory in
            FMCallSlots.concurrencyForTesting = 2
            let fifo = directory.appendingPathComponent("fm.lock.1")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

            XCTAssertThrowsError(try FMCallSlots.acquireForMaintenance())
            XCTAssertTrue(try canAcquire(directory.appendingPathComponent("fm.lock.0")))
        }
    }

    func testUnreadableDirectoryFailsClosed() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read a directory without read permission") }
        try withLockDirectory { directory in
            XCTAssertEqual(chmod(directory.path, 0o300), 0)
            defer { _ = chmod(directory.path, 0o700) }

            XCTAssertThrowsError(try FMCallSlots.acquireForMaintenance())
        }
    }
}
