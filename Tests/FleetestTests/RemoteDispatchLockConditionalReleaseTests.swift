// Whether a dispatch that ended abnormally (timeout, ssh disconnect, or a non-normal sub-run
// exit code at the fan-out parent) may release the remote dispatch.lock depends on whether the
// run it started has actually ended on the runner — checked live over ssh. That can't be driven
// by a normal unit test without a real runner, so — same technique as
// RemoteDispatchLockInterruptRelayTests.swift / RemoteDispatchLockWaitLoopTests.swift — these
// tests pin the source shape: an unconditional release must not be reachable from a
// timeout/disconnect/non-normal-exit path; only the "release if the run has ended" judgment
// (`releaseLockIfRunEnded` / `liveDispatchedRunPIDs`) may release in those cases. Substring order
// checks are used instead of exact multi-line literals so continuation-line indentation can't
// make this brittle.

import Foundation
import XCTest

final class RemoteDispatchLockConditionalReleaseTests: XCTestCase {

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

    /// timeout(`runRemoteAndRelay` の throw)は catch して `releaseLockIfRunEnded` を経由してから
    /// rethrow する ―― 素通しで defer の無条件解放に落とさない
    func testBothDispatchFunctionsCatchRunRemoteAndRelayAndCheckIfTheRunEndedBeforeRethrowing() throws {
        let source = try Self.source()
        for marker in ["func dispatch(", "func dispatchApi("] {
            guard let funcRange = source.range(of: marker) else {
                XCTFail("\(marker) not found"); continue
            }
            let body = source[funcRange.lowerBound...]
            guard let callRange = body.range(of: "exitCode = try runRemoteAndRelay(") else {
                XCTFail("\(marker): runRemoteAndRelay call not found"); continue
            }
            guard let catchRange = body.range(of: "} catch {") else {
                XCTFail("\(marker): no catch around runRemoteAndRelay — a timeout throws past"
                        + " everything straight to the unconditional defer release")
                continue
            }
            guard let releaseIfEndedRange = body.range(of: "releaseLockIfRunEnded(layout: layout, reportDir: remoteReportDir)")
            else { XCTFail("\(marker): releaseLockIfRunEnded not called"); continue }
            guard let rethrowRange = body.range(of: "throw error") else {
                XCTFail("\(marker): no rethrow after the catch"); continue
            }
            XCTAssertTrue(callRange.upperBound < catchRange.lowerBound
                         && catchRange.upperBound < releaseIfEndedRange.lowerBound
                         && releaseIfEndedRange.upperBound < rethrowRange.lowerBound,
                         "\(marker): must be catch(runRemoteAndRelay) -> releaseLockIfRunEnded ->"
                         + " rethrow, in that order")
        }
    }

    /// `awaitRemoteRunEndIfDisconnected` は Bool を返し、`releaseLockIfRunEnded` を自分で呼ぶ
    /// (以前は待つだけでロックに一切触れず、呼び出し側の defer が無条件に外していた)。
    /// 呼び出し側(dispatch/dispatchApi)は戻り値を `lockReleasedEarly` へ捕まえること
    func testAwaitRemoteRunEndIfDisconnectedReturnsBoolAndReleasesConditionally() throws {
        let source = try Self.source()
        guard let funcRange = source.range(of: "private func awaitRemoteRunEndIfDisconnected(")
        else { return XCTFail("function not found") }
        let body = source[funcRange.lowerBound...]
        guard let signatureEnd = body.range(of: "-> Bool {") else {
            return XCTFail("awaitRemoteRunEndIfDisconnected must return Bool (released-early) —"
                          + " the caller needs to know whether it may skip the unconditional"
                          + " defer release")
        }
        guard let paramsRange = body.range(of: "layout: RemoteLayout,") else {
            return XCTFail("awaitRemoteRunEndIfDisconnected must take layout (needed to call"
                          + " releaseLockIfRunEnded)")
        }
        XCTAssertTrue(paramsRange.upperBound < signatureEnd.lowerBound)
        guard let releaseRange = body.range(of: "releaseLockIfRunEnded(layout: layout, reportDir: reportDir)")
        else {
            return XCTFail("the function must call releaseLockIfRunEnded instead of only logging"
                          + " and leaving the lock untouched")
        }
        XCTAssertTrue(signatureEnd.upperBound < releaseRange.lowerBound)

        for marker in ["func dispatch(", "func dispatchApi("] {
            guard let funcRange = source.range(of: marker) else { continue }
            let callerBody = source[funcRange.lowerBound...]
            guard let assignRange = callerBody.range(of: "lockReleasedEarly = awaitRemoteRunEndIfDisconnected(")
            else {
                XCTFail("\(marker): must capture awaitRemoteRunEndIfDisconnected's return value"
                        + " into lockReleasedEarly — otherwise the unconditional defer release"
                        + " still fires underneath it")
                continue
            }
            _ = assignRange  // 存在確認のみ(継続行のインデントは崩れやすいので厳密比較しない)
        }
    }

    /// 親(fan-out)の解放は exitCode を受け取り、0/1(正常終了)以外は
    /// `liveDispatchedRunPIDs` で生死を確かめてから外す(無条件の releaseDispatchLock へ
    /// 素通ししない)
    func testReleaseDispatchLockAsParentChecksLivePIDsForNonNormalExitCodes() throws {
        let source = try Self.source()
        guard let funcRange = source.range(of: "func releaseDispatchLockAsParent(layout: RemoteLayout, exitCode: Int32?) {")
        else {
            return XCTFail("releaseDispatchLockAsParent(layout:exitCode:) not found — the parent"
                          + " release must take the sub-run's exit code")
        }
        let body = source[funcRange.lowerBound...]
        // 次の宣言(func/private func のどちらか)までをこの関数の本文とみなす
        let boundary = ["\n    func ", "\n    private func "]
            .compactMap { body.dropFirst(1).range(of: $0)?.lowerBound }
            .min() ?? body.endIndex
        let ownBody = body[body.startIndex..<boundary]
        guard let normalCheckRange = ownBody.range(of: "exitCode == 0 || exitCode == 1") else {
            return XCTFail("must special-case exactly the normal exit codes (0/1) — treating nil"
                          + " (unknown) as normal would release a lock whose sub-run's fate is"
                          + " unknown")
        }
        guard let livePIDsRange = ownBody.range(of: "liveDispatchedRunPIDs(layout: layout)") else {
            return XCTFail("the non-normal branch must consult liveDispatchedRunPIDs before releasing")
        }
        XCTAssertTrue(normalCheckRange.upperBound < livePIDsRange.lowerBound,
                      "liveDispatchedRunPIDs must be checked inside the non-normal-exit-code branch")
    }
}
