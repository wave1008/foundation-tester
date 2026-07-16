import XCTest
@testable import FTCore

final class ProcessExitWaitTests: XCTestCase {

    /// 終了待ちがハングする回帰をテストスイート全体の凍結にしないため、期限付きで待つ
    private func awaitExit(_ exited: AsyncStream<Void>, timeoutSeconds: UInt64) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exited {}
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // 回帰: SIGTERM を無視する子を SIGKILL で落としても終了待ちが返る
    // (waitUntilExit はこの経路で永久ハングし、run 全体が凍結した)
    func testReturnsAfterSigkillOfTermIgnoringChild() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 1; done"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = ProcessExitWait.prepare(process)
        try process.run()
        process.terminate()
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = kill(process.processIdentifier, SIGKILL)
        let done = await awaitExit(exited, timeoutSeconds: 10)
        XCTAssertTrue(done, "SIGKILL 後 10s 以内に終了待ちが完了しない")
    }

    // 既終了レース: await より先に子が終了していても取りこぼさない
    func testReturnsWhenProcessAlreadyExited() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let exited = ProcessExitWait.prepare(process)
        try process.run()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let done = await awaitExit(exited, timeoutSeconds: 10)
        XCTAssertTrue(done, "既終了の子に対する終了待ちが完了しない")
    }

    func testBlockingWaitReturnsAndStatusIsSet() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 7"]
        let waitForExit = ProcessExitWait.prepareBlocking(process)
        try process.run()
        waitForExit()
        XCTAssertEqual(process.terminationStatus, 7)
    }
}
