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
        let state = RunInterruptState()
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
        let state = RunInterruptState()
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
        let state = RunInterruptState()
        let p = try sleeper()
        defer { if p.isRunning { p.terminate() } }
        let unregister = state.registerChildProcess(p)
        unregister()
        unregister()  // 二重呼び出しも無害
        XCTAssertTrue(p.isRunning, "unregister 後の requestStop は届かない前提の確認(まだ止めていない)")
    }
}
