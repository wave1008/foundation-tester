// xctrace の見張り(ResponseTraceSession.watcherScript)を実際の /bin/sh で動かす。親の死で、記録の代役と
// 一時フォルダを引数に持つ子(書き出しの代役)の両方が止まり、フォルダが消えること。
// 代役は `tail -f <一時フォルダ>/…`(SIGINT / SIGTERM で終わり、コマンドラインにフォルダを持つ)

import XCTest
@testable import fleetest

final class ResponseTraceWatcherTests: XCTestCase {

    private func launch(_ path: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    func testParentDeathStopsTheRecorderAndTheExportChildThenRemovesTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-trace-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["record.log", "export.log"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        let parent = try launch("/bin/sleep", ["300"])
        let recorder = try launch("/usr/bin/tail", ["-f", dir.appendingPathComponent("record.log").path])
        let export = try launch("/usr/bin/tail", ["-f", dir.appendingPathComponent("export.log").path])
        defer {
            for p in [parent, recorder, export] where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        let watcher = try launch("/bin/sh", ["-c", ResponseTraceSession.watcherScript, "fleetest-trace-watch",
                                             String(parent.processIdentifier), String(recorder.processIdentifier),
                                             dir.path])
        defer { if watcher.isRunning { watcher.terminate() } }

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(watcher.isRunning, "親が居る間は待ち続ける")
        XCTAssertTrue(export.isRunning)
        parent.terminate()

        XCTAssertTrue(waitUntil(seconds: 15) { !watcher.isRunning }, "親の死の後、見張りは後始末して終わる")
        XCTAssertFalse(recorder.isRunning, "記録の代役は SIGINT で止まる")
        XCTAssertFalse(export.isRunning, "一時フォルダを引数に持つ子(書き出し)も止まる")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "一時フォルダは消える")
    }
}
