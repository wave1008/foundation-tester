// run 完了時の掃除の配線を等号で固定する。
//
// **型では守れない継ぎ目**: 掃除を呼び忘れても run は緑のまま通り、容量が黙って増え続ける
// (気づくのはディスクが埋まったとき)。結果を書く経路は3つあり、**書く経路すべてが掃除も
// 呼ぶ**という対応だけが不変条件なので、ソース走査で本数を固定する。
//
// 走査対象を増やすときは `OCRWarmupWiringTests` と同じ規律 —— 型で守れる区間には置かない。

import XCTest

final class RunCompletionSweepWiringTests: XCTestCase {

    /// 結果を書く経路(`writeJUnitIfRequested` / `ApiRunFinishedEvent` の発行)の本数と、
    /// `RunCompletionSweep.run` の呼び出し本数が一致していること
    func testEveryPathThatWritesResultsAlsoSweeps() throws {
        let sources = ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"]
        var writes = 0
        var sweeps = 0
        for path in sources {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(path),
                                  encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                if trimmed.hasPrefix("try writeJUnitIfRequested(")
                    || trimmed.hasPrefix("emitLine(ApiRunFinishedEvent(") { writes += 1 }
                if trimmed.hasPrefix("RunCompletionSweep.run(") { sweeps += 1 }
            }
        }
        XCTAssertEqual(writes, 3, "結果を書く経路の本数が変わった —— 掃除の配線も見直すこと")
        XCTAssertEqual(sweeps, writes,
                       "結果を書く経路のどれかが RunCompletionSweep.run を呼んでいない"
                       + "(その経路の成果物だけ溜まり続ける)")
    }

    /// 掃除は**この run の runID を渡す**。渡し忘れると今回の成果物が保護されず、
    /// 書いた直後の録画・レポートが消え得る
    func testSweepAlwaysReceivesTheActiveRunID() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(path),
                                  encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("RunCompletionSweep.run(") {
                XCTAssertTrue(line.contains("activeRunID: recorder"),
                              "\(path): activeRunID に recorder の runID を渡していない — \(line)")
            }
        }
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
