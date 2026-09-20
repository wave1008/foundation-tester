// run 進捗(docs/design.md §18)の記帳の注入をソース走査で固定する。
//
// **型では守れない継ぎ目**: `writeRunProgress`/`removeRunProgress` を RunOrchestrator へ渡し
// 忘れても run は緑のまま通り、その経路(`fleetest run --profile` または `fleetest api run`)は
// 台帳を1バイトも書かない = モニターのフリート横断ボードにその run が永久に映らない。
// `fleetest run` と `fleetest api run` は実装を別々に持つ2実装(CLAUDE.md)なので両方を見る
// (ParentDeathWatchWiringTests / SupplyLeaseHandOffWiringTests と同型)。

import XCTest

final class RunProgressLedgerWiringTests: XCTestCase {

    private static let sources = ["Sources/fleetest/ProfileRunner.swift",
                                  "Sources/fleetest/ApiRunCommand.swift"]

    private static func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 2経路とも RunOrchestrator へ writeRunProgress/removeRunProgress を注入し、
    /// 実体(RunProgressLedger.write/remove)を呼んでいること
    func testBothRunOrchestratorCallSitesWireRunProgress() throws {
        for path in Self.sources {
            let text = try Self.code(path)
            XCTAssertTrue(text.contains("writeRunProgress: { record in"),
                          "\(path): writeRunProgress を注入していない(この経路の run が" +
                          " フリート横断ボードに出ない)")
            XCTAssertTrue(text.contains("removeRunProgress: {"),
                          "\(path): removeRunProgress を注入していない(run 終了後も台帳が残る)")
            XCTAssertTrue(text.contains("RunProgressLedger.write("),
                          "\(path): writeRunProgress が RunProgressLedger.write を呼んでいない")
            XCTAssertTrue(text.contains("RunProgressLedger.remove("),
                          "\(path): removeRunProgress が RunProgressLedger.remove を呼んでいない")
            XCTAssertTrue(text.contains("RunProgressLedger.sweep("),
                          "\(path): run の開始時に sweep を呼んでいない(SIGKILL で残った控えが" +
                          " 溜まり続け、api monitor が毎周期そのぶんを読む)")
            XCTAssertTrue(text.contains("profile: resolved.runName") || text.contains("profile: profileName"),
                          "\(path): RunOrchestrator へプロファイル名を渡していない" +
                          " (RunProgressRecord.profile が常に nil になる)")
        }
    }
}
