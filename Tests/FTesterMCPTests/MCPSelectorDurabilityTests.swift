// セレクタの**耐久性の格付け**(2026-08-10)。
//
// 「書ける」と「壊れにくい」は別物。`#id` と一意ラベルは木が変わっても指し続けるが、
// `#container >> .type[n]` の `[n]` は**同じ型の兄弟が1つ増減しただけで別要素を指す**。
// 同じ一覧に無印で混ぜると生成器は先頭を採るだけなので、印と但し書きで差を出す。
//
// 検知の類なので**両方向**を固定する: 添字付きに印が付くこと / 安定側に印が付かないこと。

import XCTest
import FTCore
import FTDSL
@testable import ftester_mcp

final class MCPSelectorDurabilityTests: XCTestCase {

    private func fixtureNames() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    private func fixture(_ name: String) throws -> SnapshotResponse {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots/\(name).json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    // MARK: - 印と但し書きの対応

    func testMarkAndCautionOnlyOnIndexed() {
        XCTAssertEqual(MCPServer.Durability.indexed.mark, "~")
        XCTAssertTrue(MCPServer.Durability.indexed.caution.contains("index-based"))
        // **安定側は無印**: 印が付くのは注意が要るものだけ、が読みやすい
        XCTAssertEqual(MCPServer.Durability.stable.mark, "")
        XCTAssertEqual(MCPServer.Durability.stable.caution, "")
        XCTAssertNotNil(MCPServer.indexedSelectorNote(.indexed))
        XCTAssertNil(MCPServer.indexedSelectorNote(.stable))
    }

    // MARK: - 実アプリのコーパス全数

    /// スコープ記法から採った式は**綴りに `[n]` が出なくても** indexed であること。
    /// `#容器 >> .clickable` は「容器の中の最初の clickable」で、位置依存は消えていない ——
    /// 綴りで判定していた版はこの形だけを取りこぼして無印にしていた(2026-08-10)
    func testScopedSelectorStaysIndexedEvenWhenTheIndexIsNotSpelledOut() throws {
        var checkedFirstSibling = false
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                guard let graded = naming.graded(for: element, in: snapshot),
                      graded.selector.contains(">>") else { continue }
                XCTAssertEqual(graded.durability, .indexed,
                               "\(name): \(graded.selector) がスコープ記法なのに stable")
                if !graded.selector.contains("[") { checkedFirstSibling = true }
            }
        }
        XCTAssertTrue(checkedFirstSibling,
                      "添字の出ないスコープ記法がコーパスに1件も無く、この回帰を検証できていない")
    }

    /// **勧める形と、下書きに実際に書かれる形が一致する**こと。
    /// 判定は `ScenarioCodeGen` 本体(下書きが通るのと同じ経路)に通す —— 自前で往復させると、
    /// `asWritten` が恒等関数に退化しても素通しになる(2026-08-10 に自分で踏んだ)
    func testSuggestedSelectorIsExactlyWhatTheGeneratorWrites() throws {
        var checked = 0
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                guard let graded = naming.graded(for: element, in: snapshot) else { continue }
                var step = FlowStep(action: "tap")
                step.locator = FTSelector.parse(graded.selector).primary
                let code = ScenarioCodeGen.render(
                    flow: Flow(name: "t", app: "a", platform: "ios", goal: nil,
                               generatedBy: "test", steps: [step]),
                    className: "T", generatedBy: "test", emptyExpectation: true)
                XCTAssertTrue(code.contains("tap(\"\(graded.selector)\")"),
                              "\(name): 勧めた \(graded.selector) が下書きに"
                                + "そのまま書かれない\n\(code)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// コーパスに両方の格付けが出ていること(片側しか見ていない状態を防ぐ)
    func testCorpusExercisesBothGrades() throws {
        var stable = 0, indexed = 0
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let naming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                guard let graded = naming.graded(for: element, in: snapshot) else { continue }
                if graded.durability == .indexed { indexed += 1 } else { stable += 1 }
            }
        }
        XCTAssertGreaterThan(stable, 0)
        XCTAssertGreaterThan(indexed, 0, "添字付きが1件も出ないコーパスでは印の検証にならない")
    }

    /// 曖昧ラベル注記の凡例が印を説明していること(印だけ出て意味が書いていない状態を防ぐ)
    func testAmbiguousNoteExplainsTheMark() throws {
        for name in try fixtureNames() {
            let note = MCPServer.ambiguousLabelsNote(try fixture(name))
            guard !note.isEmpty else { continue }
            XCTAssertTrue(note.contains("\"~\""), "\(name): 凡例に ~ の説明が無い")
            return
        }
        XCTFail("曖昧ラベル注記が1枚も出ないコーパスでは凡例を検証できない")
    }
}
