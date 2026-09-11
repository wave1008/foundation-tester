// 自分の死んだディスパッチのロックを外す前に、ランナー上でその run がまだ生きていないかを見る
// (RemoteDispatchUnlock.guardingLiveRemoteRun / RemoteDispatchLock.liveDispatchedRunsCommand)。
// 手元の pid が死んでもリモートの run は最後まで流れることがあり(kill -9 で実測)、そこで外すと
// 同じ台へ2本目が乗る。

import Foundation
import XCTest
import FTRemote

final class RemoteDispatchLiveRunGuardTests: XCTestCase {

    private let released = RemoteDispatchUnlock.Decision.release(reason: "your dispatch is no longer running")

    func testReleaseIsKeptWhenNoDispatchedRunIsAlive() {
        XCTAssertEqual(RemoteDispatchUnlock.guardingLiveRemoteRun(released, livePIDs: []), released)
    }

    func testReleaseIsRefusedWhileTheDispatchedRunIsStillAlive() {
        guard case .refuse(let reason) = RemoteDispatchUnlock.guardingLiveRemoteRun(
            released, livePIDs: [87597, 88271]) else { return XCTFail("must refuse") }
        XCTAssertTrue(reason.contains("pid 87597, 88271"), reason)
        XCTAssertTrue(reason.contains("still running on the runner"), reason)
    }

    /// 確かめられなかった(ssh の失敗)は「生きていない」と読まない
    func testReleaseIsRefusedWhenLivenessCouldNotBeChecked() {
        guard case .refuse = RemoteDispatchUnlock.guardingLiveRemoteRun(released, livePIDs: nil)
        else { return XCTFail("must refuse when the check failed") }
    }

    func testNonReleaseDecisionsPassThrough() {
        let refuse = RemoteDispatchUnlock.Decision.refuse(reason: "held by someone else")
        XCTAssertEqual(RemoteDispatchUnlock.guardingLiveRemoteRun(refuse, livePIDs: [1]), refuse)
        XCTAssertEqual(RemoteDispatchUnlock.guardingLiveRemoteRun(.nothingToDo, livePIDs: nil), .nothingToDo)
    }

    func testParseLivePIDs() {
        XCTAssertEqual(RemoteDispatchLock.parseLivePIDs("87597\n 88271 \n\n"), [87597, 88271])
        XCTAssertEqual(RemoteDispatchLock.parseLivePIDs(""), [])
    }

    private func spawn(reportDir: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `; true` で sh を残す(単一コマンドだと sh が sleep へ exec して引数が消える)
        process.arguments = ["-c", "sleep 30; true", "fleetest", "--report-dir", reportDir]
        try process.run()
        return process
    }

    private func probePIDs(base: String) throws -> [Int32] {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")   // ランナーのログインシェルと同じ
        probe.arguments = ["-c", RemoteDispatchLock.liveDispatchedRunsCommand(base: base)]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try probe.run()
        probe.waitUntilExit()
        XCTAssertEqual(probe.terminationStatus, 0, "no match must still exit 0 (told apart from ssh 255)")
        return RemoteDispatchLock.parseLivePIDs(
            String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self))
    }

    /// **本物の pgrep に当てる**: ディスパッチの run の形の引数を持つプロセスだけを拾い、
    /// おとり(dispatch/ 以外の report-dir)と、probe を起動したシェル自身は拾わないこと。
    /// base は既定の置き場(`/Users/<user>/fleetest-runner`)と同じく正規表現の特殊文字を含まない形
    func testProbeFindsOnlyADispatchedRunOnARealProcessTable() throws {
        let base = "/tmp/ftlive-\(UUID().uuidString)"
        let dispatched = try spawn(reportDir: "\(base)/users/alice/work/.fleetest/dispatch/s1/reports")
        let decoy = try spawn(reportDir: "\(base)/users/alice/work/reports")
        defer {
            dispatched.terminate()
            decoy.terminate()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(try probePIDs(base: base), [dispatched.processIdentifier])
    }

    /// base の `.` は文字どおりの `.` にだけ一致する(エスケープしないと別の base の run まで拾う)
    func testBaseIsMatchedLiterally() throws {
        let id = UUID().uuidString
        let other = try spawn(reportDir: "/tmp/ftXdot-\(id)/users/alice/work/.fleetest/dispatch/s1/reports")
        defer { other.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(try probePIDs(base: "/tmp/ft.dot-\(id)"), [])
    }

    /// 一致が無いときも終了コード 0 で空を返す
    func testProbeReturnsNothingWhenNoDispatchedRunIsAlive() throws {
        XCTAssertEqual(try probePIDs(base: "/tmp/ftnone-\(UUID().uuidString)"), [])
    }
}
