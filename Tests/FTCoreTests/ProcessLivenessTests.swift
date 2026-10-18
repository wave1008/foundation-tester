import Foundation
import XCTest
@testable import FTCore

final class ProcessLivenessTests: XCTestCase {

    func testTheCurrentProcessIsAlive() {
        XCTAssertTrue(ProcessLiveness.isAlive(getpid()))
    }

    /// **ゾンビは死んだ扱い**(実プロセスで確認)。`posix_spawn` で子を起こして `waitpid` せずに
    /// 放置すると exit 済みでも親が回収するまでゾンビとして残り、`kill(pid, 0)` は成功し続ける
    /// (前提条件として明示的に確認する)。`ProcessLiveness.isAlive` はこれを死んだと判定しなければ
    /// ならない(でなければ RunLease 等の鮮度判定がゾンビの間ずっと「生存」を返し続ける)
    func testAZombieIsNotAlive() throws {
        var pid: pid_t = 0
        let path = strdup("/usr/bin/true")
        defer { free(path) }
        var argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
        let spawnStatus = posix_spawn(&pid, "/usr/bin/true", nil, nil, &argv, environ)
        try XCTSkipUnless(spawnStatus == 0, "could not spawn /usr/bin/true (status \(spawnStatus))")

        Thread.sleep(forTimeInterval: 0.5)  // exit してゾンビになるのを待つ

        XCTAssertEqual(kill(pid, 0), 0,
                       "precondition failed: kill(pid, 0) must still succeed on a zombie")
        XCTAssertFalse(ProcessLiveness.isAlive(pid), "a zombie must not read as alive")

        var status: Int32 = 0
        waitpid(pid, &status, 0)  // 回収(残すと本物のゾンビとしてホストに残る)
    }

    func testANonexistentPidIsNotAlive() throws {
        let pid = pid_t(Int32.max - 7)  // 通常割り当てられない領域(衝突しうるので前提を確認する)
        try XCTSkipUnless(kill(pid, 0) == -1 && errno == ESRCH,
                          "pid \(pid) unexpectedly exists on this host")
        XCTAssertFalse(ProcessLiveness.isAlive(pid))
    }

    func testIsAliveStateMatchesProcessStatusSemantics() {
        XCTAssertFalse(ProcessLiveness.isAliveState(SZOMB))
        XCTAssertTrue(ProcessLiveness.isAliveState(SRUN))
        // P_WEXIT が立っていれば SRUN でも死んだ扱い(2026-08-18 にリモートで実測: `ps` の STAT が
        // `?Es` のまま数十分残る = ゾンビになりきらず刺さった形)
        XCTAssertFalse(ProcessLiveness.isAliveState(SRUN, flags: 0x0000_2000))
    }

    // MARK: - isAliveAndNotStartedAfter(pid 再利用を弾く判定)

    /// 自プロセスは実際の開始時刻より後の時刻を記録に持てば「その後に始まった別物」ではない
    func testAliveAndNotStartedAfterIsTrueWhenRecordedAtIsAfterTheRealStart() {
        XCTAssertTrue(ProcessLiveness.isAliveAndNotStartedAfter(getpid(), recordedAt: Date()))
    }

    /// **pid 再利用の再現**: 記録時刻をこの pid が実際に生まれるより前(この場合は epoch 0)に
    /// 置くと、「その pid は記録より後に始まった」= 記録した pid とは別物として死んだ扱いにする
    func testAliveAndNotStartedAfterIsFalseWhenTheRealStartComesAfterTheRecordedTime() {
        XCTAssertFalse(ProcessLiveness.isAliveAndNotStartedAfter(
            getpid(), recordedAt: Date(timeIntervalSince1970: 0)))
    }

    func testAliveAndNotStartedAfterIsFalseForANonexistentPid() throws {
        let pid = pid_t(Int32.max - 7)  // 通常割り当てられない領域(衝突しうるので前提を確認する)
        try XCTSkipUnless(kill(pid, 0) == -1 && errno == ESRCH,
                          "pid \(pid) unexpectedly exists on this host")
        XCTAssertFalse(ProcessLiveness.isAliveAndNotStartedAfter(pid, recordedAt: Date()))
    }

    /// **開始時刻が読めない(不明)ときは生きている側に倒す**(不明を死にしない) ——
    /// 記録時刻がどれだけ古くても、開始時刻を確認できなければ結論を出さない
    func testAliveAndNotStartedAfterTreatsAnUnreadableStartTimeAsAlive() {
        XCTAssertTrue(ProcessLiveness.isAliveAndNotStartedAfter(
            getpid(), recordedAt: Date(timeIntervalSince1970: 0),
            isAliveOverride: { _ in true }, startTimeOverride: { _ in nil }))
    }

    /// pid 自体が死んでいれば、開始時刻の比較にすら進まず死んだ扱い
    func testAliveAndNotStartedAfterIsFalseWhenIsAliveOverrideSaysDead() {
        XCTAssertFalse(ProcessLiveness.isAliveAndNotStartedAfter(
            getpid(), recordedAt: Date(),
            isAliveOverride: { _ in false },
            startTimeOverride: { _ in XCTFail("死んでいるなら開始時刻を読む必要は無い"); return nil }))
    }


    // MARK: - 観測(RecorderWatch が使う 3 値)

    /// sysctl の生の結果 → 観測。**失敗は errno を問わず unreadable**(ENOENT は OID の探索失敗で pid の不在ではない)、
    /// 居ない pid は「成功 + size 0」(macOS の実測・XNU の実装)
    func testClassifyMapsSysctlResultsToObservations() {
        let started = timeval(tv_sec: 1_700_000_000, tv_usec: 123_456)
        XCTAssertEqual(ProcessLiveness.classify(sysctlStatus: 0, size: 0, pStat: Int32(SRUN), flags: 0, started: started), .gone)
        XCTAssertEqual(ProcessLiveness.classify(sysctlStatus: -1, size: 0, pStat: 0, flags: 0, started: started), .unreadable)
        XCTAssertEqual(ProcessLiveness.classify(sysctlStatus: 0, size: 648, pStat: Int32(SZOMB), flags: 0, started: started), .gone)
        XCTAssertEqual(ProcessLiveness.classify(sysctlStatus: 0, size: 648, pStat: Int32(SRUN), flags: 0x0000_2000, started: started),
                       .gone, "終了処理中(P_WEXIT)は死")
        XCTAssertEqual(ProcessLiveness.classify(sysctlStatus: 0, size: 648, pStat: Int32(SRUN), flags: 0, started: started),
                       .alive(startedMicroseconds: 1_700_000_000_123_456), "µs は tv_sec * 1_000_000 + tv_usec(秒へ丸めない)")
    }

    func testObserveSeesALiveChildAndThenItsAbsence() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        guard case .alive = ProcessLiveness.observe(process.processIdentifier) else {
            process.terminate(); process.waitUntilExit()
            return XCTFail("生きている子は alive のはず")
        }
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(ProcessLiveness.observe(process.processIdentifier), .gone, "回収済みの pid は gone")
    }

    /// 同じ秒に起きた 3 本の起動時刻が区別できる(秒へ丸める退行は同じ値にする)。同じ秒に収まらなければ採り直す
    func testStartTimesOfProcessesSpawnedInTheSameSecondDiffer() throws {
        for _ in 0..<5 {
            let processes = try (0..<3).map { _ -> Process in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                process.arguments = ["30"]
                try process.run()
                return process
            }
            defer { processes.forEach { $0.terminate(); $0.waitUntilExit() } }
            let micros = processes.compactMap { process -> Int64? in
                guard case .alive(let value) = ProcessLiveness.observe(process.processIdentifier) else { return nil }
                return value
            }
            XCTAssertEqual(micros.count, 3)
            guard Set(micros.map { $0 / 1_000_000 }).count == 1 else { continue }  // 秒の境目をまたいだ = 採り直す
            XCTAssertEqual(Set(micros).count, 3, "同じ秒の 3 本は µs で区別できるはず: \(micros)")
            return
        }
        XCTFail("5 回とも 3 本が同じ秒に収まらなかった")
    }

    /// µs の起動時刻は、起こす直前(− 1 秒)と直後の壁時計の間に収まる(整合の確認。秒の丸めの検出は上のテストが担う)
    func testStartTimeMicrosecondsLiesWithinTheSpawnWindow() throws {
        let before = Date().timeIntervalSince1970 - 1
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let after = Date().timeIntervalSince1970
        guard case .alive(let micros) = ProcessLiveness.observe(process.processIdentifier) else { return XCTFail("alive のはず") }
        let seconds = Double(micros) / 1_000_000
        XCTAssertGreaterThanOrEqual(seconds, before)
        XCTAssertLessThanOrEqual(seconds, after)
    }
}
