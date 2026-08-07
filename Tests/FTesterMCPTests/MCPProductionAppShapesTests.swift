// 実アプリ(Apple マップ iOS 27.0 Simulator / Google マップ Android 15)を ft_* で探索して
// 2026-08-07 に採取した形の回帰テスト。**自前の 4 SUT では1形も出ない**ので、ここが唯一の砦:
//   - 視覚的には親だが木では兄弟のラッパー(検索バー・カード)が遮蔽物として誤検知される
//   - 40文字超のラベルは切り詰めて印字されるので、印字どおり写したセレクタは一生当たらない
//   - 同名のスクロール容器が並ぶ画面で `scrollFrame:` に書ける形が案内されない
//
// 座標・depth・ref は**実測値をそのまま**入れてある(丸めると包含判定が 1pt で裏返る)。

import XCTest
import FTCore
import FTDSL
@testable import ftester_mcp

final class MCPProductionAppShapesTests: XCTestCase {

    private func element(_ ref: Int, _ id: String, depth: Int, type: String = "button",
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                         label: String? = nil, z: Int? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth, z: z)
    }

    /// Apple マップの1画面目(実測。ref/depth/矩形は生ツリーのまま)
    private func appleMapsHome() -> [ElementInfo] {
        [
            element(1, "Maps.Application.Standard", depth: 1, type: "window", 0, 0, 402, 874),
            element(3, "sheetGrabber", depth: 4, 152.99, 847.75, 96.01, 23.04),
            element(4, "MapsSearchBar", depth: 7, type: "other", 8, 488.64, 386, 72.97),
            element(5, "MapsSearchTextField", depth: 9, type: "searchField", 23.36, 504.00, 305.34, 42.24),
            element(8, "userProfileButton", depth: 7, 336.38, 504.00, 42.24, 42.24),
            element(10, "HomeView", depth: 7, type: "other", 8, 488.64, 386, 377.35),
            element(22, "PinnedItemSection", depth: 15, type: "other", 8, 765.81, 386, 116.18),
            element(23, "PinnedTile", depth: 17, 23.36, 765.81, 78.41, 116.18),
            element(37, "UserProfileView", depth: 8, type: "other", 8, 389.10, 386, 476.89),
            // 中身を1つ持たせる: 空の葉コンテナは isBlankLeafContainer で候補から外れるので、
            // これが無いと「遮蔽しない」が通ってしまい真陽性のテストが無力になる
            element(39, "CardButtonTypeClose", depth: 10, 336.38, 404, 42.24, 42.24),
        ]
    }

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    // MARK: - 遮蔽の誤検知(F7)

    /// **検索バーは中のアバターを覆っていない**。木では兄弟(どちらも depth 7)で、
    /// バーのほうが先に出る = 奥。面積は画面の 8.7% なので、旧規則では
    /// 「画面規模でない包含 = 遮蔽」に落ちて ⚠️scroll-leftover を出していた
    func testSearchBarIsNotAnOccluderOfTheAvatarNestedInsideIt() {
        let elements = appleMapsHome()
        let avatar = elements.first { $0.identifier == "userProfileButton" }!
        let hit = RefGuard.occluder(of: avatar, in: elements, screen: screen)
        XCTAssertNil(hit, "覆っていると報告された: \(hit?.identifier ?? "-")")
    }

    /// **カードは中の検索欄を覆っていない**。こちらは木の順序では後(ref 10 > 5)なので
    /// 順序では切れない —— 決め手は「対象の親(#MapsSearchBar)ごと包んでいる」こと
    func testCardIsNotAnOccluderWhenItAlsoEnclosesTheTargetsParent() {
        let elements = appleMapsHome()
        let field = elements.first { $0.identifier == "MapsSearchTextField" }!
        let hit = RefGuard.occluder(of: field, in: elements, screen: screen)
        XCTAssertNil(hit, "覆っていると報告された: \(hit?.identifier ?? "-")")
    }

    /// **真陽性は残す**: プロフィールシートは下のホームのタイルに実際にかぶさっている
    /// (親 #PinnedItemSection は下端 16pt はみ出すので「親ごと包む」には当たらない)
    func testProfileSheetStillCountsAsAnOccluderOfTheTileBehindIt() {
        let elements = appleMapsHome()
        let tile = elements.first { $0.identifier == "PinnedTile" }!
        let hit = RefGuard.overlayCovering(tile, in: elements, screen: screen)
        XCTAssertEqual(hit?.identifier, "UserProfileView")
    }

    /// **真陽性は残す(小さい浮遊ボタン)**: 東京駅の出発情報で ★ ピルが行の中心に乗る形
    func testFloatingPillStillCountsAsAnOccluderOfTheRowUnderIt() {
        let elements = [
            element(1, "root", depth: 1, type: "window", 0, 0, 402, 874),
            element(70, "TransitDeparturesContainer", depth: 10, type: "other", 23, 745, 355, 185),
            element(75, "TransitDepartureRow", depth: 12, type: "other", 23, 791, 355, 46),
            element(82, "FavoriteButton", depth: 12, 179, 797, 42, 36),
        ]
        let row = elements.first { $0.identifier == "TransitDepartureRow" }!
        let hit = RefGuard.overlayCovering(row, in: elements, screen: screen)
        XCTAssertEqual(hit?.identifier, "FavoriteButton")
    }

    // MARK: - 塗り順(F6)

    /// **木の順序は描画順ではない**。Google マップは地図の chrome を**シートより後に**出すが、
    /// 描画はシートが手前。ref 順で判定していたため `#mylocation_button` を無警告でタップし、
    /// 裏の広告(z=124)を踏んで **Chrome が起動**した(2026-08-07 実測)。
    /// 値は実機ならぬ emulator-5554 の実スナップショットから採った実測値
    func testPaintOrderCatchesTheSheetThatTreeOrderCallsBehind() {
        let elements = [
            element(1, "root", depth: 2, type: "other", 0, 0, 1080, 2424, z: 0),
            element(17, "place_page_tabs_container", depth: 17, type: "other",
                    0, 408, 1080, 1796, z: 76),
            element(18, "recycler_view", depth: 19, type: "collectionView",
                    0, 408, 1080, 1796, z: 78),
            element(86, "on_map_secondary_action_button_container", depth: 9, type: "other",
                    881, 1075, 199, 199, z: 15),
            element(87, "qu_mylocation_container", depth: 10, type: "other",
                    881, 1075, 199, 186, z: 16),
            element(88, "mylocation_button", depth: 11, type: "image",
                    881, 1075, 199, 186, label: "位置情報サービスが無効。", z: 17),
        ]
        let target = elements.first { $0.identifier == "mylocation_button" }!
        // ref 順だけを見ると 17 < 88 なので「シートは奥」= 見逃していた
        XCTAssertTrue(target.ref > 17)
        let hit = RefGuard.overlayCovering(target, in: elements,
                                           screen: FTRect(x: 0, y: 0, width: 1080, height: 2424))
        XCTAssertEqual(hit?.identifier, "place_page_tabs_container")
    }

    /// **z を申告しないエンジン(iOS)では ref 順のまま**。片方だけ nil の木でも大小を比べない
    func testPaintOrderFallsBackToTreeOrderWhenTheBridgeDoesNotReportIt() {
        let behind = element(5, "a", depth: 2, 0, 0, 10, 10)
        let front = element(9, "b", depth: 2, 0, 0, 10, 10)
        XCTAssertTrue(RefGuard.drawnAbove(front, behind))
        XCTAssertFalse(RefGuard.drawnAbove(behind, front))
        // z が片側だけのときも ref 順(混在した木で大小が無意味になるのを避ける)
        let halfKnown = element(3, "c", depth: 2, 0, 0, 10, 10, z: 999)
        XCTAssertFalse(RefGuard.drawnAbove(halfKnown, behind))
    }

    // MARK: - 中身のどこでもない点を叩く(R2)

    /// 全幅の非対話コンテナで、中身は右端の FAB 1つだけ。中心は地図の上にある。
    /// 実測(Google マップ Android): `ft_tap` は "done" を返しながら海上にピンを落とした
    func testTappingAContainerWhoseCenterMissesItsContentIsFlagged() {
        let screen1080 = FTRect(x: 0, y: 0, width: 1080, height: 2424)
        let elements = [
            element(1, "map", depth: 2, type: "clickable", 0, 0, 1080, 2424),
            element(2, "layers_fab_button", depth: 4, type: "other", 0, 442, 1080, 157),
            element(3, "layers_fab", depth: 5, type: "image", 928, 457, 152, 142, label: "レイヤ"),
        ]
        let target = elements.first { $0.identifier == "layers_fab_button" }!
        let hit = RefGuard.missesItsOwnContent(target, in: elements, screen: screen1080)
        XCTAssertEqual(hit?.identifier, "layers_fab")
    }

    /// **囲っている対話要素がタップを受け止めるなら黙る**(誤検知の抑制)。
    /// 実測: `#business_place_card` の中心は空白だが、包む place card が clickable で正しく開く
    func testNoWarningWhenAnEnclosingInteractiveAncestorAbsorbsTheTap() {
        let screen1080 = FTRect(x: 0, y: 0, width: 1080, height: 2424)
        let elements = [
            element(1, "card", depth: 2, type: "clickable", 0, 1399, 1080, 1025),
            element(2, "business_place_card", depth: 3, type: "other", 0, 1399, 1080, 320),
            element(3, "title", depth: 4, type: "staticText", 42, 1462, 440, 58, label: "東京タワー"),
        ]
        let target = elements.first { $0.identifier == "business_place_card" }!
        XCTAssertNil(RefGuard.missesItsOwnContent(target, in: elements, screen: screen1080))
    }

    /// **画面規模の相手は受け止め手に数えない** —— 地図やキャンバスへ抜けること自体が実害
    func testFullScreenCanvasDoesNotCountAsAbsorbingTheTap() {
        let screen1080 = FTRect(x: 0, y: 0, width: 1080, height: 2424)
        let elements = [
            element(1, "map", depth: 2, type: "clickable", 0, 0, 1080, 2424),
            element(2, "footer_container", depth: 3, type: "other", 0, 2193, 1080, 230),
            element(3, "map_list_toggle_fab", depth: 4, type: "button", 651, 2225, 388, 147),
        ]
        let target = elements.first { $0.identifier == "footer_container" }!
        XCTAssertEqual(RefGuard.missesItsOwnContent(target, in: elements, screen: screen1080)?
            .identifier, "map_list_toggle_fab")
    }

    /// 中心が子の上にあるふつうの容器では黙る
    func testContainerWhoseCenterIsOverItsContentIsNotFlagged() {
        let elements = [
            element(1, "row", depth: 2, type: "other", 0, 0, 400, 100),
            element(2, "label", depth: 3, type: "staticText", 0, 0, 400, 100, label: "行"),
        ]
        let target = elements.first { $0.identifier == "row" }!
        XCTAssertNil(RefGuard.missesItsOwnContent(target, in: elements, screen: screen))
    }

    // MARK: - ゼロ幅文字(R4)

    /// ヒントから写したラベルは**見た目が正しいのに一致しない**ので、出す前に落とす
    func testZeroWidthCharactersAreStrippedFromLabelsWeHandBack() {
        let dirty = "\u{200b}\u{200b}MEX宮古・盛岡\u{200b}"
        // **id を持たせない**: describe は id があるとラベル分岐へ入らず、
        // ここを id 付きで書くとゼロ幅文字を戻しても落ちない(無力なテストになる)
        let noID = ElementInfo(ref: 1, type: "staticText", identifier: nil, label: dirty,
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 2)
        XCTAssertFalse(RefGuard.describe(noID).contains("\u{200b}"), RefGuard.describe(noID))
        XCTAssertTrue(RefGuard.describe(noID).contains("MEX宮古・盛岡"))
        let snap = SnapshotResponse(sessionBundleID: "a", screen: screen,
                                    elements: [noID], truncatedCount: 0)
        XCTAssertFalse(MCPServer.visibleLabelsHint(snap).contains("\u{200b}"))
    }

    // MARK: - 無効な要素(沈黙した成功の棚卸し X1)

    /// 木には `disabled` と印字しているのに、操作経路は `enabled` を一度も見ていなかった。
    /// 実測(E2E-CMP・契約上「押しても何も起きない」ボタン): tap / press / double_tap の
    /// 3つとも無警告で "done" を返していた
    func testDisabledElementsAreCalledOut() {
        let off = ElementInfo(ref: 17, type: "button", identifier: "btn_always_disabled",
                              label: "無効ボタン", value: nil, placeholder: nil, enabled: false,
                              frame: FTRect(x: 42, y: 1544, width: 309, height: 126), depth: 3)
        let warning = RefGuard.disabledWarning(off)
        XCTAssertTrue(warning.contains("disabled"), warning)
        XCTAssertTrue(warning.contains("#btn_always_disabled"), warning)
    }

    /// 有効な要素では黙る(毎回付くと注記が意味を失う)
    func testEnabledElementsGetNoDisabledWarning() {
        let on = element(1, "btn", depth: 2, 0, 0, 100, 40, label: "押せる")
        XCTAssertEqual(RefGuard.disabledWarning(on), "")
    }

    // MARK: - 切り詰めラベル(F5)

    /// 印字は40文字で切れる。**その文字列をそのままセレクタにすると一生当たらない**ので、
    /// 木を返すときに必ず言う。実測: Google マップの説明文をそのまま waitFor に渡すと外れるのに、
    /// 同じ応答にその文字列が2行印字されていた
    func testTruncatedLabelsAreCalledOutWhenTheTreeIsReturned() {
        let long = String(repeating: "あ", count: 55)
        let snap = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [element(1, "desc", depth: 2, type: "staticText", 0, 0, 300, 40, label: long)],
            truncatedCount: 0)
        XCTAssertTrue(SnapshotRenderer.render(snap).contains("…"))
        let note = SnapshotRenderer.truncatedLabelNote(snap)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("*\(String(repeating: "あ", count: 12))*") == true, note ?? "")
    }

    /// 40文字以下しか無い画面では黙る(注記を毎回出すと表の頭が太る)
    func testShortLabelsProduceNoTruncationNote() {
        let snap = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [element(1, "t", depth: 2, type: "staticText", 0, 0, 300, 40, label: "短い")],
            truncatedCount: 0)
        XCTAssertNil(SnapshotRenderer.truncatedLabelNote(snap))
    }

    /// 切り詰め表示をそのまま渡した失敗は、綴りでも待ち時間でもないと名指しする
    func testPassingTheTruncatedDisplayBackIsNamedAsTheCause() {
        let long = String(repeating: "い", count: 55)
        let snap = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [element(1, "desc", depth: 2, type: "staticText", 0, 0, 300, 40, label: long)],
            truncatedCount: 0)
        let asPrinted = String(long.prefix(40)) + "…"
        XCTAssertNotNil(SnapshotRenderer.truncatedSelectorHint(asPrinted, in: snap))
        // 切り詰めと無関係な失敗では黙る
        XCTAssertNil(SnapshotRenderer.truncatedSelectorHint("ただの誤字", in: snap))
    }

    // MARK: - 記法の助言(F3)

    /// **id 指定には id の部分一致を勧める**。旧版は無条件に `*foo*`(=ラベル部分一致)を
    /// 勧めており、id には一生当たらない書き方を案内していた
    func testIdSelectorGetsTheIdPartialMatchNotationNotTheLabelOne() {
        let elements = [element(1, "search_omnibox_text_box", depth: 2, 0, 0, 100, 40)]
        let hint = StepExecutor.partialMatchHint(for: FTSelector.parse("#omnibox").primary,
                                                 in: elements)
        XCTAssertEqual(hint, "present as a partial id match: writing \"#*omnibox*\" would find it")
    }

    /// **既に部分一致で書いてある相手には黙る**(同じものを勧め返さない)
    func testAlreadyPartialSelectorGetsNoNotationAdvice() {
        let elements = [element(1, "row", depth: 2, type: "staticText", 0, 0, 100, 40, label: "寿司屋")]
        XCTAssertNil(StepExecutor.partialMatchHint(for: FTSelector.parse("*寿司*").primary,
                                                   in: elements))
    }

    /// app bar の下に潜った行は**部分的にしか重ならない**ので、包含側の緩和では守られない経路。
    /// 面積規則(画面の 12%)が効いていることを固定する
    func testAppBarStillOccludesARowScrolledUnderIt() {
        let bar = FTRect(x: 0, y: 0, width: 1080, height: 290)
        let elements = [
            element(1, "root", depth: 1, type: "window", 0, 0, 1080, 2424),
            element(2, "list", depth: 2, type: "other", 0, 0, 1080, 2424),
            element(3, "row_03", depth: 3, 0, 150, 1080, 120),
            element(9, "app_bar", depth: 2, type: "other",
                    bar.x, bar.y, bar.width, bar.height),
            // 空の葉コンテナ除外(欠陥③)を経由しないよう子を持たせる
            element(10, "btn_back", depth: 3, 20, 20, 60, 60, label: "戻る"),
        ]
        let row = elements.first { $0.identifier == "row_03" }!
        let hit = RefGuard.overlayCovering(row, in: elements,
                                           screen: FTRect(x: 0, y: 0, width: 1080, height: 2424))
        XCTAssertEqual(hit?.identifier, "app_bar")
    }
}
