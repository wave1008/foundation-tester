// MCP(ft_*)は宣言されていない引数名を黙って無視していた —— 実地:
// `ft_status {"serial":"…","thisArgumentDoesNotExist":"surprise"}` が何も言わず成功していた。
// 打ち間違い(holdSecond/waitSecond/scrollframe)は黙って既定値で実行される。
// 方針は「まず警告から」(断らない): `MCPServer.unknownArgumentNote` が成功・失敗どちらの
// 応答にも1行の注記を乗せる。近い名前があれば "(did you mean ...)" を添える。

import XCTest
import FTCore
@testable import fleetest_mcp

final class UnknownArgumentNoteTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - 純粋関数(unknownArgumentNote)

    func testNoteIsEmptyWhenAllArgumentsAreDeclared() {
        XCTAssertEqual(MCPServer.unknownArgumentNote(tool: "ft_status", args: ["serial": "emulator-5554"]), "")
    }

    func testNoteNamesTheUnknownKeyAndListsWhatTheToolTakes() {
        let note = MCPServer.unknownArgumentNote(
            tool: "ft_status", args: ["serial": "emulator-5554", "thisArgumentDoesNotExist": "surprise"])
        XCTAssertTrue(note.contains("thisArgumentDoesNotExist"), note)
        XCTAssertTrue(note.contains("ft_status takes:"), note)
        XCTAssertTrue(note.contains("serial"), note)
        XCTAssertFalse(note.contains("surprise"), "値そのものは注記に要らない: \(note)")
    }

    /// `_` 始まりの鍵(MCP クライアントの `_meta` 相当)は対象外
    func testUnderscorePrefixedKeysAreExempt() {
        XCTAssertEqual(MCPServer.unknownArgumentNote(tool: "ft_status", args: ["_meta": ["x": 1]]), "")
    }

    /// 宛先を宣言していないツール(ft_doctor は device ターゲットを取らない)へ渡した宛先引数も
    /// 同じ注記になる(toolAcceptsDeviceTarget の挙動そのものは変えない —— ここは
    /// 「スキーマに無い鍵」として自然に同じ結果になるだけ)
    func testUndeclaredDeviceArgumentOnANonDeviceToolIsNoted() {
        let note = MCPServer.unknownArgumentNote(tool: "ft_doctor", args: ["udid": "ABCD-1234"])
        XCTAssertTrue(note.contains("udid"), note)
    }

    /// 大文字小文字だけ違う: waitSeconds を waitseconds と打った
    func testCaseInsensitiveTypoSuggestsTheDeclaredSpelling() {
        let note = MCPServer.unknownArgumentNote(tool: "ft_snapshot", args: ["waitfor": "#ok"])
        XCTAssertTrue(note.contains("did you mean \"waitFor\"?"), note)
    }

    /// 編集距離2以下: scrollFrame → scrollframe(大文字小文字だけでなく1文字も違わない ——
    /// 大文字小文字を落とせば一致するのでこれも case-insensitive 枝で拾われる。編集距離だけの
    /// 例として holdSeconds → holdSecond(末尾の1文字欠落、距離1)を使う
    func testEditDistanceTypoSuggestsTheClosestDeclaredName() {
        let note = MCPServer.unknownArgumentNote(tool: "ft_long_press", args: ["x": 1, "y": 1, "holdSecond": 2.0])
        XCTAssertTrue(note.contains("holdSecond"), note)
        XCTAssertTrue(note.contains("did you mean \"holdSeconds\"?"), note)
    }

    /// 遠すぎる名前には候補を付けない(誤った示唆をしない)
    func testUnrelatedNameGetsNoSuggestion() {
        let note = MCPServer.unknownArgumentNote(tool: "ft_status", args: ["completelyUnrelatedThing": 1])
        XCTAssertTrue(note.contains("completelyUnrelatedThing"), note)
        XCTAssertFalse(note.contains("did you mean"), note)
    }

    // MARK: - 実物の呼び口: 断らず、注記だけ付けて成功する

    func testCallSucceedsWithUnknownArgumentAndCarriesTheNote() async throws {
        let content = try await server.call(tool: "ft_status", args: ["thisArgumentDoesNotExist": "surprise"])
        let text = body(content)
        XCTAssertTrue(text.contains("⚠️ ignored unknown argument(s): thisArgumentDoesNotExist"), text)
    }

    /// 失敗した回にも注記が付く(call の catch 経路)。ft_logs は iOS で bundleId が決まらないと
    /// isError で断る既存の経路 —— そこに未知引数を混ぜても注記が消えないこと
    func testCallFailureStillCarriesTheUnknownArgumentNote() async {
        do {
            _ = try await server.call(tool: "ft_logs",
                                      args: ["platform": "ios", "thisArgumentDoesNotExist": "surprise"])
            XCTFail("bundleId 無しの iOS の ft_logs が成功扱いで返った")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("bundleId is required"), message)
            XCTAssertTrue(message.contains("thisArgumentDoesNotExist"), message)
        }
    }
}
