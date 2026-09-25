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
}
