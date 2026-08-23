import Foundation
import XCTest
@testable import ftester

/// 並行する relay の1つを止めても、残りの子への横取りが解けないことを固定する
/// (受け手報告 2026-08-23: 手元の子が先に終わった分散 run の親へ kill -INT → 親だけ死んで
/// M1Max の子・ssh・リモートの run・dispatch.lock が残った)。
/// **このテストは自プロセスへ SIGINT を撃つ**: 横取りが解けていれば既定動作でテストプロセスごと
/// 落ちる(= 検出)。壊れていない限り無害
final class InterruptRelayTests: XCTestCase {

    private func sleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    func testStoppingOneRelayKeepsForwardingToTheOthers() throws {
        let first = try sleeper()
        let second = try sleeper()
        defer {
            if first.isRunning { first.terminate() }
            if second.isRunning { second.terminate() }
        }
        let relayA = InterruptRelay.forwarding(to: first, escalateAfter: nil)
        let relayB = InterruptRelay.forwarding(to: second, escalateAfter: nil)
        XCTAssertEqual(InterruptRelay.registeredCount, 2)
        relayA.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 1)

        kill(getpid(), SIGINT)

        let deadline = Date().addingTimeInterval(5)
        while second.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(second.isRunning, "the remaining child must receive the relayed SIGTERM")
        XCTAssertTrue(first.isRunning, "a stopped relay must not forward to its (already released) child")
        relayB.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 0)
    }

    func testStopIsIdempotentAndRestoresDefaultOnlyWhenEmpty() throws {
        let p = try sleeper()
        defer { if p.isRunning { p.terminate() } }
        let relay = InterruptRelay.forwarding(to: p, escalateAfter: nil)
        relay.stop()
        relay.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 0)
    }
}
