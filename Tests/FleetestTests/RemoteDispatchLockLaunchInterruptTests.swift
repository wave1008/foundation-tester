// An interrupt that arrives between acquiring the dispatch lock and launching the ssh session that
// starts the remote run (reapOrphanedHooksAcrossIssuers/prepareWorkspace/transfer) must stop the
// launch: the lock-held relay only marks a flag, and `InterruptRelay.forwarding` is registered after
// `process.run()`. Pins the source shape (same technique as RemoteDispatchLockInterruptRelayTests /
// RemoteDispatchLockConditionalReleaseTests) — driving it live needs real ssh and a timed signal.

@testable import fleetest
import Foundation
import XCTest

final class RemoteDispatchLockLaunchInterruptTests: XCTestCase {

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

    private func occurrences(of needle: String, in text: Substring) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = text.startIndex
        while let next = text.range(of: needle, range: cursor..<text.endIndex) {
            result.append(next)
            cursor = next.upperBound
        }
        return result
    }

    /// dispatch()/dispatchApi() は `bailIfAlreadyInterrupted` を2回呼ぶ(ロック取得直後・
    /// ssh でリモート run を起動する直前)。1回だけだと prepareWorkspace/transfer の間に届いた
    /// 中断は誰も見ないまま起動まで進む
    func testBothDispatchFunctionsCheckInterruptedBeforeAcquiringAndBeforeLaunchingTheRemoteRun() throws {
        let source = try Self.source()
        for marker in ["func dispatch(", "func dispatchApi("] {
            guard let funcRange = source.range(of: marker) else {
                XCTFail("\(marker) not found"); continue
            }
            let body = source[funcRange.lowerBound...]
            // 次の宣言(func/private func)までをこの関数の本文とみなす
            let boundary = ["\n    func ", "\n    private func "]
                .compactMap { body.dropFirst(1).range(of: $0)?.lowerBound }
                .min() ?? body.endIndex
            let ownBody = body[body.startIndex..<boundary]
            let bailCalls = occurrences(of: "try bailIfAlreadyInterrupted(", in: ownBody)
            XCTAssertEqual(bailCalls.count, 2, "\(marker): must call bailIfAlreadyInterrupted"
                          + " exactly twice — once right after acquiring the lock, once right"
                          + " before launching the ssh session that starts the remote run")
            guard bailCalls.count == 2,
                  let acquireRange = ownBody.range(of: "try acquireDispatchLock("),
                  let launchRange = ownBody.range(of: "exitCode = try runRemoteAndRelay(")
            else { continue }
            XCTAssertTrue(acquireRange.upperBound < bailCalls[0].lowerBound
                         && bailCalls[0].upperBound < launchRange.lowerBound
                         && bailCalls[1].upperBound < launchRange.lowerBound,
                         "\(marker): the two checks must straddle everything between acquiring"
                         + " the lock and launching the remote run (hooks reap + workspace prep"
                         + " + transfer)")
        }
    }

    /// runRemoteAndRelay は interruptFlag を受け取り(既定値なし)、そのまま
    /// runInheritedWithLineRewrite へ渡す
    func testRunRemoteAndRelayForwardsInterruptFlagToLineRewrite() throws {
        let source = try Self.source()
        guard let funcRange = source.range(of: "private func runRemoteAndRelay(") else {
            return XCTFail("runRemoteAndRelay not found")
        }
        let body = source[funcRange.lowerBound...]
        guard let signatureEnd = body.range(of: "-> Int32 {") else {
            return XCTFail("runRemoteAndRelay signature not found")
        }
        let signature = body[body.startIndex..<signatureEnd.upperBound]
        XCTAssertTrue(signature.contains("interruptFlag: DispatchInterruptFlag"),
                     "runRemoteAndRelay must take interruptFlag with no default value")
        guard let callRange = body.range(of: "try runInheritedWithLineRewrite(") else {
            return XCTFail("runInheritedWithLineRewrite call not found")
        }
        let callSite = body[callRange.lowerBound...].prefix(600)
        XCTAssertTrue(callSite.contains("interruptFlag: interruptFlag"),
                     "runRemoteAndRelay must forward its own interruptFlag to"
                     + " runInheritedWithLineRewrite")
    }

    /// runInheritedWithLineRewrite は forwarding を登録した**直後**にもう一度 interruptFlag を
    /// 見て、立っていれば process.terminate() を自分で撃つ(forwarding 登録前に届いていた中断が
    /// 素通りしない)
    func testRunInheritedWithLineRewriteRechecksInterruptRightAfterRegisteringForwarding() throws {
        let source = try Self.source()
        guard let funcRange = source.range(of: "private func runInheritedWithLineRewrite(") else {
            return XCTFail("runInheritedWithLineRewrite not found")
        }
        let body = source[funcRange.lowerBound...]
        guard let signatureEnd = body.range(of: "-> Int32 {") else {
            return XCTFail("signature not found")
        }
        let signature = body[body.startIndex..<signatureEnd.upperBound]
        XCTAssertTrue(signature.contains("interruptFlag: DispatchInterruptFlag"),
                     "runInheritedWithLineRewrite must take interruptFlag with no default value")
        guard let forwardingRange = body.range(of: "InterruptRelay.forwarding(to: process)") else {
            return XCTFail("InterruptRelay.forwarding is not registered here")
        }
        guard let recheckRange = body.range(
            of: "if interruptFlag.interrupted { process.terminate() }")
        else {
            return XCTFail("must recheck interruptFlag right after registering forwarding and"
                          + " call process.terminate() if it is already set")
        }
        guard let deadlineRange = body.range(of: "let deadline =") else {
            return XCTFail("deadline computation not found")
        }
        XCTAssertTrue(forwardingRange.upperBound < recheckRange.lowerBound
                     && recheckRange.upperBound < deadlineRange.lowerBound,
                     "the recheck must sit between registering forwarding and starting the"
                     + " timed wait")
    }

    /// ssh を起こす関数は2つだけ(runInherited=rsync/照会用・runInheritedWithLineRewrite=
    /// リモート run の起動用)。新しい ssh 起動経路を足したら、この本数を通して気づき、
    /// 起動直前の中断確認が要るかを判断する
    func testExactlyTwoFunctionsRegisterInterruptForwardingForSSHProcesses() throws {
        let source = try Self.source()
        let count = occurrences(of: "InterruptRelay.forwarding(to: process)", in: source[...]).count
        XCTAssertEqual(count, 2, "a new ssh-launching function must decide whether it needs the"
                      + " same post-registration interrupt recheck as runInheritedWithLineRewrite"
                      + " before this count is updated")
    }

    /// (純粋関数) 親(fan-out)がこのホストのロックを先取りしているときは、
    /// `releaseLockIfRunEnded` が run の生死に関わらず無条件で false を返す(解放の持ち主は
    /// 親の1箇所だけ)ので、「まだ終わっていないかも」とは言わない
    func testShouldLogKeptDispatchLockSkipsWhenParentHoldsTheLock() {
        XCTAssertFalse(RemoteRunDispatcher.shouldLogKeptDispatchLock(parentHoldsLock: true))
        XCTAssertTrue(RemoteRunDispatcher.shouldLogKeptDispatchLock(parentHoldsLock: false))
    }

    /// dispatch()/dispatchApi() の timeout catch と awaitRemoteRunEnd の3箇所とも、
    /// 直書きの log(...) ではなく共有の logKeptDispatchLock を通す(2つ目の判定を作らない)
    func testAllThreeKeptDispatchLockSitesShareTheHelper() throws {
        let source = try Self.source()
        XCTAssertEqual(occurrences(of: "logKeptDispatchLock(afterCollecting:", in: source[...]).count,
                      4, "expected 1 declaration + 3 call sites (dispatch's catch, dispatchApi's"
                      + " catch, awaitRemoteRunEnd) sharing logKeptDispatchLock")
    }
}
