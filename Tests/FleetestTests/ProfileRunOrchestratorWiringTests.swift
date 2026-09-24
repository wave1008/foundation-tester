// `fleetest run --profile` と `fleetest api run` が RunOrchestrator の配線を ProfileRunOrchestrator の
// 1箇所から受けることを固定する。**型では守れない継ぎ目**: どちらかが RunOrchestrator を直に組み直すと、
// 配線を見る走査(RunProgressLedgerWiringTests / SupplyLeaseHandOffWiringTests / RunnerMidRunRecheckTests)は
// 共有ファイルだけを見て緑のまま、その経路だけ lease・進捗・再確認が抜ける。

import XCTest

final class ProfileRunOrchestratorWiringTests: XCTestCase {

    private static let callers = ["Sources/fleetest/ProfileRunner.swift",
                                  "Sources/fleetest/ApiRunCommand.swift"]

    private static func codeWithoutComments(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testBothRunPathsBuildTheOrchestratorThroughTheSharedWiring() throws {
        for path in Self.callers {
            let text = try Self.codeWithoutComments(path)
            XCTAssertEqual(count("ProfileRunOrchestrator.make(", in: text), 1, path)
            XCTAssertEqual(count("RunOrchestrator(", in: text), 0,
                           "\(path) が RunOrchestrator を直に組んでいる(共有の配線を迂回する)")
            XCTAssertEqual(count("ProfileRunOrchestrator.writePreparingProgress(", in: text), 1,
                           "\(path) が供給の前に段階「準備中」を書いていない")
        }
    }
}
