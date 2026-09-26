// RemoteRunDispatcher.acquireDispatchLock waits on a remote FIFO queue via repeated ssh round
// trips (Shell.run against the real host). That loop can't be driven by a normal unit test
// without a live runner, so — same technique as RemoteDispatchLockInterruptRelayTests.swift —
// these tests pin the source shape of two behaviors that must hold inside the wait loop:
//
//   1. the loop checks `interruptFlag.interrupted` every cycle (a Ctrl-C while queued must stop
//      the wait instead of running to completion and then starting the actual remote run)
//   2. the auto-release of our own stale lock (`autoReleaseOurStaleLock`) is attempted on every
//      `.held` cycle, not gated behind a "tried once" flag (the holder can die while we wait,
//      not just before we start waiting — LocalDispatchLock.acquire already does this and this
//      pins the remote side matching it)

import Foundation
import XCTest

final class RemoteDispatchLockWaitLoopTests: XCTestCase {

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

    private static func acquireDispatchLockBody() throws -> Substring {
        let source = try Self.source()
        guard let funcRange = source.range(of: "private func acquireDispatchLock(") else {
            XCTFail("acquireDispatchLock not found in RemoteRunDispatcher.swift")
            return Substring("")
        }
        // 次の `private func` までを1関数分の本文とみなす(厳密な波括弧対応は取らない —— 他の
        // テストも同じ簡易スキャンで足りている)
        let rest = source[funcRange.lowerBound...]
        guard let nextFunc = rest.dropFirst(1).range(of: "\n    private func ") else { return rest }
        return rest[rest.startIndex..<nextFunc.lowerBound]
    }

    // MARK: - 1. 待機ループは毎周 interruptFlag を見る

    func testAcquireDispatchLockTakesAnInterruptFlagParameter() throws {
        let source = try Self.source()
        XCTAssertTrue(
            source.contains("private func acquireDispatchLock(layout: RemoteLayout, runGroup: String?,")
            && source.contains("interruptFlag: DispatchInterruptFlag) throws {"),
            "acquireDispatchLock must take the caller's interruptFlag — without it, a Ctrl-C while"
            + " queued for the lock can't be observed inside the wait loop")
    }

    func testTheWaitLoopChecksTheInterruptFlagBeforeSleeping() throws {
        let body = try Self.acquireDispatchLockBody()
        guard let progressRange = body.range(of: "emitDispatchWaiting(status)") else {
            return XCTFail("progress-log block not found")
        }
        guard let sleepRange = body.range(of: "Thread.sleep(forTimeInterval:") else {
            return XCTFail("Thread.sleep not found")
        }
        guard let checkRange = body.range(of: "guard !interruptFlag.interrupted else {") else {
            return XCTFail("no interruptFlag check in the wait loop — a Ctrl-C while queued for"
                          + " the dispatch lock would be ignored until the run finally acquires it")
        }
        XCTAssertTrue(progressRange.upperBound < checkRange.lowerBound
                     && checkRange.upperBound < sleepRange.lowerBound,
                     "the interrupt check must sit between the progress log and Thread.sleep,"
                     + " so an interrupted wait never reaches the sleep for one more cycle")
    }

    /// 取得の直後(dispatch()/dispatchApi() 側)にも中断を見て、既に取ったロックを外してから
    /// 抜けることを固定する。**取得より後・prepareWorkspace より前**であること —— 順序が違うと
    /// 中断済みのまま実際のリモート run(prepareWorkspace 以降)まで進んでしまう
    func testBothDispatchFunctionsRecheckInterruptRightAfterAcquiringBeforeStartingTheRemoteRun() throws {
        let source = try Self.source()
        for marker in ["func dispatch(", "func dispatchApi("] {
            guard let funcRange = source.range(of: marker) else {
                XCTFail("\(marker) not found"); continue
            }
            let body = source[funcRange.lowerBound...]
            guard let acquireRange = body.range(of: "try acquireDispatchLock(layout: layout, runGroup: runGroup, interruptFlag: interruptFlag)")
            else { XCTFail("\(marker): acquireDispatchLock call not found"); continue }
            guard let recheckRange = body.range(of: "try bailIfAlreadyInterrupted(") else {
                XCTFail("\(marker): no post-acquire interrupt recheck — a Ctrl-C that arrives"
                        + " exactly as the lock is acquired would still start the remote run")
                continue
            }
            guard let workspaceRange = body.range(of: "prepareWorkspace(") else {
                XCTFail("\(marker): prepareWorkspace call not found"); continue
            }
            XCTAssertTrue(acquireRange.upperBound < recheckRange.lowerBound
                         && recheckRange.upperBound < workspaceRange.lowerBound,
                         "\(marker): the interrupt recheck must sit between acquireDispatchLock and"
                         + " prepareWorkspace")
        }
    }

    // MARK: - 2. 自動回収は毎周試す(1回だけのガードを持たない)

    func testAutoReleaseIsNotGatedBehindASingleAttemptFlag() throws {
        let source = try Self.source()
        XCTAssertFalse(source.contains("autoReleaseTried"),
                       "a single-attempt guard reappeared for autoReleaseOurStaleLock — it must be"
                       + " tried on every `.held` cycle (the holder can die while we wait, not just"
                       + " before we start waiting; LocalDispatchLock.acquire already does this)")
    }

    func testTheHeldBranchCallsAutoReleaseUnconditionally() throws {
        let body = try Self.acquireDispatchLockBody()
        guard let heldRange = body.range(of: "if case .held = outcome {") else {
            return XCTFail("the .held branch was not found in its expected shape")
        }
        let afterHeld = body[heldRange.upperBound...]
        let nextMeaningfulLine = afterHeld
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        XCTAssertEqual(nextMeaningfulLine.trimmingCharacters(in: .whitespaces),
                       "switch autoReleaseOurStaleLock(layout: layout) {",
                       "the .held branch must call autoReleaseOurStaleLock as its very next"
                       + " statement, not behind another condition")
    }
}
