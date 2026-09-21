// `fleetest remote unlock --runner local`(= この Mac の dispatch.lock を今すぐ外す)の判定。
// **誰のロックかで証拠が変わる**: この機械から取ったものは pid で確定し(RemoteDispatchUnlock.
// decideLocalSweep)、別の Mac から撃たれたディスパッチのものは手元の pgrep だけで決める
// (guardingLiveRemoteRun)。文言は完全一致で固定する —— 外した / 生きている / 確かめられない
// のどれなのかは、そのまま利用者が次に打つ手を決める。

import Foundation
import XCTest
import FTRemote

final class DispatchUnlockThisMachineTests: XCTestCase {

    /// この Mac から取ったロック(手元の run か、この Mac から撃ったディスパッチ)
    private let mine = RemoteDispatchLockInfo(issuerHost: "my-mac", pid: 4242,
                                              acquiredAt: "2026-09-21T09:00:00Z", issuer: "wave1008")
    /// 他人が別の Mac からこの機械へ撃ったディスパッチのロック(pid は**向こうの** pid)
    private let dispatchedHere = RemoteDispatchLockInfo(issuerHost: "alice-mbp", pid: 77,
                                                        acquiredAt: "2026-09-21T09:30:00Z", issuer: "alice")

    private func decide(_ probe: RemoteDispatchLock.Probe, alive: @escaping (Int32) -> Bool = { _ in false },
                        livePIDs: @escaping () -> [Int32]?) -> RemoteDispatchUnlock.Decision {
        RemoteDispatchUnlock.decideThisMachine(probe: probe, myIssuer: "wave1008", myHost: "my-mac",
                                               pidAlive: alive, livePIDs: livePIDs)
    }

    // MARK: - この機械から取ったロック(pid だけで決まる)

    func testMyDeadRunsLockIsReleased() {
        guard case .release(let reason) = decide(.held(mine), livePIDs: { XCTFail("pgrep は要らない"); return [] })
        else { return XCTFail("死んだ自分の run のロックは外す") }
        XCTAssertEqual(reason, "your dispatch (pid 4242) is no longer running on this machine")
    }

    func testMyLiveRunsLockIsKept() {
        guard case .refuse(let reason) = decide(.held(mine), alive: { $0 == 4242 },
                                                livePIDs: { XCTFail("pgrep は要らない"); return [] })
        else { return XCTFail("走っている自分の run のロックを外してはいけない") }
        XCTAssertEqual(reason, "your dispatch (pid 4242) is still running on this machine"
            + " — stop it and it releases the lock itself")
    }

    /// 同じ機械から取った**他人名義**のロックは、pid が死んでいても手動では外さない
    /// (`decideLocalSweep` の規則そのまま。奪うのは `--force-lock` の役目)
    func testALockTakenOnThisMachineByAnotherIssuerIsKept() {
        let theirs = RemoteDispatchLockInfo(issuerHost: "my-mac", pid: 9, acquiredAt: "x", issuer: "alice")
        guard case .refuse(let reason) = decide(.held(theirs), livePIDs: { [] })
        else { return XCTFail("同じ機械の他人名義のロックは外さない") }
        XCTAssertTrue(reason.contains("alice"), reason)
    }

    // MARK: - 別の Mac から撃たれたディスパッチのロック(手元の pgrep だけで決まる)

    func testALockDispatchedHereIsReleasedWhenNoSuchRunIsLeft() {
        guard case .release(let reason) = decide(.held(dispatchedHere), alive: { _ in true },
                                                 livePIDs: { [] })
        else { return XCTFail("守っている run がこの機械に居ないなら外す") }
        XCTAssertEqual(reason, "it was dispatched to this Mac by alice (from alice-mbp, pid 77)"
            + " and no run it started is left here")
    }

    func testALockDispatchedHereIsKeptWhileItsRunIsStillHere() {
        guard case .refuse(let reason) = decide(.held(dispatchedHere), livePIDs: { [311, 512] })
        else { return XCTFail("この機械で走っている run のロックを外してはいけない") }
        XCTAssertEqual(reason, "a run dispatched to this Mac is still running here (pid 311, 512)"
            + " — the Mac that started it may be gone, but that run is not."
            + " Wait for it to finish; it releases the lock itself when it does")
    }

    /// **確かめられないなら外さない**(pgrep が撃てなかった = 不明を空きに倒さない)
    func testALockDispatchedHereIsKeptWhenTheCheckCouldNotRun() {
        guard case .refuse(let reason) = decide(.held(dispatchedHere), livePIDs: { nil })
        else { return XCTFail("確かめられなかったら外さない") }
        XCTAssertEqual(reason, "could not check whether a run dispatched to this Mac is still running here")
    }

    /// 控えの pid は**向こうの Mac のもの**なので見ない(見ると手元の無関係な pid に当たる)
    func testThePidInALockDispatchedHereIsNeverConsulted() {
        var pidChecked = false
        _ = decide(.held(dispatchedHere), alive: { _ in pidChecked = true; return true }, livePIDs: { [] })
        XCTAssertFalse(pidChecked, "別の Mac の pid の生死を手元で判定している")
    }

    // MARK: - ロックが無い / 読めない

    func testAbsentLockIsNothingToDo() {
        XCTAssertEqual(decide(.absent, livePIDs: { XCTFail("pgrep は要らない"); return [] }), .nothingToDo)
    }

    func testAnUnreadableLockIsKept() {
        guard case .refuse(let reason) = decide(.held(nil), livePIDs: { [] })
        else { return XCTFail("読めないロックも尊重する") }
        XCTAssertEqual(reason, "the lock's info.json could not be read, so its owner is unknown"
            + " — if you are sure no run is going on this Mac, pass --force-lock on your next run")
    }

    // MARK: - base を絞らない pgrep

    /// 発行側の `--remote-dir` は控えに残らないので、既定 base を仮定して撃つと**別の base の
    /// 生きている run** を見落として外してしまう。base 無しのパターンは base 指定版の上位集合
    func testTheAnyBaseProbeMatchesEveryBase() {
        let anyBase = RemoteDispatchLock.liveDispatchedRunsAnyBaseCommand()
        XCTAssertTrue(anyBase.contains("/users/[^ /]+/work/\\.fleetest/dispatch/"), anyBase)
        let specific = RemoteDispatchLock.liveDispatchedRunsCommand(base: "/Users/me/fleetest-runner")
        XCTAssertTrue(specific.contains("/users/[^ /]+/work/\\.fleetest/dispatch/"), specific)
        XCTAssertFalse(anyBase.contains("fleetest-runner"), anyBase)
    }

    /// **本物の pgrep に当てる**: 既定とは違う base のディスパッチ run も拾うこと(拾えないと、
    /// 生きている run のロックを「run は居ない」と読んで外す)。おとり(dispatch/ 以外の
    /// report-dir)は拾わない
    func testTheAnyBaseProbeFindsARunUnderAnUnexpectedBase() throws {
        let base = "/tmp/ftlocal-\(UUID().uuidString)"
        let dispatched = try spawn(reportDir: "\(base)/users/alice/work/.fleetest/dispatch/s1/reports")
        let decoy = try spawn(reportDir: "\(base)/users/alice/work/reports")
        defer {
            dispatched.terminate()
            decoy.terminate()
        }
        Thread.sleep(forTimeInterval: 0.3)
        let pids = try probePIDs()
        XCTAssertTrue(pids.contains(dispatched.processIdentifier), "\(pids)")
        XCTAssertFalse(pids.contains(decoy.processIdentifier), "\(pids)")
    }

    private func spawn(reportDir: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `; true` で sh を残す(単一コマンドだと sh が sleep へ exec して引数が消える)
        process.arguments = ["-c", "sleep 30; true", "fleetest", "--report-dir", reportDir]
        try process.run()
        return process
    }

    /// 手元は `/bin/sh`(リモートの zsh と同じ綴りが通る契約)
    private func probePIDs() throws -> [Int32] {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh")
        probe.arguments = ["-c", RemoteDispatchLock.liveDispatchedRunsAnyBaseCommand()]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try probe.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        XCTAssertEqual(probe.terminationStatus, 0, "一致なしも 0 で終わること")
        return RemoteDispatchLock.parseLivePIDs(String(decoding: output, as: UTF8.self))
    }
}
