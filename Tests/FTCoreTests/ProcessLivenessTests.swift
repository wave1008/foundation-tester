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
}
