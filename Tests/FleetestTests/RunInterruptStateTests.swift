// `RunInterruptState`(手元だけの `api run`/`run` が SIGINT/SIGTERM を受けたときに握る状態)。
// 二役(新規シナリオの配布停止フラグ・実行中の子への SIGTERM)を検証する。
//
// **注意**: `requestStop()` は2回目の呼び出しで `exit(143)` する(1回目で通常の完了経路が
// 刺さったとき人が抜けられるようにするための最終手段)。このファイルの各テストは
// `requestStop()` をちょうど1回しか呼ばない —— 2回呼ぶとテストプロセスごと終了する

import XCTest
@testable import fleetest

final class RunInterruptStateTests: XCTestCase {

    private func sleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    /// 戻すと落ちる根拠: `requestStop()` が `runningProcesses` を撃たなくなると、
    /// 中断時に「今動いているシナリオ子」が SIGTERM されず孤児として残る
    /// 
    func testRequestStopTerminatesRegisteredRunningProcesses() throws {
        let state = RunInterruptState(recorder: nil)
        let p = try sleeper()
        defer { if p.isRunning { p.terminate() } }
        let unregister = state.registerChildProcess(p)
        defer { unregister() }

        XCTAssertFalse(state.isStopped)
        state.requestStop()
        XCTAssertTrue(state.isStopped)

        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(p.isRunning, "登録済みの子は requestStop() で SIGTERM される")
    }

    /// 戻すと落ちる根拠: `registerChildProcess` が「既に中断済みならその場で SIGTERM」を
    /// 落とすと、register と中断到着が競合したとき(中断が先に来ていた場合)その子だけ
    /// 生き残ってしまう
    func testRegisterChildProcessTerminatesImmediatelyIfAlreadyStopped() throws {
        let state = RunInterruptState(recorder: nil)
        state.requestStop()  // まだ何も登録していない状態で中断済みにする(1回目 = exit しない)
        XCTAssertTrue(state.isStopped)

        let p = try sleeper()
        defer { if p.isRunning { p.terminate() } }
        _ = state.registerChildProcess(p)

        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(p.isRunning, "登録前に中断済みなら、その場で SIGTERM される")
    }

    /// unregister 後は登録簿から外れる(次に requestStop() が呼ばれても触らない ——
    /// 直接には確認できないが、少なくとも unregister 自体がクラッシュしないことを確認する)
    func testUnregisterRemovesTheProcessWithoutCrashing() throws {
        let state = RunInterruptState(recorder: nil)
        let p = try sleeper()
        defer { if p.isRunning { p.terminate() } }
        let unregister = state.registerChildProcess(p)
        unregister()
        unregister()  // 二重呼び出しも無害
        XCTAssertTrue(p.isRunning, "unregister 後の requestStop は届かない前提の確認(まだ止めていない)")
    }

    /// 供給フェーズ間で使い回す発火カウンタ(`attachLateSubscriber` の相手は `@Sendable` なので、
    /// ローカル `var` を直接キャプチャできない。InterruptRelayTests.Flag と同じ形)
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    /// 戻すと落ちる根拠: 供給フェーズより前に立てた interruptState を、オーケストレータ構築後に
    /// `attachLateSubscriber` で合流させる形(ApiRunCommand.runWithProfileParallel /
    /// ProfileRunner.run / Fleetest.runParallel が実際に使う形)。まだ中断していなければ、
    /// requestStop() が呼ばれたときに初めて subscriber が呼ばれる
    func testAttachLateSubscriberFiresOnFirstRequestStop() {
        let state = RunInterruptState(recorder: nil)
        let flag = Flag()
        state.attachLateSubscriber { flag.increment() }
        XCTAssertEqual(flag.count, 0, "登録しただけでは呼ばない")
        state.requestStop()
        XCTAssertEqual(flag.count, 1, "requestStop() の1回目で合流先を呼ぶ")
    }

    /// 戻すと落ちる根拠: 供給フェーズ中(オーケストレータがまだ存在しない間)に中断が届いた場合、
    /// あとから合流した subscriber がその場で追いつけないと、オーケストレータが中断を一生
    /// 知らないまま全シナリオを普通に実行してしまう(G10: リモートの供給フェーズ中の SIGHUP が
    /// この形で run.json を尻切れのまま残した)
    func testAttachLateSubscriberFiresImmediatelyIfAlreadyStopped() {
        let state = RunInterruptState(recorder: nil)
        state.requestStop()  // まだ何も合流していない状態で中断済みにする(1回目 = exit しない)
        XCTAssertTrue(state.isStopped)

        let flag = Flag()
        state.attachLateSubscriber { flag.increment() }
        XCTAssertEqual(flag.count, 1, "合流前に既に中断済みなら、その場で呼ばれる")
    }
}
