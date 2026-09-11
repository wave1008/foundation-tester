import Foundation
import XCTest
@testable import fleetest

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

    /// `Process` を伴わない購読(手元の `api run`/`run` が中断ハンドラを登録する形)。
    /// **戻すと落ちる根拠**: `.observing` を消す/`forwardToAll` の `.observer` ケースを外すと、
    /// このテストは SIGINT を送ってもコールバックが呼ばれず既定動作(テストプロセスごと終了)に
    /// フォールバックする(このテスト自身が検出用に自分へ SIGINT を送る。壊れていなければ無害)
    func testObservingIsNotifiedOnSignalAndStopsAfterStop() throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
        }
        let flag = Flag()
        let relay = InterruptRelay.observing { flag.increment() }
        XCTAssertEqual(InterruptRelay.registeredCount, 1)

        kill(getpid(), SIGINT)
        let deadline = Date().addingTimeInterval(5)
        while flag.count == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(flag.count, 1, "observer は SIGINT のたびに呼ばれる")

        relay.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 0)
        // stop 後は既定動作(このプロセス自体は SIG_DFL に戻るが、テストを落とさないよう
        // 二度目の SIGINT は送らない —— 「呼ばれ続けない」ことは registeredCount==0 で確認済み)
    }

    /// process 版と observer 版が同時に登録されても、シグナルソースは1組のまま
    /// (1プロセスに1組。CLAUDE.md の規律)
    func testProcessAndObserverTargetsShareOneSignalSourceSet() throws {
        let p = try sleeper()
        defer { if p.isRunning { p.terminate() } }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
        }
        let flag = Flag()
        let processRelay = InterruptRelay.forwarding(to: p, escalateAfter: nil)
        let observerRelay = InterruptRelay.observing { flag.increment() }
        XCTAssertEqual(InterruptRelay.registeredCount, 2)

        kill(getpid(), SIGINT)
        let deadline = Date().addingTimeInterval(5)
        while (p.isRunning || flag.count == 0), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(p.isRunning, "process 版も引き続き届く")
        XCTAssertEqual(flag.count, 1, "observer 版も同じシグナルで届く")

        processRelay.stop()
        observerRelay.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 0)
    }
}
