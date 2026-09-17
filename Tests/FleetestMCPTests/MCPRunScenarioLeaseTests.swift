// ft_run_scenario は ScenarioHost.run(実デバイス)を直接呼ぶだけで MCPDeviceLease を書いておらず、
// 並行する `fleetest run` がこの台を避けられず、他の MCP セッションへも警告が出なかった(台帳 §19.3)。
// デバイス/ビルドが要る実行なので単体テストでは撃てず、配線をソース走査で固定する
// (MCPRotateSettleTests.testRestoreCallIsGatedToAndroidInSource と同じ手法)。

import XCTest

final class MCPRunScenarioLeaseTests: XCTestCase {
    private func sourceCode() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+ScenarioTools.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 関数本体を切り出す(次の `func` 宣言、無ければファイル末尾まで)
    private func functionBody(_ name: String, in code: String) throws -> String {
        guard let start = code.range(of: "func \(name)(") else {
            XCTFail("\(name) が見つからない")
            return ""
        }
        let rest = code[start.upperBound...]
        // 次の宣言(`static func` も含む)の手前まで。無ければファイル末尾まで
        let boundaries = ["\n    func ", "\n    static func "].compactMap { rest.range(of: $0)?.lowerBound }
        let end = boundaries.min() ?? rest.endIndex
        return String(rest[..<end])
    }

    /// 実行経路(profile 解決/直指定の両分岐が収束した後)は、実デバイスを渡す
    /// ScenarioHost.run より前に MCPDeviceLease の印を書く
    func testRunScenarioWritesLeaseBeforeTheRealRun() throws {
        let body = try functionBody("runScenario", in: try sourceCode())
        guard let leaseRange = body.range(of: "MCPDeviceLease.writeAndWarnIfInUse") else {
            XCTFail("runScenario が MCPDeviceLease.writeAndWarnIfInUse を呼んでいない")
            return
        }
        guard let runRange = body.range(of: "await ScenarioHost.run(project: project, scenarioID: info.id,") else {
            XCTFail("runScenario の実行呼び出しが見つからない(シグネチャが変わった?)")
            return
        }
        XCTAssertTrue(leaseRange.upperBound < runRange.lowerBound,
                      "MCPDeviceLease の書き込みは実デバイスへ触る ScenarioHost.run より前であること")
        // 鍵は driver(args) 経由の記憶(udids[]/connectedAndroidSerials[])に頼らず、
        // この経路が自分で組んだ `connection` の udid/serial から直接取ること
        XCTAssertTrue(body.contains("connection.udid ?? connection.serial"),
                      "鍵は resolveProfileTarget/直指定で得た connection から取ること"
                      + "(udids[]/connectedAndroidSerials[] はこの経路では埋まらない)")
    }

    /// dry-run(NullDriver。ロケータ構文だけを確かめ実機に触れない)は台の印を書かない
    func testDryRunDoesNotWriteALease() throws {
        let body = try functionBody("dryRun", in: try sourceCode())
        XCTAssertFalse(body.contains("MCPDeviceLease"),
                       "dry-run は実機を掴まないので MCPDeviceLease を書いてはいけない")
    }
}
