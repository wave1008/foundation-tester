// BridgeLauncher.confirmDeathThenRemovePidFile: pid ファイルは「プロセス死亡確認後」にのみ
// 消す(即削除すると assignPort がポートを空きと誤認し bindFailed(48) を招く)ことを、実プロセス
// (/bin/sleep)を立てて検証する。

import XCTest
@testable import FTBridgeClient

final class BridgeLauncherStopTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftbridge-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func writePid(_ pid: Int32, port: UInt16) throws -> URL {
        let path = stateDir.appendingPathComponent("bridge-\(port).pid")
        try String(pid).write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    func testRemovesPidFileOnlyAfterProcessDies() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        let pid = proc.processIdentifier
        let pidPath = try writePid(pid, port: 8199)

        kill(pid, SIGTERM)
        BridgeLauncher.confirmDeathThenRemovePidFile(pid: pid, pidPath: pidPath, timeout: 5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath.path),
                       "死亡確認を経て pid ファイルが削除される")
        XCTAssertNotEqual(kill(pid, 0), 0, "プロセスは死亡している")
        proc.waitUntilExit()
    }

    func testRemovesPidFileWhenProcessAlreadyDead() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["0"]
        try proc.run()
        proc.waitUntilExit()  // 既に終了・reap 済み
        let pidPath = try writePid(proc.processIdentifier, port: 8198)

        BridgeLauncher.confirmDeathThenRemovePidFile(
            pid: proc.processIdentifier, pidPath: pidPath, timeout: 5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath.path),
                       "不在プロセスの pid ファイルは即削除される")
    }
}
