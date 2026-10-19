// afterAll(run × クラスで1回の片付け)の呼び出し口の配線。tearDownDevice を片付ける経路は、run の最後に
// afterAll も片付けなければならない。**呼び忘れは型でもテストでも止まらない**(その経路の run では afterAll が
// 黙って走らないだけで、どのシナリオも緑のまま)ので、ソースを走査して経路ごとに数を揃える

import XCTest

final class AfterAllWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testEveryPathThatTearsDownDevicesAlsoRunsAfterAll() throws {
        let paths = ["Sources/FTCore/RunOrchestrator.swift", "Sources/fleetest/Fleetest.swift",
                     "Sources/fleetest/ApiRunCommand.swift", "Sources/fleetest-mcp/MCPServer+ScenarioTools.swift"]
        for path in paths {
            let text = try source(path)
            let tearDowns = count("ScenarioHost.runDeviceTearDowns(", in: text)
            XCTAssertGreaterThan(tearDowns, 0, "\(path): 走査の対象が見つからない(名前が変わった?)")
            XCTAssertEqual(count("ScenarioHost.runAfterAlls(", in: text), tearDowns,
                           "\(path): tearDownDevice を片付ける経路で afterAll を呼んでいない")
        }
    }
}
