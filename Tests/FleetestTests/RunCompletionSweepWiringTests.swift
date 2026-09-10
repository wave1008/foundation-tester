// run 完了時の背景掃除の配線を固定する。
//
// **型では守れない継ぎ目**: 起こし忘れても run は緑のまま通り、容量が黙って増え続ける。
// 不変条件は3つ ——
//   ①結果を書く経路すべてが掃除を起こす(本数の等号)
//   ②**テストより前には起こさない**(掃除をテストの実行時間に含めない = ユーザー決定)
//   ③子に `FT_PARENT_PID` を渡さない(渡すと親の run の終了と同時に掃除が殺される)

import XCTest
@testable import fleetest

final class RunCompletionSweepWiringTests: XCTestCase {

    private static let sources = ["Sources/fleetest/Fleetest.swift",
                                  "Sources/fleetest/ApiRunCommand.swift"]

    /// 結果を書く経路(`writeJUnitIfRequested` / `ApiRunFinishedEvent` の発行)の本数と、
    /// 背景掃除を起こす本数が一致し、どれも**結果を書いた後**にある
    func testEveryPathThatWritesResultsStartsTheBackgroundSweepAfterwards() throws {
        var writes = 0
        var spawns = 0
        for path in Self.sources {
            let lines = try Self.codeLines(path)
            let writeIndices = lines.indices.filter {
                lines[$0].hasPrefix("try writeJUnitIfRequested(")
                    || lines[$0].hasPrefix("emitLine(ApiRunFinishedEvent(")
            }
            let spawnIndices = lines.indices.filter { lines[$0].contains("RunCompletionSweep.spawn(") }
            writes += writeIndices.count
            spawns += spawnIndices.count
            for (write, spawn) in zip(writeIndices, spawnIndices) {
                XCTAssertLessThan(write, spawn, "\(path): 掃除が結果を書く前に起きている")
            }
        }
        XCTAssertEqual(writes, 3, "結果を書く経路の本数が変わった —— 掃除の配線も見直すこと")
        XCTAssertEqual(spawns, writes, "結果を書く経路のどれかが背景の掃除を起こしていない")
    }

    /// **記録開始(テストより前)では掃除を起こさない**
    func testNothingSweepsBeforeTheTestsRun() throws {
        for path in Self.sources {
            let lines = try Self.codeLines(path)
            guard let begin = lines.firstIndex(where: { $0.contains("RunRecorder.begin(") }) else {
                return XCTFail("\(path): RunRecorder.begin が見つからない(走査の前提が崩れた)")
            }
            let firstSweep = lines.firstIndex { $0.contains("RunCompletionSweep.") || $0.contains("RetentionSweeper.clean(") }
            if let firstSweep {
                XCTAssertGreaterThan(firstSweep - begin, 20,
                                     "\(path): 記録開始の直後に掃除がある(テストの実行時間に乗る)")
            }
        }
    }

    /// 掃除には**この run の runID を渡す**(終わったばかりの自分の run を保護する)
    func testSpawnAlwaysReceivesTheActiveRunID() throws {
        for path in Self.sources {
            for line in try Self.codeLines(path) where line.contains("RunCompletionSweep.spawn(") {
                XCTAssertTrue(line.contains("activeRunID: recorder.runID"),
                              "\(path): activeRunID に recorder の runID を渡していない — \(line)")
            }
        }
    }

    /// 子の環境: `FT_PARENT_PID` を抜き、他の変数は引き継ぎ、**親が決めた2つの場所を固定する**
    func testChildEnvironmentDropsTheParentPIDAndPinsBothRoots() {
        let roots = RetentionSweeper.Roots(package: URL(fileURLWithPath: "/work/app"),
                                           tool: URL(fileURLWithPath: "/tools/foundation-tester"))
        let env = RunCompletionSweep.childEnvironment(
            roots: roots, base: ["FT_PARENT_PID": "123", "PATH": "/usr/bin",
                                 "DEVELOPER_DIR": "/Applications/X.app",
                                 "FT_PACKAGE_ROOT": "/stale", "FT_TOOL_ROOT": "/stale"])
        XCTAssertNil(env["FT_PARENT_PID"], "親の run と一緒に掃除が殺される")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["DEVELOPER_DIR"], "/Applications/X.app")
        // 受け手の外部構成では2つが別の場所。子に解決し直させると取り違える
        XCTAssertEqual(env["FT_PACKAGE_ROOT"], "/work/app", "掃除がプロジェクトの場所を取り違える")
        XCTAssertEqual(env["FT_TOOL_ROOT"], "/tools/foundation-tester")
    }

    /// 子の作業フォルダはプロジェクトの場所(ツールの場所ではない)
    func testSpawnRunsTheChildInThePackageRoot() throws {
        let text = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/fleetest/RunCompletionSweep.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("process.currentDirectoryURL = roots.package"),
                      "背景の掃除をツールの場所で起こしている —— 受け手のプロジェクトを見ない")
    }

    /// 子の標準入出力を3本とも /dev/null にしている(継がせると拡張・ssh が掃除の終わりまで待つ)
    func testSpawnDetachesAllThreeStandardStreams() throws {
        let text = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/fleetest/RunCompletionSweep.swift"), encoding: .utf8)
        for stream in ["standardInput", "standardOutput", "standardError"] {
            XCTAssertTrue(text.contains("process.\(stream) = FileHandle.nullDevice"),
                          "\(stream) を /dev/null にしていない —— run の終わりが掃除の終わりまで延びる")
        }
    }

    /// コメント行を除き、前後の空白を落としたソース行
    private static func codeLines(_ path: String) throws -> [String] {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") ? "" : trimmed
        }
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
