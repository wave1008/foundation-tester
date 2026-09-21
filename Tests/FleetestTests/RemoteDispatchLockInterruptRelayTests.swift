// bug-audit-2026-09-06.md §3: `RemoteRunDispatcher.dispatch`/`dispatchApi` acquire a remote
// `dispatch.lock` and release it via `defer { releaseDispatchLock(...) }`. Between the lock
// acquisition and the two `runInherited*` calls (the only spots that register an
// `InterruptRelay`), every step is a plain `Shell.run` ssh/rsync call with no relay of its own.
// With zero `InterruptRelay` targets registered, SIGINT/SIGTERM/SIGHUP keep their default
// disposition (immediate termination) instead of being routed through `forwardToAll()`, so the
// `releaseDispatchLock` defer never runs and the remote lock is left stuck until someone runs
// `fleetest remote unlock`.
//
// The fix registers a no-op `InterruptRelay.observing` immediately before `acquireDispatchLock`
// (stopped after `releaseDispatchLock`'s defer, since defers run in reverse declaration order) —
// its mere registration flips SIGINT/SIGTERM/SIGHUP to `SIG_IGN` + GCD dispatch, which keeps the
// process alive long enough to run its defers. This is a wiring contract a normal unit test can't
// exercise (it requires actually sending a signal mid-ssh-dispatch), so this pins the source
// shape instead: the observer must be registered, and it must come before `acquireDispatchLock`
// in both `dispatch()` and `dispatchApi()`.

import Foundation
import XCTest

final class RemoteDispatchLockInterruptRelayTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
    }

    private static func source() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/fleetest/RemoteRunDispatcher.swift"),
            encoding: .utf8)
    }

    func testBothDispatchFunctionsObserveInterruptsBeforeAcquiringTheLock() throws {
        let source = try Self.source()
        for marker in ["func dispatch(", "func dispatchApi("] {
            guard let funcRange = source.range(of: marker) else {
                XCTFail("\(marker) not found in RemoteRunDispatcher.swift")
                continue
            }
            let body = source[funcRange.lowerBound...]
            guard let relayRange = body.range(of: "InterruptRelay.observing") else {
                XCTFail("\(marker): no InterruptRelay.observing registration"
                        + " — a SIGINT during ssh/rsync steps after the lock is acquired"
                        + " would skip releaseDispatchLock's defer and leave the remote lock stuck")
                continue
            }
            guard let acquireRange = body.range(of: "try acquireDispatchLock(") else {
                XCTFail("\(marker): acquireDispatchLock call not found")
                continue
            }
            XCTAssertTrue(relayRange.lowerBound < acquireRange.lowerBound,
                          "\(marker): InterruptRelay.observing must be registered before"
                          + " acquireDispatchLock, so it is already active for the whole"
                          + " lock-held section (including acquireDispatchLock itself)")
        }
    }
}
