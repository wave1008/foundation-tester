import XCTest
@testable import FTBridgeClient

/// 実機ブリッジの LAN 宣言待ちが**キャンセルで即座に抜ける**こと。
/// 呼び手(ProfileWorkerFactory.buildWorker)は期限付き TaskGroup で cancelAll するが、
/// `try? Task.sleep` は取り消しを握りつぶすので、見ないと締切(既定 180s)まで空回りし、
/// その間に次の試行が同じポートへ2本目のランナーを起動して孤児が残る(2026-09-04 実測)
final class PhysicalBridgeWaitCancellationTests: XCTestCase {

    func testAnnounceWaitStopsPromptlyWhenCancelled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-announce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 宣言の無い空ログ = 何も起きなければ 30 秒待つ
        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".fleetest/bridge-8199.log").path, contents: Data())

        let started = Date()
        let task = Task<String, Error> {
            try await IOSDeviceTransport.waitForAnnouncedAddress(
                port: 8199, repoRoot: root, timeoutSeconds: 30)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled wait must throw")
        } catch is CancellationError {
            // expected
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5, "cancel must not wait for the 30s deadline (took \(elapsed)s)")
    }
}
