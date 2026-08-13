// `ft_type`(replace なし)の追記警告を「予告」から「観測」へ変えた回の回帰(2026-08-13)。
//
// witness: Google メッセージの「新しい会話」画面。宛先欄 `#ContactSearchField` は空のとき
// ヒント文字列を `value` に載せる(`isShowingHintText()` が false なのでブリッジは
// `placeholder` を出さない)。撃つ前 value="名前、電話番号、メールアドレスのいずれかを入力"、
// 撃った後 value="5551234567" —— 旧実装は連結を**予告**していたので、
// **同じ応答が返す木がその場で否定する**注記になっていた。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPTypeAppendVerificationTests: XCTestCase {

    private static let hint = "名前、電話番号、メールアドレスのいずれかを入力"

    private static func field(_ value: String, placeholder: String? = nil,
                              type: String = "TextField") -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: "ContactSearchField", label: nil,
                    value: value, placeholder: placeholder, enabled: true,
                    frame: FTRect(x: 60, y: 77, width: 285, height: 42), depth: 1, focused: true)
    }

    private static func screen(_ element: ElementInfo) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 360, height: 808),
                         elements: [element], truncatedCount: 0)
    }

    // MARK: - 純粋関数

    /// **witness**: 撃った文字だけが残っている = 撃つ前の値は実在の内容ではなかったので黙る
    func testAppendNoteIsSilentWhenOnlyTheTypedTextRemains() {
        let note = MCPServer.appendVerificationNote(
            target: Self.field(Self.hint), typed: "5551234567", prior: Self.hint,
            fresh: Self.screen(Self.field("5551234567")))
        XCTAssertEqual(note, "", "ヒントを実在の内容と誤認して警告している: \(note)")
    }

    /// **予告ではなく観測**: 読み返した値が素朴な連結と違っても、読み返したほうを名乗る
    func testAppendNoteQuotesTheValueItReadBackNotThePrediction() {
        let note = MCPServer.appendVerificationNote(
            target: Self.field("old"), typed: "new", prior: "old",
            fresh: Self.screen(Self.field("XXXnew")))
        XCTAssertTrue(note.contains("XXXnew"), note)
        XCTAssertFalse(note.contains("oldnew"), "読まずに連結を断定している: \(note)")
    }

    /// 素直に連結された形は今までどおり名指しする(陰性対照ではなく真陽性側)
    func testAppendNoteStillWarnsWhenTheFieldReallyHeldContent() {
        let note = MCPServer.appendVerificationNote(
            target: Self.field("old"), typed: "new", prior: "old",
            fresh: Self.screen(Self.field("oldnew")))
        XCTAssertTrue(note.contains("oldnew"), note)
        XCTAssertTrue(note.contains("ft_clear_input"), note)
    }

    /// 読み返せないときは断定しない(値を名乗らない)
    func testAppendNoteStaysNeutralWhenUnreadable() {
        let note = MCPServer.appendVerificationNote(
            target: Self.field("old"), typed: "new", prior: "old", fresh: nil)
        XCTAssertTrue(note.contains("could not be read back"), note)
        XCTAssertFalse(note.contains("oldnew"), "読めていないのに結果を断定している: \(note)")
    }

    /// 対象が木から消えていても断定しない
    func testAppendNoteStaysNeutralWhenTheFieldIsGone() {
        let gone = SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 360, height: 808),
                                    elements: [], truncatedCount: 0)
        let note = MCPServer.appendVerificationNote(
            target: Self.field("old"), typed: "new", prior: "old", fresh: gone)
        XCTAssertTrue(note.contains("could not be read back"), note)
        XCTAssertFalse(note.contains("oldnew"), note)
    }

    /// マスク欄は「違う」ではなく「確かめようがない」(replaceVerificationNote と同じ規約)
    func testAppendNoteDoesNotGuessThroughAMaskedField() {
        let note = MCPServer.appendVerificationNote(
            target: Self.field("old", type: "SecureTextField"), typed: "new", prior: "old",
            fresh: Self.screen(Self.field("••••••", type: "SecureTextField")))
        XCTAssertTrue(note.contains("could not be verified"), note)
        XCTAssertFalse(note.contains("••••••"), note)
    }

    // MARK: - dispatch(配線)

    /// **配線のテストを別に持つ**: 純粋関数だけを固定すると「呼び出しを外す」変異が生き残る
    func testTypeIsSilentWhenThePriorValueWasHintText() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.screen(Self.field(Self.hint))
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // verifiedRef の撮り直し(撃つ前)→ 読み返し(撃った後)
        driver.scriptedSnapshots = [
            Self.screen(Self.field(Self.hint)),
            Self.screen(Self.field("5551234567")),
        ]
        let content = try await server.call(
            tool: "ft_type", args: ["ref": 1, "text": "5551234567"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.contains("already held"), "ヒントを内容と誤認している: \(text)")
        XCTAssertFalse(text.contains(Self.hint), text)
    }

    /// 本当に値が入っていた欄では、読み返した値を名乗って警告する
    func testTypeQuotesTheValueItReadBack() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.screen(Self.field("old"))
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [
            Self.screen(Self.field("old")),
            Self.screen(Self.field("oldnew")),
        ]
        let content = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "new"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("already held"), text)
        XCTAssertTrue(text.contains("oldnew"), text)
    }

    /// **判定は DSL と同じ**: `value == placeholder` の空欄では読み返しにも行かず黙る
    /// (`TypeReadback.normalizedValue`。旧実装は素の `value` を見て MCP だけが警告していた)
    func testTypeDoesNotWarnWhenTheValueIsJustThePlaceholder() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.screen(Self.field("単一行", placeholder: "単一行"))
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [Self.screen(Self.field("単一行", placeholder: "単一行"))]
        let before = driver.calls.count
        let content = try await server.call(tool: "ft_type", args: ["ref": 1, "text": "abc"])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.contains("already held"), text)
        XCTAssertFalse(text.contains("could not be read back"), text)
        // 読み返しの往復も払わない(verifiedRef の1枚 + type だけ)
        let added = driver.calls[before...]
        XCTAssertEqual(added.filter { $0.hasPrefix("snapshot") }.count, 1,
                       "黙るべき形で読み返しを払っている: \(Array(added))")
    }

    // MARK: - ft_clear_input(同型の掃討)

    /// **無条件の「cleared」を断言しない**: 値が残っていたら警告になる
    func testClearInputWarnsWhenTheValueSurvives() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.screen(Self.field("old"))
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // verifiedRef の撮り直し(消す前)→ 読み返し(消えていない想定)
        driver.scriptedSnapshots = [Self.screen(Self.field("old")), Self.screen(Self.field("old"))]
        let content = try await server.call(tool: "ft_clear_input", args: ["ref": 1])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("still reads"), "残った値を黙って「cleared」と言っている: \(text)")
        XCTAssertTrue(text.contains("old"), text)
    }

    /// 本当に消えていれば今までどおり肯定する
    func testClearInputConfirmsWhenTheFieldIsEmpty() async throws {
        let driver = FakeDriver()
        driver.snapshotResponse = Self.screen(Self.field("old"))
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [Self.screen(Self.field("old")), Self.screen(Self.field(""))]
        let content = try await server.call(tool: "ft_clear_input", args: ["ref": 1])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("cleared the field"), text)
        XCTAssertFalse(text.contains("warning"), text)
    }
}
