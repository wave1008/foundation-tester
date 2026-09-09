// PID 再利用ガード: TTL 自主終了(design.md §4.1)後に bridge-<port>.pid が残ったまま、その pid が
// 数日後に無関係なプロセスへ再利用されると、`fleetest bridge down --port N` がその無関係プロセスを
// 撃ってしまう欠陥が指摘された。stop()/stopAndWait() は kill する前に
// BridgeLauncher.isOurRunner(pid:port:) でコマンドラインを確認し、一致しなければ撃たず
// stale な pid ファイルだけ片付ける。

import FTCore
import XCTest
@testable import FTBridgeClient

final class BridgeLauncherPidReuseTests: XCTestCase {

    // MARK: - isOurRunner(command:port:) の pure な判定

    func testIsOurRunnerMatchesThisPortsXctestrun() {
        let command = "/usr/bin/xcodebuild test-without-building -xctestrun"
            + " /a/b/DerivedData/Build/Products/FleetestRunner-8123.xctestrun -destination ..."
        XCTAssertTrue(BridgeLauncher.isOurRunner(command: command, port: 8123))
    }

    func testIsOurRunnerRejectsDifferentPort() {
        let command = "/usr/bin/xcodebuild test-without-building -xctestrun"
            + " /a/b/DerivedData/Build/Products/FleetestRunner-8124.xctestrun -destination ..."
        XCTAssertFalse(BridgeLauncher.isOurRunner(command: command, port: 8123),
                       "別ポート専用の xctestrun を自分のものと誤認しないこと")
    }

    func testIsOurRunnerRejectsUnrelatedProcess() {
        XCTAssertFalse(BridgeLauncher.isOurRunner(command: "/bin/sleep 30", port: 8123),
                       "PID 再利用で無関係プロセスに化けたコマンドラインは false")
    }

    // MARK: - stop() / stopAndWait(): pid が生きているが自分たちのランナーでないとき撃たない

    /// 死ぬまで待つ(**壁時計の閾値で合否を決めない** —— 「死んだ」という事象そのものを待つ)。
    /// 期限は「負荷で遅れても十分」な上限で、通常は数十 ms で返る
    private func waitUntilNotAlive(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessLiveness.isAlive(pid) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !ProcessLiveness.isAlive(pid)
    }

    private func makeRepoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-pidreuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        return root
    }

    func testStopDoesNotKillReusedPidAndRemovesStaleFile() throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = BridgeLauncher(repoRoot: root, device: "U", port: 8188, physical: false)

        // 無関係な生きたプロセス(コマンドラインに FleetestRunner-8188.xctestrun を含まない)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        defer { proc.terminate() }
        try String(proc.processIdentifier).write(to: launcher.pidPath, atomically: true, encoding: .utf8)

        try launcher.stop()

        // **生死の判定は ProcessLiveness**(`kill(pid, 0)` はゾンビにも成功するので、撃たれた
        // 直後の未 reap を「生きている」と誤って読む = 撃ってしまっても緑になる)
        XCTAssertTrue(ProcessLiveness.isAlive(proc.processIdentifier),
                      "無関係プロセスを撃ってはいけない(PID 再利用の実害)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.pidPath.path),
                       "stale な pid ファイルは片付けること")
    }

    func testStopAndWaitDoesNotKillReusedPidAndThrowsNotRunning() async throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = BridgeLauncher(repoRoot: root, device: "U", port: 8189, physical: false)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        defer { proc.terminate() }
        try String(proc.processIdentifier).write(to: launcher.pidPath, atomically: true, encoding: .utf8)

        do {
            try await launcher.stopAndWait()
            XCTFail("再利用された pid を自分たちのランナーとして扱ってはいけない")
        } catch LauncherError.notRunning(let notRunningPort) {
            XCTAssertEqual(notRunningPort, 8189 as UInt16?)
        }

        // **生死の判定は ProcessLiveness**(`kill(pid, 0)` はゾンビにも成功するので、撃たれた
        // 直後の未 reap を「生きている」と誤って読む = 撃ってしまっても緑になる)
        XCTAssertTrue(ProcessLiveness.isAlive(proc.processIdentifier),
                      "無関係プロセスを撃ってはいけない(PID 再利用の実害)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.pidPath.path),
                       "stale な pid ファイルは片付けること")
    }

    /// 陽性対照: 本物の(コマンドラインにこのポート専用の xctestrun を含む)プロセスは
    /// 従来どおり撃たれること。実際に xcodebuild を起動する余裕は無いので、コマンドライン照合の
    /// 対象になる文字列を含む代役プロセスで代える
    func testStopKillsProcessWhoseCommandLineMatchesThisPort() throws {
        let root = try makeRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = BridgeLauncher(repoRoot: root, device: "U", port: 8190, physical: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // sh が exec して自分を置き換えると ps の command から引数が消える(IOSPhysicalDeviceTests の
        // testPortsMatchingFindsBridgeByUDIDInProcessArguments と同じ罠)。`;` で2コマンドにして残す
        process.arguments = ["-c", "sleep 30; : -xctestrun FleetestRunner-8190.xctestrun"]
        try process.run()
        let pid = process.processIdentifier
        try String(pid).write(to: launcher.pidPath, atomically: true, encoding: .utf8)

        try launcher.stop()
        // **`confirmDeaths` は使わない** —— 残っていれば自分で SIGKILL するので、stop() が撃てて
        // いなくてもこの陽性対照が緑になる。**判定も `kill(pid, 0)` では行わない**(ゾンビにも
        // 成功するため、親が reap する前は「生きている」と読む —— 2026-09-10 のフル
        // `swift test` はこれで落ちた。単独では reap が間に合って通っていた)
        XCTAssertTrue(waitUntilNotAlive(pid, timeout: 10),
                      "自分たちのランナーは従来どおり止まること")
        process.waitUntilExit()
    }
}
