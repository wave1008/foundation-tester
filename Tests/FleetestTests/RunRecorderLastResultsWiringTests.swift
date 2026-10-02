// RunRecorder.begin の本番の呼び手(run / api run)が `lastResultsDir:` を渡していることの固定。
// 既定の nil は「書かない」なので、渡し忘れても run は緑のまま通り、始まらなかったシナリオが
// `--failed` から黙って落ちる(型では守れない継ぎ目)。

import XCTest

final class RunRecorderLastResultsWiringTests: XCTestCase {

    private static let sources = ["Sources/fleetest/Fleetest.swift",
                                  "Sources/fleetest/ApiRunCommand.swift"]

    func testProductionCallersPassTheLastResultsDirectory() throws {
        for path in Self.sources {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let begins = lines.indices.filter {
                lines[$0].contains("RunRecorder.begin(") && !lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            XCTAssertEqual(begins.count, 1, "\(path): RunRecorder.begin の本数が変わった —— 配線を見直すこと")
            for index in begins {
                let call = lines[index...(index + 4)].joined(separator: "\n")
                XCTAssertTrue(call.contains("lastResultsDir: LastResultsStore.stateDir("),
                              "\(path): lastResultsDir を渡していない — \(call)")
            }
        }
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
