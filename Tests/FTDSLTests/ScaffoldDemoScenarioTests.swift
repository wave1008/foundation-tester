// `fleetest init` / `project create` が受け手に置くデモシナリオ(ProjectScaffold.demoScenario)は
// 文字列なので、DSL を改名しても型検査が効かない(`screenshot(filename:)` の廃止が雛形にだけ残り、
// 新しい受け手の最初のビルドが必ず落ちていた)。同じ中身を ScaffoldDemoScenarioFixture.swift として
// このテストターゲットに置いてコンパイルさせ、ここで両者の一致を固定する。

import XCTest
@testable import FTCore

final class ScaffoldDemoScenarioTests: XCTestCase {

    func testCompiledFixtureIsExactlyTheScaffoldedDemo() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ScaffoldDemoScenarioFixture.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let marker = "// ---- ここから雛形の出力 ----\n"
        let range = try XCTUnwrap(source.range(of: marker), "区切り行が無い")
        let compiled = String(source[range.upperBound...])
        // 複数行リテラルは最後の行の改行を含まない。コピーのファイルは改行で終わるので1文字足して比べる
        let scaffolded = ProjectScaffold.demoScenario(app: "com.example.scaffoldfixture") + "\n"
        XCTAssertEqual(compiled, scaffolded,
                       "雛形が変わった。ScaffoldDemoScenarioFixture.swift の区切り行より下をこれに貼り替える:\n"
                       + scaffolded)
    }
}
