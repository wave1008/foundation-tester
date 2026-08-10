// ref の世代管理(2026-08-10)。
//
// なぜ要るか(実害): ブリッジは snapshot を撮るたびに ref を振り直す。MCP は「1つ前の木」しか
// 起点にしない(RefGuard.relocate は lastSnapshots だけを見る)ので、それより前の snapshot の
// ref を撃たれると、たまたま同じ番号を持つ**新しい木の別要素**へ黙って当たる
// (実測: ft_scroll_to の後に旧 ref [42](戻るボタンのつもり)を叩いたら、新しい木の
// [42](静的テキスト「料金:」)に当たった)。
//
// 対策は MCP 層で ref にオフセット(base)を掛け、セッション内で全世代の ref を一意にすること。
// ここではその世代管理(adoptSnapshot/resolveSessionRef/nativeRef)を dispatch 経由で検証する。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPRefGenerationTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func element(ref: Int, type: String = "Button", id: String? = nil,
                         label: String? = nil, x: Double = 10, y: Double = 20,
                         w: Double = 100, h: Double = 40, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    private func screen(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: elements, truncatedCount: 0)
    }

    private var actions: [String] { driver.calls.filter { !$0.hasPrefix("isAppForeground") } }

    private static func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// 1. 同じ木を2回返すフェイクで ft_snapshot を2回 → ref が変わらない(世代が進まない)。
    /// **世代が1つの間は従来の ref と完全に一致する**(base 0)ことも合わせて確かめる
    func testSnapshotTwiceWithAnUnchangedTreeKeepsTheSameRef() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "btn_ok", label: "OK")])
        let first = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        let second = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        // SnapshotRenderer の行形式は `[ref] type "label" id=identifier (frame)`
        XCTAssertTrue(first.contains("[1] button \"OK\" id=btn_ok"), first)
        XCTAssertTrue(second.contains("[1] button \"OK\" id=btn_ok"),
                      "世代が進んで ref が変わってはいけない: \(second)")
    }

    /// 2. 1回目と2回目で要素構成が変わるフェイク → 2回目の ref は1回目と重ならない(全 ref 一意)。
    /// base は「これまでに使った native ref の最大値+1」から始まるので、1要素だけの1世代目の後は
    /// 2 から始まる(native max ref 1 → nextRefBase = 0 + 1 + 1 = 2)
    func testSnapshotWithAChangedTreeUsesNonOverlappingRefs() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "btn_a", label: "A")])
        let first = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        driver.snapshotResponse = screen([element(ref: 1, id: "btn_b", label: "B")])
        let second = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertTrue(first.contains("[1] button \"A\" id=btn_a"), first)
        XCTAssertTrue(second.contains("[3] button \"B\" id=btn_b"), second)
        XCTAssertFalse(second.contains("[1] button \"B\" id=btn_b"),
                       "旧世代の番号を再利用してはいけない: \(second)")
    }

    /// 3. 木が変わった後、**古い世代の ref** で ft_tap → 旧世代の同一性で引き直され、
    /// 応答に「older snapshot」の警告が載る。かつフェイクドライバが受け取る tap の ref は
    /// **ブリッジ native の正しい番号**(セッション ref をそのまま送ってはいけない)。
    ///
    /// 3世代作る(戻る → 確定 → 戻る)ことで、gen0 の session ref (1) が gen2 では別の base に
    /// 移っていること(番号としては再利用されない)を保証したうえで、なお識別子で引き直せることを見る
    func testTapWithAnOlderGenerationRefIsRelocatedAndWarns() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "btn_back", label: "戻る", x: 10, y: 20)])
        _ = try await server.call(tool: "ft_snapshot", args: [:]) // gen0: session ref 1 = btn_back

        driver.snapshotResponse = screen([element(ref: 1, id: "btn_confirm", label: "確定",
                                                   x: 200, y: 300)])
        _ = try await server.call(tool: "ft_snapshot", args: [:]) // gen1: 別要素、base が進む

        driver.snapshotResponse = screen([element(ref: 1, id: "btn_back", label: "戻る", x: 10, y: 20)])
        _ = try await server.call(tool: "ft_snapshot", args: [:]) // gen2: btn_back が新しい base で再登場

        // 世代1つ目(gen0)の session ref である「1」を撃つ。gen0 以外には「1」という session ref が
        // 存在しない(base が単調増加するため)ので、これは確実に古い世代からの参照になる
        let result = try await server.call(tool: "ft_tap", args: ["ref": 1])
        let text = Self.text(result)
        XCTAssertTrue(text.contains("older snapshot"), text)
        // **"done." と注記の間に区切りがあること**(2026-08-10): staleNote が裸の "note:" で
        // 始まると "done.note:" と密着し、末尾の余白は次の " (selector:" と二重空白になる
        XCTAssertTrue(text.contains("done. note:"), text)
        XCTAssertFalse(text.contains("done.note:"), text)
        XCTAssertFalse(text.contains("  ("), "二重空白: \(text)")
        XCTAssertTrue(text.contains("#btn_back"), text)
        XCTAssertTrue(actions.contains("tap(ref:1)"),
                      "ブリッジ native の正しい番号(1)で撃つこと(セッション ref を送ってはいけない): \(actions)")
    }

    /// 4. 最新世代の ref で ft_tap → 「older snapshot」警告は出ない
    func testTapWithTheLatestGenerationRefHasNoStaleWarning() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "btn_ok", label: "OK")])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("older snapshot"), text)
    }

    /// 5. どの世代にも無い ref で ft_tap(世代列はある)→ 「unknown ref」の throw。
    /// 世代が無いとき(ft_snapshot を1度も挟んでいないとき)は素通しする既存の不変条件と対比する
    func testTapWithARefFromNoGenerationThrowsUnknownRef() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "btn_ok", label: "OK")])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": 999])
            XCTFail("直近5世代のどれにも無い ref は throw するはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unknown ref"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("999"), error.localizedDescription)
        }
        XCTAssertFalse(actions.contains { $0.hasPrefix("tap") }, "撃ってはいけない")
    }

    /// 対比: 世代が1つも無ければ(ft_snapshot を挟んでいない)従来どおり素通しする
    /// (既存の不変条件。ここが壊れると上のテストと矛盾する動作になる)
    func testTapWithoutAnyPriorSnapshotStillPassesThrough() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["ref": 42])
        XCTAssertEqual(actions, ["tap(ref:42)"])
    }
}
