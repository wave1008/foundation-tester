// ref の世代管理。
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
@testable import fleetest_mcp

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
        // **"done." と注記の間に区切りがあること**: staleNote が裸の "note:" で
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

    // MARK: - 機を跨いだ ref の衝突(2026-08-13・軸②「2台以上」の監査で実機再現)

    /// **本命**: 2台を触ったセッションで、機A の ref を機B へ撃っても当たらないこと。
    ///
    /// base を engineKey ごとに 0 から始めていたため、**両機の ref 番号が衝突**していた。
    /// 実機実測(E2EAppCMP・iOS 2台): 機A の ref 10 は `#row_30`、機B の ref 10 は
    /// `#btn_item_1`。機A の木を見て採った `ft_tap ref: 10` を port だけ機B にして撃つと、
    /// **警告も拒否も無く成功して**機B のボタンを叩き、状態が変わった
    /// (`result=item3` → `result=item1`)。どちらも button なので**もっともらしく成功する**。
    /// 採番をセッション共通にすると、他機の ref は世代のどこにも無いので `.gone` で断られる
    func testARefTakenOnOneDeviceDoesNotHitAnotherDevice() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "row_30", label: "行 30")])
        let a = Self.text(try await server.call(tool: "ft_snapshot", args: ["port": 8123]))
        let refA = Self.firstRef(in: a)

        driver.snapshotResponse = screen([element(ref: 1, id: "btn_item_1", label: "項目")])
        let b = Self.text(try await server.call(tool: "ft_snapshot", args: ["port": 8124]))
        let refB = Self.firstRef(in: b)

        XCTAssertNotEqual(refA, refB,
                          "2台で同じ ref 番号が振られている — 片方の木を見て採った ref が"
                          + "もう片方の別要素へ黙って当たる(実機で再現済み)")

        // 機A の ref を機B へ撃つ: 当たってはいけない
        do {
            _ = try await server.call(tool: "ft_tap", args: ["port": 8124, "ref": refA])
            XCTFail("機A の ref \(refA) が機B で解決されて成功した(黙って別要素を叩いている)")
        } catch {
            XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap") },
                           "拒否したはずなのに tap が発射されている: \(driver.calls)")
        }
    }

    /// **上のテストが見ていなかった形**(2026-08-14・実機+仮想デバイス混在の監査で実機再現)。
    /// あちらは2台目も MCP で撮っているので「この engineKey に世代がある」が成り立ち、
    /// 素通しの分岐に入らなかった。**撮っていない宛先へ撃つ**とその分岐に落ちて、
    /// MCP の番号がそのままブリッジへ渡り、ブリッジ自前の 1..N で解決されて別要素に当たる。
    ///
    /// 実機実測(E2E-iOS・iPhone wave): profile: で撮った木の ref は 70..93 なのに、
    /// 同じ機を `port:8143 ref:10` で撃つと `tap [10] done`(警告ゼロ)で
    /// ブリッジの #10 = `#btn_input_submit` を実際に押し、`submitted=-` → `submitted=physical`
    /// になった。**engineKey は指し方込み**(`profile:…` / `direct:ios:<port>:`)なので、
    /// 同じ1台でも指し方を変えるだけでこの穴に入る
    func testARefIsNotForwardedRawToATargetThatWasNeverSnapshotted() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "row_30", label: "行 30")])
        let taken = Self.text(try await server.call(tool: "ft_snapshot", args: ["port": 8123]))
        let ref = Self.firstRef(in: taken)

        // 撃つ先(port 8124)では一度も ft_snapshot を撮っていない
        do {
            _ = try await server.call(tool: "ft_tap", args: ["port": 8124, "ref": ref])
            XCTFail("撮っていない宛先へ ref \(ref) が素通しされた(ブリッジ自前の番号で解決される)")
        } catch {
            XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap") },
                           "拒否したはずなのに tap が発射されている: \(driver.calls)")
            XCTAssertTrue(error.localizedDescription.contains("different target"),
                          error.localizedDescription)
        }
    }

    /// 出自を名指しすること —— 「不明な番号」とだけ言うと、呼び手は撃ち間違いだと読んで
    /// 同じ番号を別の宛先へ撃ち直す(拒否が助言になっていない)
    func testTheRefusalNamesBothTheTargetItWasTakenUnderAndTheOneItWasFiredAt() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "btn_ok", label: "OK")])
        let taken = Self.text(try await server.call(
            tool: "ft_snapshot", args: ["project": "E2E-iOS", "profile": "ios-device"]))
        let ref = Self.firstRef(in: taken)
        do {
            _ = try await server.call(tool: "ft_tap", args: ["port": 8143, "ref": ref])
            XCTFail("同じ機でも指し方が違えば ref は通してはいけない")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("ios-device"), message)
            XCTAssertTrue(message.contains("8143"), message)
        }
    }

    /// 陰性対照: **セッションが ref を1つも発行していない**ときの素通しは残す
    /// (ft_snapshot を挟まずに撃つ呼び方。判断の起点が無いのでブリッジの 404 に任せる)。
    /// 上の2本が「常に拒否する検出器」になっていないことをここで確かめる
    func testPassThroughSurvivesOnlyWhileTheSessionHasIssuedNoRefs() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["port": 8124, "ref": 42])
        XCTAssertEqual(actions, ["tap(ref:42)"])
    }

    /// 採番はセッションに1つ(機を跨いでも単調増加)。上のテストが「たまたま番号がずれた」で
    /// 通ることを防ぐ —— 2台目の base が1台目の消費ぶんだけ進んでいることを直接見る
    func testRefBaseIsSharedAcrossDevicesAndOnlyGrows() async throws {
        driver.snapshotResponse = screen([element(ref: 1), element(ref: 2)])
        _ = try await server.call(tool: "ft_snapshot", args: ["port": 8123])
        let afterA = server.nextRefBase
        XCTAssertGreaterThan(afterA, 0)

        _ = try await server.call(tool: "ft_snapshot", args: ["port": 8124])
        XCTAssertGreaterThan(server.nextRefBase, afterA,
                             "2台目が1台目と同じ base を使い回している")
    }

    /// 一覧の1行目の ref を抜く(`[12] button …` の 12)
    private static func firstRef(in text: String) -> Int {
        for line in text.split(separator: "\n") where line.hasPrefix("[") {
            if let close = line.firstIndex(of: "]"),
               let value = Int(line[line.index(after: line.startIndex)..<close]) {
                return value
            }
        }
        return -1
    }
}
