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
        // 受け手の導入は ID を渡さないので、写しは仮 ID(= @Draft 付き)の形にする。@Draft の行もコンパイルさせるため
        let scaffolded = ProjectScaffold.demoScenario(app: "com.example.myapp") + "\n"
        XCTAssertEqual(compiled, scaffolded,
                       "雛形が変わった。ScaffoldDemoScenarioFixture.swift の区切り行より下をこれに貼り替える:\n"
                       + scaffolded)
    }

    /// 実 ID を渡した雛形は一括実行に載る(@Draft を付けない)。仮 ID のときだけ外す
    func testDemoIsDraftOnlyWhileAppIDIsThePlaceholder() {
        XCTAssertTrue(ProjectScaffold.demoScenario(app: "com.example.myapp").contains("\n@Draft("))
        XCTAssertFalse(ProjectScaffold.demoScenario(app: "com.sutec.mobile").contains("@Draft"))
    }
}
