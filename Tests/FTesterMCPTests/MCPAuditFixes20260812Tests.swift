// 2026-08-12 の実アプリ監査(赤羽→立川の乗換検索・Apple マップ / Google マップ)で出た
// 「注記が読みにくい」系の修正4件。いずれも**注記の量**を減らす変更なので、検知の類と同じく
// **両方向**を固定する —— 消すべきものが消えること / 残すべきものが残ること。
//
//   #3 曖昧ラベル一覧から記号だけのラベルを外す(Google マップの区切り `" · "` ×3)
//   #4 leftover/offscreen の注記は最外の行だけ名指す(Apple マップで 8 件中 7 件が子孫)
//   #5 マシンプロファイル未使用の見出しは2回目以降は理由を畳む
//   #6 ft_status の宛先に udid まで出す(ポートはセッション中に動く)

import XCTest
import FTBridgeClient
import FTCore
import FTDSL
@testable import ftester_mcp

final class MCPAuditFixes20260812Tests: XCTestCase {

    private func element(ref: Int, type: String, id: String? = nil, label: String? = nil,
                         frame: FTRect, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: depth)
    }

    private func snapshot(_ elements: [ElementInfo],
                          screen: FTRect = FTRect(x: 0, y: 0, width: 402, height: 874))
        -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                         elements: elements, truncatedCount: 0)
    }

    // MARK: - #3 記号だけのラベル

    /// 語(英数字・仮名・漢字・ハングル)を1文字でも含めば「書けるラベル」。
    /// **日本語を落とさないこと**が要 —— `isLetter` 系で組むと全角記号の扱いで揺れる
    func testSymbolOnlyLabelDetection() {
        for symbolOnly in [" · ", "·", "—", "→", "…", "／", "(", "  ", "•", "×"] {
            XCTAssertTrue(MCPServer.isSymbolOnlyLabel(symbolOnly), "\(symbolOnly) は記号だけのはず")
        }
        for word in ["715円", "赤羽駅", "OK", "2", "IC 運賃", "ハングル", "한글", "x"] {
            XCTAssertFalse(MCPServer.isSymbolOnlyLabel(word), "\(word) は語を含むはず")
        }
    }

    /// 実測の形(Google マップの経路詳細): 区切り `" · "` が3つ、運賃 `"715円"` が2つ。
    /// **区切りは消え、運賃は残る** —— 片方向だけ見ると「全部消す」変異を素通しする
    func testAmbiguousLabelsNoteDropsSeparatorsButKeepsWords() {
        let rows = (0..<3).map { i in
            element(ref: 10 + i, type: "staticText", label: " · ",
                    frame: FTRect(x: 100, y: Double(100 + i * 40), width: 20, height: 20), depth: 2)
        }
        let fares = (0..<2).map { i in
            element(ref: 20 + i, type: "staticText", label: "715円",
                    frame: FTRect(x: 200, y: Double(100 + i * 40), width: 40, height: 20), depth: 2)
        }
        let note = MCPServer.ambiguousLabelsNote(snapshot(rows + fares))
        XCTAssertTrue(note.contains("715円"), "語を持つ曖昧ラベルは残すこと: \(note)")
        XCTAssertFalse(note.contains(" · "), "記号だけのラベルは列挙しないこと: \(note)")
    }

    // MARK: - #4 最外の行だけ名指す

    /// 祖先と子孫がまとめて同じ印を持つとき、名指すのは最外の1行だけ。
    /// **落とした件数は黙らせない**(注記に出す)
    func testOutermostKeepsTheAncestorAndCountsDescendants() {
        let container = element(ref: 1, type: "other", id: "Row",
                                frame: FTRect(x: 0, y: 0, width: 400, height: 100), depth: 1)
        let children = (0..<3).map { i in
            element(ref: 2 + i, type: "staticText", id: "Label\(i)", label: "行\(i)",
                    frame: FTRect(x: 10, y: Double(10 + i * 20), width: 100, height: 18), depth: 2)
        }
        let unrelated = element(ref: 9, type: "button", id: "Other", label: "別",
                                frame: FTRect(x: 0, y: 300, width: 80, height: 40), depth: 1)
        let all = [container] + children + [unrelated]
        let (outer, dropped) = MCPServer.outermost(all, in: all)
        XCTAssertEqual(outer.map(\.ref), [1, 9], "最外の2行だけが残るはず")
        XCTAssertEqual(dropped, 3)
    }

    /// **子孫が印を持たない群では1件も落とさない**(「常に畳む」変異を落とす)
    func testOutermostDropsNothingWhenTheFlaggedRowsAreSiblings() {
        let siblings = (0..<3).map { i in
            element(ref: 1 + i, type: "button", id: "Btn\(i)", label: "B\(i)",
                    frame: FTRect(x: 0, y: Double(i * 50), width: 80, height: 40), depth: 1)
        }
        let (outer, dropped) = MCPServer.outermost(siblings, in: siblings)
        XCTAssertEqual(outer.count, 3)
        XCTAssertEqual(dropped, 0)
    }

    /// 判定の材料は**渡した集合**であって木全体ではない: 祖先が印を持たないなら子孫は残る
    func testOutermostIgnoresAncestorsOutsideTheFlaggedSet() {
        let container = element(ref: 1, type: "other", id: "Row",
                                frame: FTRect(x: 0, y: 0, width: 400, height: 100), depth: 1)
        let child = element(ref: 2, type: "staticText", id: "Label", label: "行",
                            frame: FTRect(x: 10, y: 10, width: 100, height: 18), depth: 2)
        let (outer, dropped) = MCPServer.outermost([child], in: [container, child])
        XCTAssertEqual(outer.map(\.ref), [2])
        XCTAssertEqual(dropped, 0)
    }

    // MARK: - #5 フォールバック見出しの短縮

    /// 短縮形でも「マシンプロファイルを使っていない」事実は必ず残す ——
    /// ここを消すと受け手は自分の profiles/ が死んでいることに永久に気づけない
    func testAbbreviatedFallbackHeaderStillSaysItIsNotUsingAProfile() {
        let reason = "multiple projects exist. Pick one with project: (candidates: A, B, C)"
        let full = DeviceInventory.fallbackHeader(reason: reason)
        let short = DeviceInventory.fallbackHeader(reason: reason, abbreviated: true)
        XCTAssertTrue(full.contains(reason), "初回は理由を満額で出すこと: \(full)")
        XCTAssertFalse(short.contains(reason), "2回目以降は理由を畳むこと: \(short)")
        XCTAssertTrue(short.contains("Not using a machine profile"), short)
        XCTAssertLessThan(short.count, full.count)
    }

    /// 門番は devicesText と呼び出し側で共有する(片方だけ増えると鍵だけ消費される)
    func testSupportedPlatformGate() {
        XCTAssertTrue(DeviceInventory.isSupportedPlatform(nil))
        XCTAssertTrue(DeviceInventory.isSupportedPlatform("ios"))
        XCTAssertTrue(DeviceInventory.isSupportedPlatform("android"))
        XCTAssertFalse(DeviceInventory.isSupportedPlatform("web"))
        XCTAssertFalse(DeviceInventory.isSupportedPlatform(""))
    }

    // MARK: - #2 タイムアウトは確かめてから断定する

    /// **タイムアウトは死を意味しない**: 実アプリ監査で ft_type がこれで落ち、素の文言は
    /// 「未起動 / 遅い / suspend」の3択を並べるだけだった。走査してポートが消えていれば
    /// 死亡と言い切り、**生きていれば何も足さない**(遅い/suspend の可能性が残るため)
    func testBridgeVanishedOnlyWhenThePortIsGone() {
        let others = [BridgeDiscovery.Found(port: 8125, device: "iPhone-01", engine: "inapp"),
                      BridgeDiscovery.Found(port: 8130, device: "iPhone-04", engine: "inapp")]
        XCTAssertTrue(MCPServer.bridgeVanished(port: 8127, running: others),
                      "走査に居ないポートは消えたと言い切ってよい")
        XCTAssertTrue(MCPServer.bridgeVanished(port: 8127, running: []),
                      "1本も走っていないなら当然消えている")
        XCTAssertFalse(MCPServer.bridgeVanished(port: 8125, running: others),
                       "生きているポートのタイムアウトは死亡と断定しないこと")
    }

    // MARK: - #6 宛先に udid を出す

    /// **先頭は必ず `port `**: `connectionLostHint` が `hasPrefix("port")` で iOS 経路を判別する
    func testConnectionLabelCarriesTheUDIDAndKeepsThePortPrefix() {
        let labelled = MCPServer.connectionLabel(port: 8127, udid: "C96A69C4-FE49-42EE")
        XCTAssertTrue(labelled.hasPrefix("port 8127"), labelled)
        XCTAssertTrue(labelled.contains("C96A69C4-FE49-42EE"), labelled)
        // udid を申告しない旧ブリッジでは port だけ(「不明」と書くより短く、嘘も混ざらない)
        XCTAssertEqual(MCPServer.connectionLabel(port: 8123, udid: nil), "port 8123")
        XCTAssertEqual(MCPServer.connectionLabel(port: 8123, udid: ""), "port 8123")
    }
}
