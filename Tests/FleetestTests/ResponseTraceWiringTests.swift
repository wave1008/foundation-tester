// iOS 実機の計測(xctrace)と Android のアニメーション復元の配線を、`run --profile` と `api run` の両方で固定する。
// **型では守れない継ぎ目**: 片方の入口に足し忘れても、その入口の計測 run が最初のフレーム無しのまま緑で通る。

import XCTest
@testable import fleetest

final class ResponseTraceWiringTests: XCTestCase {

    private static let entrances = ["Sources/fleetest/ProfileRunner.swift", "Sources/fleetest/ApiRunCommand.swift"]

    private static func code(_ path: String) throws -> [String] {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("//") }
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testBothEntrancesStartFinishAndCleanUpTheTrace() throws {
        for path in Self.entrances {
            let lines = try Self.code(path)
            func index(_ needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
            let start = try XCTUnwrap(index("ResponseTraceSession.startIfNeeded("), "\(path): 記録を始めていない")
            let finish = try XCTUnwrap(index("responseTrace?.finish(runDir:"), "\(path): 記録を止めて結果へ入れていない")
            let cleanup = try XCTUnwrap(index("responseTrace?.cleanup()"), "\(path): defer の後始末が無い")
            XCTAssertLessThan(start, finish, path)
            XCTAssertEqual(lines.filter { $0.contains("ResponseTraceSession.startIfNeeded(") }.count, 1, path)
            XCTAssertEqual(lines.filter { $0.contains("responseTrace?.finish(runDir:") }.count, 1, path)
            _ = cleanup
        }
    }

    func testBothEntrancesCaptureBeforeAndRestoreAfterTheAnimationSync() throws {
        for path in Self.entrances {
            let lines = try Self.code(path)
            let capture = try XCTUnwrap(lines.firstIndex { $0.contains("captureAnimationRestore(") }, path)
            let restore = try XCTUnwrap(lines.firstIndex { $0.contains("restoreAnimations(") }, path)
            XCTAssertEqual(lines.filter { $0.contains("captureAnimationRestore(") }.count, 1, path)
            XCTAssertEqual(lines.filter { $0.contains("restoreAnimations(") }.count, 1, path)
            // 取得は buildAndroidWorkers(開始時の同期)を呼ぶ行より前
            if let build = lines.firstIndex(where: { $0.contains("ProfileWorkerFactory.buildAndroidWorkers(") }) {
                XCTAssertLessThan(capture, build, "\(path): 同期の後に元の値を読んでいる")
            }
            _ = restore
        }
    }

    func testSessionNeverReadsAPipeToTheEnd() throws {
        let lines = try Self.code("Sources/fleetest/ResponseTraceSession.swift")
        XCTAssertFalse(lines.contains { $0.contains("readDataToEndOfFile") })
        XCTAssertFalse(lines.contains { $0.contains("FT_PARENT_PID") || $0.contains("childEnvironment") },
                       "見張りは親の死を生き延びる(FT_PARENT_PID を渡すと拡張の孤児掃除に殺される)")
    }
}
