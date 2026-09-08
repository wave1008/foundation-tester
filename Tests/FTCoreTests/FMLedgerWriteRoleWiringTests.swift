// FMLedgerWriteRole の opt-in 配線をソース走査で固定する。
//
// **書くのは opt-in した production の入口だけ**(FMLedgerWriteRole.swift 冒頭)。この集合を
// 等号で固定するのは、FM を実呼び出しする新しい実行ファイルを足したときに「opt-in を
// 呼び忘れて台帳が永久に『不明』のまま」を検出するため(逆に、呼ばなくてよい実行ファイルへ
// 足しても実害は無いので、増える分にはこのテストは反応しない —— 減った/入れ忘れた側だけを見る)。

import XCTest
@testable import FTCore

final class FMLedgerWriteRoleWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// FM を実呼び出しする3つの実行ファイル(fleetest CLI・fleetest-scenarios-* の共通実装・
    /// fleetest-mcp)の起動時 opt-in。三者とも FTFoundationModels に依存しており、
    /// FMHealth.record の呼び出し元(OcclusionVerifier/ReplayAssist/FMLoadGenerator)と
    /// FMLivenessProbe.refresh の呼び出し元(ApiHostMetricsCommand/ProfileRunner/
    /// MCPServer+Hints)を実際に通すのはこの3実行ファイルだけなので、この3箇所で十分
    /// (Package.swift の dependencies 参照)
    func testEveryFMCallingEntryPointOptsIn() throws {
        let entryPoints = [
            "Sources/fleetest/Fleetest.swift",
            "Sources/FTScenarioRunner/ScenarioRunnerMain.swift",
            "Sources/fleetest-mcp/MCPServer.swift",
        ]
        for path in entryPoints {
            let text = try source(path)
            XCTAssertTrue(text.contains("FMLedgerWriteRole.enableForProduction()"),
                          "\(path) が起動時に FMLedgerWriteRole.enableForProduction() を呼んでいない" +
                          "(この実行ファイルからの FM 呼び出しが台帳へ届かない)")
        }
    }
}
