// 消去・置換の読み返しの2つの契約:
// ①空になった入力欄は「読めない」ではなく「空」と読む(Android の空の EditText は `value` 属性
//   そのものを省き、iOS も空欄は空文字ではなく nil を返す)
// ②`ft_clear_input` の文言は「replace requested」と言わない。判定(`replaceVerificationNote`)は
//   共有してよいが、文言は呼び手ごとに持つ(CLAUDE.md)

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPEmptyFieldClearWordingTests: XCTestCase {

    private func field(value: String?) -> ElementInfo {
        ElementInfo(ref: 1, type: "textField", identifier: "search_box", label: nil,
                    value: value, placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
    }

    private func tree(_ element: ElementInfo) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: [element], truncatedCount: 0)
    }

    // MARK: - ① nil value(空欄)は「読めない」ではなく「空」と読む

    /// **本命**: 消去/置換後、値が nil(= 空を表す)なら成功として読む(既定の呼び手 = replace)
    func testNilValueAfterAClearOnlyRequestReadsAsCleared() {
        let empty = field(value: nil)
        let note = MCPServer.replaceVerificationNote(
            target: empty, expected: "", fresh: tree(empty))
        XCTAssertEqual(note, " (cleared the field)", note)
        XCTAssertFalse(note.contains("could not be read back"), note)
    }

    /// **陰性対照**: 非空を期待する置換で値が nil なら、従来どおり「読めない」のまま
    /// (本当に読めないケースまで「空」と誤読しない)
    func testNilValueAfterARealReplaceRequestStillReadsAsUnreadable() {
        let empty = field(value: nil)
        let note = MCPServer.replaceVerificationNote(
            target: empty, expected: "hello", fresh: tree(empty))
        XCTAssertTrue(note.contains("could not be read back"), note)
    }

    /// **入力欄でない要素(容器の ref を受け付けた回)の nil は「空」と読まない** —— そもそも値を出さない
    /// 要素なので、消えた証拠にならない
    func testNilValueOnANonInputElementIsNotReadAsCleared() {
        let container = ElementInfo(ref: 1, type: "other", identifier: "search_container", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
        let note = MCPServer.replaceVerificationNote(
            target: container, expected: "", fresh: tree(container), requestedAs: "clear")
        XCTAssertFalse(note.contains("cleared the field"), note)
        XCTAssertTrue(note.contains("could not be read back"), note)
    }

    /// 従来の「空文字」の空も同じく成功のまま(退行させない)
    func testEmptyStringValueAfterAClearOnlyRequestStillReadsAsCleared() {
        let empty = field(value: "")
        let note = MCPServer.replaceVerificationNote(
            target: empty, expected: "", fresh: tree(empty))
        XCTAssertEqual(note, " (cleared the field)", note)
    }

    // MARK: - ② 文言は呼び手ごと(ft_clear_input は「replace」を名乗らない)

    func testClearInputCallerNamesItselfClearNotReplace() {
        let empty = field(value: nil)
        let note = MCPServer.replaceVerificationNote(
            target: empty, expected: "", fresh: nil, requestedAs: "clear")
        XCTAssertTrue(note.contains("clear requested"), note)
        XCTAssertFalse(note.contains("replace requested"), note)
    }

    /// 既定(呼び手を渡さない = ft_type の replace 経路)は従来どおり "replace"
    func testDefaultCallerStillNamesItselfReplace() {
        let note = MCPServer.replaceVerificationNote(target: nil, expected: "hello", fresh: nil)
        XCTAssertTrue(note.contains("replace requested"), note)
    }

    /// **配線**: ft_clear_input の呼び出し口が `requestedAs: "clear"` を渡していること
    /// (渡し忘れると既定の "replace" のまま文言が事実と食い違う)
    func testClearInputCallSiteIsWiredWithTheClearVerb() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Dispatch.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("target: clearTarget, expected: \"\",")
                      && code.contains("requestedAs: \"clear\")"),
            "ft_clear_input が replaceVerificationNote へ requestedAs: \"clear\" を渡していない")
    }

    // MARK: - 配線: ft_clear_input を実際に呼んで応答を確かめる

    func testClearInputOnAnEmptyFieldReportsClearedNotUnreadable() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        // 空の EditText は value 属性そのものを省く(Android)/ iOS も空欄は nil を返す
        driver.snapshotResponse = tree(field(value: nil))
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        let result = try await server.call(tool: "ft_clear_input", args: ["ref": 1])
        let text = result.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("cleared the field"), text)
        XCTAssertFalse(text.contains("could not be read back"), text)
        XCTAssertFalse(text.contains("replace requested"), text)
    }
}
