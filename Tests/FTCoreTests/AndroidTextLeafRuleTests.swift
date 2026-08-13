// Android ブリッジの「型が付かない葉テキスト」の救済規則(`SnapshotBuilder.mappedType` の
// default 分岐)を、**text と contentDesc の両方**を見ることに固定する。
//
// **なぜ守る必要があるか**(2026-08-13 に実機で発見した実バグ):
// className が役割を語らないノードのうち、この分岐で `StaticText` にならなかったものは
// `Other` になり、`shouldInclude` の default が **resource-id を要求する**ので木から消える。
// Flutter は文字を contentDesc に入れるが、**Chromium(WebView)は `getText()` に入れる**ため、
// contentDesc しか見ていなかった間は WebView 内の `<td>` が1つも出ていなかった。
// しかも `<table>` 自身は GridView + id で残るので `webViewGapNote` の空白帯にもならず、
// **黙って消える**(WebView 124 と 150 の両方で再現。版の問題ではなくこちらの取りこぼし)。
//
// Java はここから実行できないので、規則の形だけをソース走査で見る(既存の
// `SnapshotElementLimitTests.testJavaMirrorDeclaresTheSameConstants` と同じ作法)。

import XCTest
@testable import FTCore

final class AndroidTextLeafRuleTests: XCTestCase {

    private func snapshotBuilderSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java"), encoding: .utf8)
    }

    /// 葉テキストの救済が **contentDesc だけ**に戻っていないこと。
    /// 条件式そのものを1つの塊として取り出して見る(離れた行の `node.text` を数えても、
    /// この分岐が text を見ている証拠にはならないため)
    func testTheLeafTextRuleConsultsBothTextAndContentDescription() throws {
        let source = try snapshotBuilderSource()
        // 条件式は `if (...)` の閉じ括弧まで。`return "StaticText"` に届く範囲だけを見る
        // **コメントを剥がしてから見る**(2026-08-13 のレビュー指摘)。分岐の内側に
        // 説明コメントを置くと、コメント中の `node.text` だけでアサートが通ってしまう
        let stripped = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
            .joined(separator: "\n")
        guard let range = stripped.range(of: "!node.hasChildren") else {
            return XCTFail("葉テキストの救済分岐が見つからない(コメント除去後)")
        }
        let tail = stripped[range.lowerBound...].prefix(400)
        guard let staticText = tail.range(of: "\"StaticText\"") else {
            return XCTFail("`!node.hasChildren` の分岐が StaticText を返していない")
        }
        let condition = tail[..<staticText.lowerBound]
        XCTAssertTrue(condition.contains("node.contentDesc"),
                      "contentDesc を見なくなると Flutter の文字が落ちる(2026-07-26 実測)")
        XCTAssertTrue(condition.contains("node.text"),
                      "text を見なくなると WebView 内の <td> が丸ごと落ちる(2026-08-13 実機で実害)")
    }

    /// 上の救済が効かなかったノードを捨てる側の網が、**resource-id を要求したまま**であること。
    /// ここが緩むと救済規則が形骸化し(何を落としても default が拾ってしまう)、
    /// 上のテストが壊れても症状が出なくなる
    func testTheDefaultFilterStillRequiresAResourceID() throws {
        let source = try snapshotBuilderSource()
        XCTAssertTrue(source.contains("return !node.resourceID.isEmpty();"),
                      "default 分岐が resource-id 要求でなくなったなら、"
                      + "葉テキストの救済規則の意味も変わる。両方まとめて見直すこと")
    }
}
