import Foundation
import XCTest
@testable import fleetest

/// live serve の command watchdog は「進まない時間」を測る。観測の各段(前面追従・screenshot・snapshot・
/// springboard 退避・失敗の注記)は個別に期限があるので、段の手前で窓を張り直す
/// (`ResidentProcessGuard.noteCommandProgress`)。命令全体を1本の窓で数えると、劣化したランナー
/// (AX の1問に 20 秒超)で進んでいるのに serve ごと強制終了する(maintainer-notes §68.1)。
/// ①張り直しの意味(アイドル中は何もしない)②観測の段の手前に張り直しがあることをソース走査で固定する。
final class LiveWatchdogProgressScanTests: XCTestCase {

    // MARK: - 張り直しの意味

    func testProgressRestartsTheWindowOnlyWhileACommandIsActive() throws {
        ResidentProcessGuard.noteCommandEnd()
        ResidentProcessGuard.noteCommandProgress()
        XCTAssertNil(ResidentProcessGuard.commandStartedAtForTesting, "アイドル中に窓を開けてはいけない")

        ResidentProcessGuard.noteCommandStart(allowanceSeconds: 0)
        let started = try XCTUnwrap(ResidentProcessGuard.commandStartedAtForTesting)
        Thread.sleep(forTimeInterval: 0.01)
        ResidentProcessGuard.noteCommandProgress()
        let restarted = try XCTUnwrap(ResidentProcessGuard.commandStartedAtForTesting)
        XCTAssertGreaterThan(restarted.uptimeNanoseconds, started.uptimeNanoseconds)
        ResidentProcessGuard.noteCommandEnd()
    }

    // MARK: - ソース走査

    private static var source: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
    }

    /// コメントを落とし、空行を除いた行
    private static func codeLines() throws -> [String] {
        try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// `name` の本体(次の宣言の手前まで)
    private static func body(of name: String, in lines: [String]) throws -> [String] {
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("func \(name)(") }, "\(name) が見つからない")
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("    private func ") || $0.hasPrefix("    func ")
            || $0.hasPrefix("    static func ") || $0.hasPrefix("    private static func ") } ?? lines.endIndex
        return Array(lines[start..<end])
    }

    func testFollowGoesThroughTheHelperOnly() throws {
        let lines = try Self.codeLines()
        XCTAssertFalse(lines.contains { $0.contains("follower?.follow(") },
                       "前面追従は followFrontmost を通す(窓の張り直しが漏れる)")
        XCTAssertEqual(lines.filter { $0.contains(".follow(driver:") }.count, 1)
        let helper = try Self.body(of: "followFrontmost", in: lines)
        XCTAssertEqual(helper.filter { $0.contains("noteCommandProgress()") }.count, 2)
    }

    func testEveryObservationStepRestartsTheWindowFirst() throws {
        let lines = try Self.codeLines()
        var checked = 0
        for name in ["emitObservation", "emitFrame", "snapshotWithSessionFallback"] {
            let body = try Self.body(of: name, in: lines)
            for (i, line) in body.enumerated()
            where line.contains("await driver.") || line.contains("await annotated(") {
                // 直前の行が張り直し(同じ段の中で前置きの計算を挟まない)
                let previous = i > 0 ? body[i - 1] : ""
                XCTAssertTrue(previous.contains("noteCommandProgress()"),
                              "\(name): 「\(line.trimmingCharacters(in: .whitespaces))」の手前に noteCommandProgress が無い")
                checked += 1
            }
        }
        // 走査が段に届いていること(screenshot 2・snapshot 2・launch 1・annotated 2)
        XCTAssertEqual(checked, 7)
    }
}
