// エージェント向けの手引き(docs/user-docs/tools/agent_guide(_ja).md)の見本コードは文字列なので、
// DSL を改名しても型検査が効かない。同じ中身を AgentGuideExampleFixture.swift として
// このテストターゲットに置いてコンパイルさせ、ここで英日両方のページの見本との一致を固定する。

import XCTest

final class AgentGuideExampleTests: XCTestCase {

    func testCompiledFixtureIsExactlyTheGuideExampleInBothLanguages() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = try String(contentsOf: here.appendingPathComponent("AgentGuideExampleFixture.swift"),
                                 encoding: .utf8)
        let marker = "// ---- ここから手引きの見本 ----\n"
        let range = try XCTUnwrap(fixture.range(of: marker), "区切り行が無い")
        let compiled = String(fixture[range.upperBound...])
        let docs = here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/user-docs/tools")
        for page in ["agent_guide.md", "agent_guide_ja.md"] {
            let text = try String(contentsOf: docs.appendingPathComponent(page), encoding: .utf8)
            let open = try XCTUnwrap(text.range(of: "```swift\n"), "\(page) に swift の見本が無い")
            let rest = text[open.upperBound...]
            let close = try XCTUnwrap(rest.range(of: "```\n"), "\(page) の見本が閉じていない")
            XCTAssertEqual(String(rest[..<close.lowerBound]), compiled,
                           "\(page) の見本と AgentGuideExampleFixture.swift が食い違う(両方を同じにする)")
        }
    }
}
