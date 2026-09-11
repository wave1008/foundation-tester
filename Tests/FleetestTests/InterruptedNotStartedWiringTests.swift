// 逐次経路は中断(SIGINT/SIGTERM)を受けるとループを抜ける。そのとき**始まらなかった分を記録して
// 失敗に数える**(RunRecorder.recordInterruptedBeforeStart)。黙って抜けると「全体 - 失敗」で数える
// 経路が走っていない分を合格と数え、「All N passed」で exit 0 になる。ループはデバイスが要るので
// 単体では通せない —— 配線をソースで固定し、黙って抜ける形の再発も落とす。

import XCTest

final class InterruptedNotStartedWiringTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// run の逐次経路1箇所・api run の逐次経路2箇所(直指定 / --profile)
    func testEachSequentialLoopRecordsTheScenariosThatDidNotStart() throws {
        XCTAssertEqual(count("recordInterruptedBeforeStart(", in: try source("Sources/fleetest/Fleetest.swift")), 1)
        XCTAssertEqual(count("recordInterruptedBeforeStart(", in: try source("Sources/fleetest/ApiRunCommand.swift")), 2)
    }

    /// 中断で黙ってループを抜ける形を Sources/fleetest に残さない
    func testNoLoopBreaksSilentlyOnInterrupt() throws {
        let directory = Self.repoRoot.appendingPathComponent("Sources/fleetest")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("guard !interruptState.isStopped else { break }"),
                           "\(file): record the scenarios that did not start (recordInterruptedBeforeStart)")
        }
    }
}
