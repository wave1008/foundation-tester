// 「撃つ前に言える危なさ」の共有判定。**MCP と DSL が同じ定義を使う**ことが要点。
// DSL 側は失敗にせずステップ注記へ混ぜる(無効な要素をわざと叩く書き方は正当なため)。

import XCTest
@testable import FTCore

final class TapTargetAdvisoryTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)

    private func element(_ ref: Int, _ id: String, _ type: String,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                         depth: Int = 2, enabled: Bool = true) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    /// 木には `disabled` と印字しているのに、操作経路は `enabled` を一度も見ていなかった
    /// (E2E-CMP の契約上「押しても何も起きない」ボタンで実測)
    func testDisabledTargetIsCalledOut() {
        let off = element(1, "btn_always_disabled", "button", 42, 1544, 309, 126, enabled: false)
        let note = TapTargetGeometry.advisory(for: off, in: [off], screen: screen)
        XCTAssertEqual(note, "the target is disabled, so this almost certainly did nothing")
    }

    /// **ホイールピッカーは何も覆わない**(2026-08-12 の実アプリ監査)。`pickerWheel` は
    /// 回転ドラムの content 全長を frame に出すので入れ物を上下にはみ出す ——
    /// 実測(Apple マップの経路オプション・iOS 27 Simulator): `datePicker`
    /// (41,246.7 320x216) の中のホイールが (81,209.2 133x291) で、その上に並ぶ
    /// セグメント「今すぐ出発」(26,204.3 116x32) の中心 (84,220.3) を覆っていた。
    /// 実際のタップは通る(同日 ft_batch で実測)ので純粋な誤検知。
    ///
    /// **並び順はフィクスチャ ios-maps_route_options のまま**にしてある —— ホイールを
    /// セグメントの直後に置くと `lineage` が子孫として除外してしまい、
    /// 「修正が効いた」のか「候補にすら上がらなかった」のか区別できないテストになる
    func testPickerWheelDoesNotOccludeTheSegmentAboveIt() {
        let segment = element(13, "OptionLabel", "button", 26, 204.33, 116, 32, depth: 17)
        let elements = [
            segment,
            element(14, "OptionLabel", "button", 142, 204.33, 117, 32, depth: 17),
            element(16, "", "clickable", 16, 246.67, 370, 216, depth: 11),
            element(18, "", "datePicker", 41, 246.67, 320, 216, depth: 16),
            element(19, "", "pickerWheel", 81, 209.17, 133, 291, depth: 18),
        ]
        XCTAssertNil(OcclusionGeometry.overlayCovering(segment, in: elements, screen: screen),
                     "ホイールの申告 frame は描画範囲ではないので遮蔽と言わないこと")
        XCTAssertNil(TapTargetGeometry.advisory(for: segment, in: elements, screen: screen))
    }

    /// **入れ物ごと外したのではない**ことの対照: ピッカーの器そのものが中心を覆うなら
    /// 従来どおり名指しする。これが黙ると「ピッカーが下の入力欄を覆っている」本物の形を落とす
    func testTheEnclosingPickerContainerStillOccludes() {
        let field = element(13, "field", "button", 60, 300, 116, 32, depth: 17)
        let elements = [
            field,
            element(18, "", "datePicker", 41, 246.67, 320, 216, depth: 17),
        ]
        let hit = OcclusionGeometry.overlayCovering(field, in: elements, screen: screen)
        XCTAssertEqual(hit?.ref, 18, "ホイールでなく器が覆っているなら名指しすること")
    }

    /// 有効な要素では黙る(毎回付くと注記が意味を失う)
    func testEnabledPlainTargetIsSilent() {
        let on = element(1, "btn", "button", 0, 0, 100, 40)
        XCTAssertNil(TapTargetGeometry.advisory(for: on, in: [on], screen: screen))
    }

    /// 全幅の非対話コンテナで中身は右端の FAB だけ = 中心は地図の上
    /// (実測: 叩くと海上の座標にピンが落ちて place page が開いた)
    func testContainerWhoseCentreMissesItsContent() {
        let elements = [
            element(1, "map", "clickable", 0, 0, 1080, 2424),
            element(2, "layers_fab_button", "other", 0, 442, 1080, 157, depth: 4),
            element(3, "layers_fab", "image", 928, 457, 152, 142, depth: 5),
        ]
        let note = TapTargetGeometry.advisory(for: elements[1], in: elements, screen: screen)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("#layers_fab") == true, note ?? "")
        XCTAssertTrue(note?.contains("behind it") == true, note ?? "")
    }

    /// **囲っている対話要素がタップを受け止めるなら黙る**(誤検知の抑制)
    func testEnclosingInteractiveAncestorSilencesIt() {
        let elements = [
            element(1, "card", "clickable", 0, 1399, 1080, 1025),
            element(2, "business_place_card", "other", 0, 1399, 1080, 320, depth: 3),
            element(3, "title", "staticText", 42, 1462, 440, 58, depth: 4),
        ]
        XCTAssertNil(TapTargetGeometry.advisory(for: elements[1], in: elements, screen: screen))
    }

    /// **中心が画面の外**は空振りの警告になる(実測: Compose iOS のカレンダーで
    /// ヘッダ裏へ抜けた `#slot_07`(中心 y=-18)への ref タップが無警告の no-op だった)
    func testOffscreenCentreIsCalledOut() {
        let above = element(1, "slot_07", "button", 0, -46, 402, 56)
        let note = TapTargetGeometry.advisory(
            for: above, in: [above], screen: FTRect(x: 0, y: 0, width: 402, height: 874))
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("outside the visible screen") == true, note ?? "")
        XCTAssertTrue(note?.contains("(201, -18)") == true, note ?? "")
    }

    /// **縁の丸め誤差では黙る**(実測: Apple マップ下端バーの `#SubtitleLabel` は中心が
    /// screen.height を 0.3pt だけ超えるが、見えているラベルなので警告したら嘘)
    func testEdgeRoundingIsNotCalledOffscreen() {
        let edge = element(1, "SubtitleLabel", "staticText", 51, 866.8, 23, 15)
        XCTAssertNil(TapTargetGeometry.offscreenAdvisory(
            for: edge, screen: FTRect(x: 0, y: 0, width: 402, height: 874)))
    }

    /// screen が採れない(0 サイズ)ときは黙る(嘘を足さない)
    func testZeroScreenStaysSilent() {
        let e = element(1, "x", "button", -100, -100, 10, 10)
        XCTAssertNil(TapTargetGeometry.offscreenAdvisory(
            for: e, screen: FTRect(x: 0, y: 0, width: 0, height: 0)))
    }

    // MARK: - occlusionAdvisory(座標に依るチェーン。連鎖と優先順の実体は advisoryKind)
    //
    // **advisoryKind が唯一の連鎖の定義**: 以前はここに「MCP の
    // RefGuard.overlapWarning と同じ優先順」という主張だけがあり、それを照合するテストが
    // 無いままズレていた(zeroFrame・sliver の2形が MCP のタップ時に出ていなかった)。
    // 今は両者が `TapTargetGeometry.advisoryKind` を呼ぶので、順序はここでしか変えられない。
    // 優先順そのものの固定は下の TapAdvisoryKindPriorityTests、DSL/MCP が同じ kind を
    // 経由することの固定は Tests/FTesterMCPTests/TapAdvisoryKindSharedTests.swift 側にある。

    func testZeroWidthFrameIsCalledOutByChain() {
        let e = element(1, "z", "button", 100, 100, 0, 40)
        let note = TapTargetGeometry.occlusionAdvisory(for: e, in: [e], screen: screen)
        XCTAssertTrue(note?.contains("zero width/height") == true, note ?? "")
    }

    func testZeroHeightFrameIsCalledOutByChain() {
        let e = element(1, "z", "button", 100, 100, 40, 0)
        let note = TapTargetGeometry.occlusionAdvisory(for: e, in: [e], screen: screen)
        XCTAssertTrue(note?.contains("zero width/height") == true, note ?? "")
    }

    /// 実測形と同じ nav_heal / tab_controls(OcclusionGeometry.overlayCovering の doc 参照)
    func testOverlayCoveringIsCalledOutByChain() {
        let target = ElementInfo(ref: 1, type: "clickable", identifier: "nav_heal", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 16, y: 788, width: 370, height: 62), depth: 2)
        let overlay = ElementInfo(ref: 2, type: "clickable", identifier: "tab_controls", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 134, y: 778, width: 134, height: 62), depth: 2)
        let note = TapTargetGeometry.occlusionAdvisory(for: target, in: [target, overlay], screen: screen)
        XCTAssertTrue(note?.contains("#tab_controls") == true, note ?? "")
        XCTAssertTrue(note?.contains("instead") == true, note ?? "")
    }

    /// **クランプされた幽霊は覆えない**(2026-08-14・実機 SmartNews で実測。
    /// `OcclusionGeometry.occluder` の当該コメント参照)。容器の原点へ潰れた残骸(自身が
    /// 容器より小さく、同じ原点・同 depth の兄弟が3つ以上いる)は `isOutsideContainer` を
    /// 素通りするので、修正前は「本当は何も覆っていない対象」に対して幽霊を犯人として
    /// 名指ししていた。実測ではコーパス全数(ios-news_feed)で overlay 52件中30件がこの誤り
    func testClampedGhostDoesNotOccludeAnything() {
        let container = element(1, "list_rows", "table", 0, 0, 400, 800, depth: 1)
        // 中心 (150,75) がクランプ幽霊の矩形 (0,0 150x100) の縁ぎりぎり内側に入るよう置く
        let target = element(2, "top_carousel", "clickable", 50, 50, 200, 50, depth: 2)
        // クランプ幽霊の条件(hasClampedCoordinates): 容器の原点にちょうど固定され、
        // 容器より小さい、同じ frame を持つ同 depth の兄弟が3つ以上
        // **type は "other" にしない**: `isBlankLeafContainer` が type=="other"・無ラベル・
        // 無子孫を先に弾くので、"other" のままだと本題(hasClampedCoordinates)の手前で
        // 除外されてしまい、この修正を1バイトも検証しないテストになる
        let ghosts = (0..<3).map { element(10 + $0, "", "clickable", 0, 0, 150, 100, depth: 2) }
        let elements = [container, target] + ghosts
        let note = TapTargetGeometry.occlusionAdvisory(for: target, in: elements, screen: screen)
        XCTAssertNil(note, "実体の無いクランプ幽霊が覆っていると誤って名指しした: \(note ?? "-")")
    }

    /// 上と対になる**陰性対照ではない対照**: クランプの条件(3件以上・容器より小さい・
    /// 同一原点)を1つでも外すと、普通の重なりとして通常どおり検出される(退化していないこと)
    func testOrdinaryOverlapStillOccludesAfterTheClampFix() {
        let container = element(1, "list_rows", "table", 0, 0, 400, 800, depth: 1)
        let target = element(2, "top_carousel", "clickable", 50, 50, 200, 50, depth: 2)
        // 2件しかない = clampedStackThreshold(3)未満なので、単なる重なりとして扱われる
        let overlay1 = element(10, "ad_row", "clickable", 0, 0, 150, 100, depth: 2)
        let overlay2 = element(11, "ad_row2", "clickable", 0, 0, 150, 100, depth: 2)
        let elements = [container, target, overlay1, overlay2]
        let note = TapTargetGeometry.occlusionAdvisory(for: target, in: elements, screen: screen)
        XCTAssertTrue(note?.contains("#ad_row") == true, note ?? "-")
    }

    /// **原点だけが同じで大きさが違うクランプにも印が付く**(2026-08-14。
    /// `OcclusionGeometry.originClampedRefs`)。実アプリのフィードは行の高さがまちまちなので、
    /// 矩形の完全一致だけを見ていた頃はクランプ 65 件のうち 42 件にしか印が付かなかった
    func testOriginOnlyClampIsFlaggedEvenWhenSizesDiffer() {
        let container = element(1, "list", "table", 0, 100, 400, 700, depth: 1)
        // 同じ原点 (0,100)・同 depth・大きさはバラバラ = 実アプリのフィードのクランプ。
        // **ラベルを持たせるのが要点**: 実際の witness(SmartNews の広告コピー)は文字を持ち、
        // 無地のラッパーの重ね合わせ(and-camera_canvas)と区別されるのがこの条件
        func labelled(_ ref: Int, _ w: Double, _ h: Double, _ text: String) -> ElementInfo {
            ElementInfo(ref: ref, type: "staticText", identifier: nil, label: text, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 100, width: w, height: h), depth: 2)
        }
        let a = labelled(10, 150, 20, "広告 A")
        let b = labelled(11, 200, 30, "広告 B")
        let c = labelled(12, 120, 40, "広告 C")
        let elements = [container, a, b, c]
        for ghost in [a, b, c] {
            let note = TapTargetGeometry.occlusionAdvisory(for: ghost, in: elements, screen: screen)
            XCTAssertTrue(note?.contains("clamped leftovers") == true,
                          "原点クランプに印が付かない: \(note ?? "-")")
        }
        // **断定しない**: 大きさが違うので「完全一致」と言ってはいけない
        let note = TapTargetGeometry.occlusionAdvisory(for: a, in: elements, screen: screen)
        XCTAssertFalse(note?.contains("exact frame") == true, note ?? "-")
    }

    /// **無地のラッパーの重ね合わせは数えない**(2026-08-14・and-camera_canvas で判明)。
    /// Google カメラのプレビューは重ね合わせ層が全部 (0,288 1080x1440) に並ぶ普通の形で、
    /// ラベルを持つのは1つだけ。矩形一致の側には最初からあったこの条件を原点側に付け忘れ、
    /// **入れたばかりの検知が次の画面で誤検知を出す**という台帳の警告を踏んだ(13件)
    func testOriginClampIgnoresBlankWrapperStacks() {
        let container = element(1, "preview", "other", 0, 100, 400, 700, depth: 1)
        // 同じ原点・同 depth・**ラベルも値も無い**層が3つ
        let layers = (0..<3).map { element(10 + $0, "layer\($0)", "other", 0, 100, 400, 600, depth: 2) }
        let elements = [container] + layers
        for layer in layers {
            XCTAssertFalse(OcclusionGeometry.isOriginClamped(layer, in: elements),
                           "無地の重ね合わせ層をクランプ扱いした")
        }
    }

    /// 上の陰性対照: **同じ原点でも兄弟が2件だけならクランプ扱いしない**(容器と子が原点を
    /// 共有するのは普通の版組なので、ここを緩めると正常な木が丸ごと警告になる)。
    /// 2件は「片方が本当にもう片方を覆っている」形なので、overlay の警告になるのが正しい
    func testOriginClampNeedsThreeSiblings() {
        let container = element(1, "list", "table", 0, 100, 400, 700, depth: 1)
        let a = element(10, "", "staticText", 0, 100, 150, 20, depth: 2)
        let b = element(11, "", "staticText", 0, 100, 200, 30, depth: 2)
        XCTAssertFalse(OcclusionGeometry.isOriginClamped(a, in: [container, a, b]))
        let note = TapTargetGeometry.occlusionAdvisory(for: a, in: [container, a, b], screen: screen)
        XCTAssertFalse(note?.contains("clamped leftovers") == true,
                       "2件でクランプ扱いした(容器+子の普通の版組を巻き込む): \(note ?? "-")")
    }

    /// **スクロール容器は、その点に自分の中身が無いなら何も隠していない**。
    /// content inset を持つ容器はフレームが上の chrome の下へ潜り込むので、iOS(z 無し)では
    /// 木の順序だけで「タブ帯を覆っている」と誤報告していた
    func testScrollContainerWithNoContentAtThePointDoesNotOcclude() {
        // 容器は y=0 から始まるが、中身は y=103 以降にしか無い(実測 ios-news_feed と同型)
        let tab = element(1, "tab_gadget", "clickable", 320, 59, 79, 41, depth: 3)
        var table = element(2, "list", "table", 0, 0, 393, 769, depth: 2)
        table.scrollable = true
        let row = element(3, "row_01", "clickable", 0, 103, 393, 128, depth: 3)
        let note = TapTargetGeometry.occlusionAdvisory(for: tab, in: [tab, table, row],
                                                       screen: screen)
        XCTAssertNil(note, "中身の無い帯で覆っていると報告した: \(note ?? "-")")
    }

    /// 上の陽性対照: **同じ形でも、その点に中身があるなら従来どおり覆っていると報告する**
    /// (実アプリの witness は Safari のスタートページ —— 背後の本文リンクをタイルが実際に覆う)
    func testScrollContainerWithContentAtThePointStillOccludes() {
        let link = element(1, "bg_link", "link", 320, 59, 79, 41, depth: 3)
        var grid = element(2, "StartPageCollectionView", "collectionView", 0, 0, 393, 769, depth: 2)
        grid.scrollable = true
        // 中身は**その点を覆うが、それ自身は遮蔽候補にならない**もの(無ラベルの葉 =
        // isBlankLeafContainer)にする。中身を単なる cell にすると、「容器を丸ごと除外する」
        // 変異でその cell が身代わりに犯人となり、テストが素通りする
        // (2026-08-14 に変異が生き残って判明。**名指しの相手まで固定する**)
        let tile = element(3, "", "other", 300, 40, 90, 90, depth: 3)
        let note = TapTargetGeometry.occlusionAdvisory(for: link, in: [link, grid, tile],
                                                       screen: screen)
        XCTAssertTrue(note?.contains("#StartPageCollectionView") == true, note ?? "-")
    }

    /// **ゲート**: 上のクロムの下へスクロールで潜っている疑い(2026-08-14・iOS カレンダーで実測)。
    /// ナビバーは木の**前**にあるので `drawnAbove` が false になり遮蔽として名指しされない ——
    /// その死角を拾って `AppDriver.hittable` へ聞きに行く入口
    func testSuspectedHiddenUnderChromeFiresForACellScrolledUnderTheNavBar() {
        // **並びは実物どおり**(iOS カレンダーの月表示): ナビバーの子が depth 15 で数個並び、
        // その後に scrollView(18)が来る。BackButton の直後に容器を置くと、depth だけを見る
        // 祖先復元が **BackButton を cell の祖先と見なして** lineage で除外してしまい、
        // ゲートが発火しないテストになる(2026-08-14 に一度そう書いて落ちた)
        let nav = element(1, "nav", "navigationBar", 0, 61, 402, 45, depth: 14)
        let back = element(2, "BackButton", "button", 16, 61, 111, 44, depth: 15)
        let title = element(3, "current-month-year", "staticText", 20, 122, 54, 39, depth: 15)
        var scroller = element(4, "month", "scrollView", 0, 0, 402, 874, depth: 18)
        scroller.scrollable = true
        let cell = element(5, "cell_0726", "button", 7, 47, 42, 41, depth: 20)
        let visible = element(6, "cell_0817", "button", 66, 549, 38, 41, depth: 20)
        let elements = [nav, back, title, scroller, cell, visible]
        XCTAssertTrue(TapTargetGeometry.suspectedHiddenUnderChrome(cell, in: elements,
                                                                   screen: screen))
        // 陰性対照1: 普通に見えているセルは疑わない(= 照会を払わない)
        XCTAssertFalse(TapTargetGeometry.suspectedHiddenUnderChrome(visible, in: elements,
                                                                    screen: screen))

        // 陰性対照2: **覆う相手が容器の中**なら疑わない —— 容器の中の重なりは木の順序で
        // 判断できる領域(`occluder` の担当)で、プラットフォームへ聞く理由が無い。
        // この対照が無いと「容器の外」という条件を外す変異が生き残る
        // **ref を victim より小さくする**(塗り順は配列順ではなく **ref の大小**。
        // 大きいと drawnAbove が真になって既存の遮蔽判定が先に拾い、「容器の外」という条件を
        // 外す変異が素通りする。2026-08-14 に配列順で並べ替えて一度生き残った)
        let sibling = element(5, "overlay_row", "button", 60, 540, 60, 60, depth: 20)
        let insideOverlap = [nav, back, title, scroller, sibling, visible]
        XCTAssertFalse(TapTargetGeometry.suspectedHiddenUnderChrome(visible, in: insideOverlap,
                                                                    screen: screen),
                       "容器の中の重なりまで疑うと、聞く必要の無い照会を払う")
    }

    /// **z がある木(Android)には掛けない**: 塗り順が実測で採れているなら `drawnAbove` が権威で、
    /// 黙っているのが正しい判断。そもそも聞く先(isHittable)も無い。
    /// 実測でもこの条件が無いと Android のフィクスチャだけで32件鳴った
    func testSuspectedHiddenUnderChromeStaysSilentWhenPaintOrderIsKnown() {
        var nav = element(1, "nav", "navigationBar", 0, 61, 402, 45, depth: 14)
        var back = element(2, "BackButton", "button", 16, 61, 111, 44, depth: 15)
        var title = element(3, "current-month-year", "staticText", 20, 122, 54, 39, depth: 15)
        var scroller = element(4, "month", "scrollView", 0, 0, 402, 874, depth: 18)
        scroller.scrollable = true
        var cell = element(5, "cell_0726", "button", 7, 47, 42, 41, depth: 20)
        // **z 以外の条件はすべて満たす形にする**(そうしないと「z を外しても落ちない」= 変異で
        // 殺せないテストになる。2026-08-14 に一度そう書いて生き残った)。
        // z を外せば発火する = この検査は z の条件だけを見ている
        // 覆う相手の z を**下**にする = 塗り順が「奥」と言って既存の遮蔽判定は黙る形
        // (Android で32件鳴っていたのがこれ)。z が上だと occluder が先に拾ってしまい、
        // z の条件を外す変異が素通りする
        nav.z = 0; back.z = 0; title.z = 0; scroller.z = 1; cell.z = 2
        let withZ = [nav, back, title, scroller, cell]
        XCTAssertFalse(TapTargetGeometry.suspectedHiddenUnderChrome(cell, in: withZ, screen: screen))
        let withoutZ = withZ.map { e -> ElementInfo in var c = e; c.z = nil; return c }
        XCTAssertTrue(TapTargetGeometry.suspectedHiddenUnderChrome(
            withoutZ[4], in: withoutZ, screen: screen),
                      "z を外しても発火しないなら、この検査は z の条件を見ていない")
    }

    /// 対話的な親の子孫が中心を横取りする形(`nestedActionCoveringCentre` の doc 参照)
    func testNestedActionIsCalledOutByChain() {
        let parent = ElementInfo(ref: 1, type: "cell", identifier: "row", label: nil, value: nil,
                                 placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 2)
        let child = ElementInfo(ref: 2, type: "button", identifier: "chip", label: nil, value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 40, y: 40, width: 20, height: 20), depth: 3)
        let note = TapTargetGeometry.occlusionAdvisory(for: parent, in: [parent, child], screen: screen)
        XCTAssertTrue(note?.contains("#chip") == true, note ?? "")
        XCTAssertTrue(note?.contains("instead") == true, note ?? "")
    }

    /// 同一矩形に3件以上積まれた要素(`OcclusionGeometry.stackedRefs` の doc 参照)。
    /// 「other」型で子孫を持たないので missedContent/nested には掛からず、stacked だけが発火する
    func testStackedFramesAreCalledOutByChain() {
        func stacked(_ ref: Int, _ label: String) -> ElementInfo {
            ElementInfo(ref: ref, type: "other", identifier: "poi", label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 300, y: 300, width: 30, height: 30), depth: 1)
        }
        let elements = (0..<3).map { stacked($0 + 1, "STACK\($0)") }
        let note = TapTargetGeometry.occlusionAdvisory(for: elements[0], in: elements, screen: screen)
        XCTAssertTrue(note?.contains("clamped leftovers") == true, note ?? "")
    }

    /// 実害形と同じ細帯(`isClippedSliver` のテスト群と同じ要素)がチェーン経由でも出る
    func testSliverIsCalledOutByChain() {
        var e = element(1, "tab_sunrise_seto", "tab", 1071, 100, 9, 137)
        e.label = "サンライズ瀬戸"
        let note = TapTargetGeometry.occlusionAdvisory(for: e, in: [e], screen: screen)
        XCTAssertTrue(note?.contains("sliver") == true, note ?? "")
    }

    /// **優先順**: 画面外と遮蔽が両方成り立つ形で、画面外(強い事実)だけが出る
    func testOffscreenBeatsOverlayInThePriorityChain() {
        let target = ElementInfo(ref: 1, type: "clickable", identifier: "target", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: -46, width: 402, height: 56), depth: 2)
        // 中心 (201, -18) を覆う候補(画面外チェックより先に評価されたら誤って発火する)
        let overlay = ElementInfo(ref: 2, type: "clickable", identifier: "overlay", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: -60, width: 250, height: 80), depth: 2)
        let smallScreen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let note = TapTargetGeometry.occlusionAdvisory(
            for: target, in: [target, overlay], screen: smallScreen)
        XCTAssertTrue(note?.contains("outside the visible screen") == true, note ?? "")
        XCTAssertFalse(note?.contains("covered by") == true, note ?? "")
    }

    /// **優先順**: 容器外送出と遮蔽が両方成り立つ形で、容器外(frame が古い = 遮蔽の名指しも
    /// 嘘になる)だけが出る
    func testScrolledOutBeatsOverlayInThePriorityChain() {
        let smallScreen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let scroller = ElementInfo(ref: 1, type: "other", identifier: "scroller", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 100, width: 402, height: 600), depth: 1,
                                   scrollable: true)
        let rowA = ElementInfo(ref: 2, type: "clickable", identifier: "row_a", label: "行A",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: 110, width: 370, height: 20), depth: 2)
        let rowB = ElementInfo(ref: 3, type: "clickable", identifier: "row_b", label: "行B",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: 160, width: 370, height: 20), depth: 2)
        let target = ElementInfo(ref: 4, type: "clickable", identifier: "target", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 750, width: 370, height: 20), depth: 2)
        // 中心 (195, 760) を覆う候補(容器外チェックより先に評価されたら誤って発火する)
        let overlay = ElementInfo(ref: 5, type: "clickable", identifier: "overlay", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 740, width: 300, height: 60), depth: 2)
        let elements = [scroller, rowA, rowB, target, overlay]
        let note = TapTargetGeometry.occlusionAdvisory(for: target, in: elements, screen: smallScreen)
        XCTAssertTrue(note?.contains("leftover from scrolling") == true, note ?? "")
        XCTAssertFalse(note?.contains("covered by") == true, note ?? "")
    }

    /// **disabled が優先**: 両方に当てはまるときは「そもそも無効」を先に言う
    func testDisabledWinsOverTheGeometricAdvice() {
        let elements = [
            element(1, "map", "clickable", 0, 0, 1080, 2424),
            element(2, "wrap", "other", 0, 442, 1080, 157, depth: 4, enabled: false),
            element(3, "inner", "image", 928, 457, 152, 142, depth: 5),
        ]
        XCTAssertEqual(TapTargetGeometry.advisory(for: elements[1], in: elements, screen: screen),
                       "the target is disabled, so this almost certainly did nothing")
    }

    // MARK: - keyboardCoveredAdvisory
    //
    // 木からは判定できない(キーボードはスナップショットの対象外)ので、ブリッジ申告の
    // keyboardFrame でだけ言える。実測(2026-08-08・iOS): キーボード下の候補行 ref タップが
    // 警告なしで顔文字キーに当たった(inputView は空葉になり、既存の空葉除外で遮蔽から漏れる)。

    /// 中心がキーボードの中 → 警告
    func testKeyboardCoveredCentreIsCalledOut() {
        let keyboard = FTRect(x: 0, y: 600, width: 402, height: 274)
        let target = element(1, "suggestion_row", "button", 16, 620, 370, 40)
        let note = TapTargetGeometry.keyboardCoveredAdvisory(target, keyboardFrame: keyboard)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("soft keyboard") == true, note ?? "")
    }

    /// 中心がキーボードの外 → 黙る
    func testCentreAboveTheKeyboardIsSilent() {
        let keyboard = FTRect(x: 0, y: 600, width: 402, height: 274)
        let target = element(1, "row", "button", 16, 400, 370, 40)
        XCTAssertNil(TapTargetGeometry.keyboardCoveredAdvisory(target, keyboardFrame: keyboard))
    }

    /// keyboardFrame が nil(旧ブリッジ・キーボード非表示)→ 黙る
    func testNoKeyboardFrameIsSilent() {
        let target = element(1, "row", "button", 16, 620, 370, 40)
        XCTAssertNil(TapTargetGeometry.keyboardCoveredAdvisory(target, keyboardFrame: nil))
    }

    // MARK: - effectiveKeyboardFrame
    //
    // 申告 keyboardFrame は `.keyboard` ノードの frame だけ(キー面のみ)で、上のサジェストバー
    // (`SystemInputAssistantView`)と地球儀/Dictate 行を含む `inputView` の下端を取りこぼす
    // (実測: 仮想デバイス iPhone 17 Pro / 402x874。申告 y=583..816 に対し木の chrome は y=538..874)。
    // ここでは実測値を丸めた自己整合な数字を使う。

    /// chrome があれば申告を上下に広げる
    func testEffectiveKeyboardFrameExpandsWithChrome() {
        let reported = FTRect(x: 0, y: 590, width: 402, height: 226) // 590..816
        let elements = [
            element(1, "inputView", "other", 0, 546, 402, 328),               // 546..874
            element(2, "SystemInputAssistantView", "other", 0, 546, 402, 44), // 546..590
        ]
        let effective = TapTargetGeometry.effectiveKeyboardFrame(reported: reported, in: elements)
        XCTAssertEqual(effective, FTRect(x: 0, y: 546, width: 402, height: 328), "546..874 まで広がること")
    }

    /// chrome が木に無ければ申告どおり(1バイトも変えない。iOS の browser_startpage /
    /// Android 全機種がこのケース)
    func testEffectiveKeyboardFrameFallsBackToReportedWithoutChrome() {
        let reported = FTRect(x: 0, y: 583, width: 402, height: 233)
        let elements = [element(1, "unrelated", "button", 16, 100, 100, 40)]
        XCTAssertEqual(TapTargetGeometry.effectiveKeyboardFrame(reported: reported, in: elements),
                       reported)
    }

    /// 申告と交差しない同名要素は和に入れない(無条件に identifier で拾うと、画面の別の場所に
    /// ある同名要素で矩形が暴発する)
    func testEffectiveKeyboardFrameIgnoresChromeThatDoesNotIntersectTheReportedFrame() {
        let reported = FTRect(x: 0, y: 590, width: 402, height: 226) // 590..816
        let elements = [element(1, "inputView", "other", 0, 0, 402, 50)] // 0..50、交差しない
        XCTAssertEqual(TapTargetGeometry.effectiveKeyboardFrame(reported: reported, in: elements),
                       reported, "交差しない chrome は無視すること")
    }

    /// keyboardFrame が nil → nil のまま(「キーボード無し」の意味を変えない)
    func testEffectiveKeyboardFrameStaysNilWithoutAReportedFrame() {
        let elements = [element(1, "inputView", "other", 0, 546, 402, 328)]
        XCTAssertNil(TapTargetGeometry.effectiveKeyboardFrame(reported: nil, in: elements))
    }

    /// **witness の再現**(実害): `#tab_home` 相当の要素は中心 (67,579) が申告 590..816 の外に
    /// 落ちるため無警告だったが、実際はキーボードの chrome(地球儀行まで)に隠れていた。
    /// 実効矩形を通すと拾われることを固定する ——この2アサーションが揃って初めて「修正が効いた」
    /// ことになる(実効矩形だけ広がって判定に使われなければ、この回帰は防げない)
    func testWitnessTabHomeIsMissedByReportedFrameButCaughtByEffectiveFrame() {
        let reported = FTRect(x: 0, y: 590, width: 402, height: 226)
        let elements = [
            element(1, "inputView", "other", 0, 546, 402, 328),
            element(2, "SystemInputAssistantView", "other", 0, 546, 402, 44),
        ]
        let tabHome = element(3, "tab_home", "button", 0, 548, 134, 62) // 中心 (67, 579)
        XCTAssertNil(TapTargetGeometry.keyboardCoveredAdvisory(tabHome, keyboardFrame: reported),
                     "申告のままでは中心 579 が 590..816 の外 = 無警告(これが実害)")
        let effective = TapTargetGeometry.effectiveKeyboardFrame(reported: reported, in: elements)
        XCTAssertNotNil(TapTargetGeometry.keyboardCoveredAdvisory(tabHome, keyboardFrame: effective),
                        "実効矩形(546..874)では中心 579 が中に入り、警告が出ること")
    }

    // MARK: - KeyboardOcclusion(chrome の部分木を除外する)
    //
    // 実測(2026-08-13 の実効矩形拡張の副作用): `#tab_home` を拾うために木の chrome
    // (`#inputView`/`#SystemInputAssistantView`)で矩形を広げると、その chrome 自身の部品
    // (地球儀キー・変換候補バー)まで「キーボードの下に隠れている」と数えてしまっていた。
    // 覆っている側を覆われている側と言う雑音で、以下は ios-messages_keyboard の実測ダンプ
    // (プロンプト記載)をそのまま使う。

    /// witness の全体再現: chrome 自身(2件)・chrome の子(3件・非対話)・chrome の子の対話要素
    /// (地球儀キー・dictation)は「覆われている」と言わない。chrome の部分木の外にある本当に
    /// 隠れたアプリの行(`#Maps.PlaceTableViewCell` 相当)には言う
    func testKeyboardOcclusionExcludesTheChromeSubtreeButKeepsAppElementsBeneathIt() {
        let reported = FTRect(x: 0, y: 583, width: 402, height: 233) // キー面だけ
        // chrome の部分木の外(preorder で chrome より前)。中心 y=871 は実効矩形の中
        let appRow = element(1, "Maps.PlaceTableViewCell", "clickable", 20, 836, 362, 70, depth: 8)
        let inputView = element(2, "inputView", "other", 0, 538, 402, 336, depth: 4)
        let assistant = element(3, "SystemInputAssistantView", "other", 0, 538, 402, 45, depth: 4)
        // SystemInputAssistantView の子孫(depth > 4 が続く間)
        let centerPageView = element(4, "CenterPageView", "other", 0, 538, 402, 45, depth: 6)
        let scrollView = element(5, "unused", "scrollView", 0, 538, 402, 45, depth: 8)
        let collectionView = element(6, "unused2", "collectionView", 0, 538, 402, 45, depth: 12)
        let globeKey = element(7, "globe_key", "button", 0, 806, 134, 68, depth: 5)
        let dictation = element(8, "dictation", "button", 268, 805, 134, 69, depth: 5)
        let elements = [appRow, inputView, assistant, centerPageView, scrollView,
                        collectionView, globeKey, dictation]

        let occlusion = KeyboardOcclusion.resolve(reported: reported, in: elements)
        XCTAssertEqual(occlusion.frame, FTRect(x: 0, y: 538, width: 402, height: 336),
                       "矩形は従来どおり chrome で広がること")

        XCTAssertNil(occlusion.advisory(for: inputView), "chrome 自身(inputView)には言わない")
        XCTAssertNil(occlusion.advisory(for: assistant),
                     "chrome 自身(SystemInputAssistantView)には言わない")
        XCTAssertNil(occlusion.advisory(for: globeKey), "chrome の子(地球儀キー)には言わない")
        XCTAssertNil(occlusion.advisory(for: dictation), "chrome の子(dictation)には言わない")
        XCTAssertNotNil(occlusion.advisory(for: appRow),
                        "chrome の部分木の外にある、本当に隠れたアプリの行には言うこと(この修正の本命)")
    }

    /// chrome が木に無ければ除外もしない(申告どおりに戻る。`ios-browser_startpage` と
    /// Android のフィクスチャ全部がこのケース)
    func testKeyboardOcclusionWithoutChromeExcludesNothing() {
        let reported = FTRect(x: 0, y: 600, width: 402, height: 274)
        let row = element(1, "some_row", "button", 16, 620, 370, 40)
        let occlusion = KeyboardOcclusion.resolve(reported: reported, in: [row])
        XCTAssertEqual(occlusion.frame, reported, "chrome が無ければ矩形は申告どおり")
        XCTAssertNotNil(occlusion.advisory(for: row), "除外対象が無いので申告どおり警告すること")
    }

    /// keyboardFrame が nil → `.none` と同じ(「キーボード無し」の意味を変えない)
    func testKeyboardOcclusionResolveStaysNilWithoutAReportedFrame() {
        let elements = [element(1, "inputView", "other", 0, 546, 402, 328)]
        let occlusion = KeyboardOcclusion.resolve(reported: nil, in: elements)
        XCTAssertNil(occlusion.frame)
        let row = element(2, "row", "button", 16, 600, 370, 40)
        XCTAssertNil(occlusion.advisory(for: row))
    }

    // MARK: - isClippedSliver

    /// 実害形: 右端で幅9pxに切れたタブ「サンライズ瀬戸」(2026-08-08・Apple マップ)
    func testThinVerticalSliverWithLabelIsClipped() {
        var e = element(1, "tab_sunrise_seto", "tab", 1071, 100, 9, 137)
        e.label = "サンライズ瀬戸"
        XCTAssertTrue(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// アイコン(9x13)は縦横比条件で除外される(ラベルを付けても偽)
    func testSmallIconIsNotASliver() {
        var e = element(1, "icon_close", "image", 1071, 100, 9, 13)
        e.label = "閉じる"
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// ラベル無しの細帯は「読めるテキストが切れた」ことを示せないので偽
    func testThinSliverWithoutALabelIsNotFlagged() {
        let e = element(1, "tab_unlabeled", "tab", 1071, 100, 9, 137)
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// 横帯(height<=10, width>=30)も同じ判定を通る
    func testThinHorizontalSliverWithLabelIsClipped() {
        var e = element(1, "banner_clipped", "staticText", 0, 866, 300, 8)
        e.label = "ライブ配信中"
        XCTAssertTrue(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// 実害形: 画面端に接した幅12px(素の閾値10は取りこぼす。実測: Google マップの
    /// モードタブ「2 時間 26」(1068,449 12x59)、画面幅1080)
    func testEdgeFlushWidth12IsClipped() {
        var e = element(1, "mode_tab", "tab", 1068, 449, 12, 59)
        e.label = "2 時間 26"
        XCTAssertTrue(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// 同じ幅12でも画面端に接していなければ「デザイン上細いだけ」の可能性を排せないので偽
    func testWidth12NotAtEdgeIsNotFlagged() {
        var e = element(1, "mode_tab", "tab", 500, 449, 12, 59)
        e.label = "2 時間 26"
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// 画面端でも edgeSliverThinDimension(14)を超える幅20は誤検知を避けるため偽
    func testEdgeFlushWidth20IsNotFlagged() {
        var e = element(1, "mode_tab", "tab", 1060, 449, 20, 59)
        e.label = "2 時間 26"
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }
}

/// **配線のテスト**: 判定関数を単体で確かめるだけでは「DSL の tap がそれを通っているか」を
/// 検証できない(2026-08-07 に掃討ハーネスで同じ穴を踏んだ)。実際に `StepExecutor` の
/// tap を実行して、ステップ注記に載ることを固定する。
private final class AdvisoryProbeDriver: AppDriver {
    let disabled: Bool
    /// true = 中心が中身のどこにも乗らない容器を `#target` として返す(有効な要素)
    let missesContent: Bool
    /// true = 中心が画面の外にある `#target` を返す(スクロールで縁の外へ抜けた形)
    let offscreen: Bool
    /// ドライバ自身が申告する注記(InAppBridge の「activate 不発→合成タッチ」に相当)
    let driverNote: String?
    /// T7: type の既存値注記テスト用。非 nil なら `#target` の value に載せる
    /// (secure=true なら型を secureTextField にして伏せ字経路を通す)
    let existingValue: String?
    let secure: Bool
    private(set) var taps = 0
    init(disabled: Bool, missesContent: Bool = false, offscreen: Bool = false,
         driverNote: String? = nil, existingValue: String? = nil, secure: Bool = false) {
        self.disabled = disabled
        self.missesContent = missesContent
        self.offscreen = offscreen
        self.driverNote = driverNote
        self.existingValue = existingValue
        self.secure = secure
    }
    var lastActionNote: String? { driverNote }
    /// このフェイクは T7(既存値注記)の配線だけを見る。snapshot() が固定値を返すので、
    /// 既定 false のままだと type 読み返しが「値が変わらない」と誤認して 8s 後に失敗する
    var verifiesTypedText: Bool { true }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws { taps += 1 }
    func tap(x: Double, y: Double) async throws { taps += 1 }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}
    /// **doubleTap を実装しないと**ジェスチャが失敗して早期 return し、注記の配線を通らない
    func doubleTap(x: Double, y: Double) async throws { taps += 1 }

    func snapshot() async throws -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        if offscreen {
            // スクロールで縁の外へ抜けた要素(実測の #slot_07 と同じ形)。単独で返す =
            // 兄弟が2つ無いので容器は推測されず、visibleTapRect には寄せられない経路になる
            return SnapshotResponse(
                sessionBundleID: nil, screen: screen,
                elements: [
                    ElementInfo(ref: 1, type: "button", identifier: "target", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: -46, width: 402, height: 56), depth: 2),
                ],
                truncatedCount: 0)
        }
        if missesContent {
            // 全幅の非対話コンテナ(#target)の中身は右端の小さな像だけ = 中心は背後の地図
            return SnapshotResponse(
                sessionBundleID: nil, screen: screen,
                elements: [
                    ElementInfo(ref: 1, type: "clickable", identifier: "canvas", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: screen, depth: 1),
                    ElementInfo(ref: 2, type: "other", identifier: "target", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 160, width: 402, height: 60), depth: 3),
                    ElementInfo(ref: 3, type: "image", identifier: "inner", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 350, y: 170, width: 40, height: 40), depth: 4),
                ],
                truncatedCount: 0)
        }
        return SnapshotResponse(
            sessionBundleID: nil, screen: screen,
            elements: [
                ElementInfo(ref: 1,
                            type: secure ? "secureTextField" : (existingValue != nil ? "textField" : "clickable"),
                            identifier: "target", label: "対象",
                            value: existingValue, placeholder: nil, enabled: !disabled,
                            frame: FTRect(x: 16, y: 410, width: 370, height: 56), depth: 2),
            ],
            truncatedCount: 0)
    }
}

/// **新チェーンの配線テスト専用ドライバ**: 固定の SnapshotResponse をそのまま返すだけ
/// (AdvisoryProbeDriver の分岐では表現しにくい複数要素の木を組むため)
private final class FixedSnapshotDriver: AppDriver {
    let response: SnapshotResponse
    private(set) var taps = 0
    private(set) var presses = 0
    private(set) var doubleTaps = 0
    init(_ response: SnapshotResponse) { self.response = response }
    var lastActionNote: String? { nil }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws { taps += 1 }
    func tap(x: Double, y: Double) async throws { taps += 1 }
    func press(ref: Int, duration: Double) async throws { presses += 1 }
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}
    func doubleTap(x: Double, y: Double) async throws { doubleTaps += 1 }
    func snapshot() async throws -> SnapshotResponse { response }
}

final class TapAdvisoryWiringTests: XCTestCase {

    /// 無効な要素を叩いたら**ステップ注記に出る**(失敗にはしない)
    func testDisabledTargetSurfacesInTheStepNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))

        XCTAssertEqual(driver.taps, 1, "注記は出すが撃つのはやめない(拒否ではない)")
        if case .passed = outcome.status {} else { XCTFail("失敗にしてはいけない: \(outcome.status)") }
        XCTAssertTrue(outcome.driverFallback?.contains("disabled") == true,
                      "注記が出ていない: \(outcome.driverFallback ?? "nil")")
    }

    /// 有効な要素では注記を足さない
    func testEnabledTargetAddsNoNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        XCTAssertEqual(driver.taps, 1)
        XCTAssertNil(outcome.driverFallback, "余計な注記が付いた: \(outcome.driverFallback ?? "")")
    }

    /// **ドライバ自身の注記と共存する**。以前はここで代入していたため、
    /// activate 不発のような**まさに飲まれた場面**で「無効な要素」の注記が消えていた
    /// (2026-08-07 のレビューで発覚。上書き→合流に直した)
    func testDriverNoteDoesNotSwallowTheAdvisory() async throws {
        let driver = AdvisoryProbeDriver(disabled: true,
                                         driverNote: "activate misfired: synthesized a touch instead")
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("disabled"), "advisory が消えた: \(note)")
        XCTAssertTrue(note.contains("activate misfired"), "ドライバの注記が消えた: \(note)")
    }

    /// **doubleTap にも載る**(配線のテスト。定数 nil に差し替えると落ちること)
    func testDoubleTapCarriesTheAdvisory() async throws {
        let driver = AdvisoryProbeDriver(disabled: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "doubleTap", locator: FlowLocator(id: "target")))
        XCTAssertTrue(outcome.driverFallback?.contains("disabled") == true,
                      "doubleTap で注記が出ていない: \(outcome.driverFallback ?? "nil")")
    }

    /// **見えている部分へ寄せたときは「背後へ抜けた」と言わない**(嘘になる)。
    /// 無効かどうかは撃つ座標に依らないので、そちらは言ってよい
    func testGeometricAdviceIsPointDependentButDisabledIsNot() {
        let elements = [
            ElementInfo(ref: 1, type: "clickable", identifier: "map", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 1080, height: 2424), depth: 2),
            ElementInfo(ref: 2, type: "other", identifier: "wrap", label: nil, value: nil,
                        placeholder: nil, enabled: false,
                        frame: FTRect(x: 0, y: 442, width: 1080, height: 157), depth: 4),
            ElementInfo(ref: 3, type: "image", identifier: "inner", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 928, y: 457, width: 152, height: 142), depth: 5),
        ]
        let wrap = elements[1]
        XCTAssertNotNil(TapTargetGeometry.disabledAdvisory(for: wrap))
        XCTAssertNotNil(TapTargetGeometry.missedContentAdvisory(
            for: wrap, in: elements, screen: FTRect(x: 0, y: 0, width: 1080, height: 2424)))
        // 有効な要素なら disabled 側だけが黙る
        let on = ElementInfo(ref: 4, type: "button", identifier: "b", label: nil, value: nil,
                             placeholder: nil, enabled: true,
                             frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 2)
        XCTAssertNil(TapTargetGeometry.disabledAdvisory(for: on))
    }

    /// **画面外の中心の配線**(tap の「寄せずに中心を撃つ」経路。実測: Compose iOS の
    /// カレンダーで #slot_07 への ref タップが無警告の no-op だった)
    func testOffscreenCentreAdvisoryReachesTheStepNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false, offscreen: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        XCTAssertEqual(driver.taps, 1, "警告は出すが撃つのはやめない(拒否ではない)")
        XCTAssertTrue(outcome.driverFallback?.contains("outside the visible screen") == true,
                      "画面外の注記が出ていない: \(outcome.driverFallback ?? "nil")")
    }

    /// **中身外しの配線**(有効な要素なので disabled 側の早期 return を通らない経路)
    func testMissedContentAdvisoryReachesTheStepNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false, missesContent: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#inner"), "中身外しの注記が出ていない: \(note)")
        XCTAssertTrue(note.contains("behind it"), note)
    }

    // MARK: - 新チェーン(occlusionAdvisory)の配線: tap / 長押し / doubleTap

    private func overlayCoveringSnapshot() -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let target = ElementInfo(ref: 1, type: "clickable", identifier: "target", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 16, y: 788, width: 370, height: 62), depth: 2)
        let overlay = ElementInfo(ref: 2, type: "clickable", identifier: "overlay", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 134, y: 778, width: 134, height: 62), depth: 2)
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [target, overlay], truncatedCount: 0)
    }

    private func scrolledOutSnapshot() -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let scroller = ElementInfo(ref: 1, type: "other", identifier: "scroller", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 100, width: 402, height: 600), depth: 1,
                                   scrollable: true)
        let rowA = ElementInfo(ref: 2, type: "clickable", identifier: "row_a", label: "行A",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: 110, width: 370, height: 20), depth: 2)
        let rowB = ElementInfo(ref: 3, type: "clickable", identifier: "row_b", label: "行B",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: 160, width: 370, height: 20), depth: 2)
        let target = ElementInfo(ref: 4, type: "clickable", identifier: "target", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 750, width: 370, height: 20), depth: 2)
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [scroller, rowA, rowB, target], truncatedCount: 0)
    }

    /// **視界の縁に半分だけ乗った要素**(visibleTapRect 経路。ClampedCoordinateTests の
    /// `testThinSliverIsNotTapped` の「real」形と同じ構成)。`phantom` は raw frame の中心を覆う
    /// 候補で、もし新チェーンが呼ばれてしまえば overlayCovering として発火するはずの罠
    private func clippedStraddleSnapshot() -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let container = ElementInfo(ref: 1, type: "other", identifier: "list", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: 230, width: 370, height: 462), depth: 11)
        let target = ElementInfo(ref: 2, type: "clickable", identifier: "target", label: "行",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 16, y: 206, width: 370, height: 38), depth: 12)
        let inside1 = ElementInfo(ref: 3, type: "clickable", identifier: "row3", label: "行",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 16, y: 300, width: 370, height: 56), depth: 12)
        let inside2 = ElementInfo(ref: 4, type: "clickable", identifier: "row4", label: "行",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 16, y: 360, width: 370, height: 56), depth: 12)
        let phantom = ElementInfo(ref: 5, type: "clickable", identifier: "phantom", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 100, y: 200, width: 200, height: 50), depth: 12)
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [container, target, inside1, inside2, phantom],
                                truncatedCount: 0)
    }

    /// 素の tap で overlayCovering が注記に出る
    func testTapCarriesOverlayCoveringAdvisory() async throws {
        let driver = FixedSnapshotDriver(overlayCoveringSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#overlay"), "overlayCovering の注記が出ていない: \(note)")
        XCTAssertTrue(note.contains("instead"), note)
    }

    /// 素の tap で scrolledOut が注記に出る
    func testTapCarriesScrolledOutAdvisory() async throws {
        let driver = FixedSnapshotDriver(scrolledOutSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#scroller"), "scrolledOut の注記が出ていない: \(note)")
        XCTAssertTrue(note.contains("leftover from scrolling"), note)
    }

    /// 長押し(hold>0 = press(ref:) 経路)でも新チェーンが出る
    func testLongPressCarriesOverlayCoveringAdvisory() async throws {
        let driver = FixedSnapshotDriver(overlayCoveringSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target"), duration: 0.5))
        XCTAssertEqual(driver.presses, 1, "長押しは press(ref:) 経路を通るはず")
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#overlay"), "長押しで overlayCovering の注記が出ていない: \(note)")
    }

    /// doubleTap(advisory() 経由)でも scrolledOut が出る
    func testDoubleTapCarriesScrolledOutAdvisory() async throws {
        let driver = FixedSnapshotDriver(scrolledOutSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "doubleTap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#scroller"), "doubleTap で scrolledOut の注記が出ていない: \(note)")
    }

    /// **visibleTapRect で寄せた経路では新チェーンを出さない**(撃つ点が変わるので、
    /// raw frame の中心を前提にした遮蔽の名指しは嘘になる)
    func testVisibleTapRectPathDoesNotCarryTheChain() async throws {
        let driver = FixedSnapshotDriver(clippedStraddleSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("tapped the visible part"), "寄せた注記が出ていない: \(note)")
        XCTAssertFalse(note.contains("covered by"), "寄せた経路で新チェーンが出てはいけない: \(note)")
        XCTAssertFalse(note.contains("outside the visible screen"), note)
    }

    // MARK: - T7: type の既存値注記

    /// 通常欄: **撃つ前に入っていた値だけ**をエコーする。連結後の値は予告しない——
    /// ここでは読み返さないので観測していない値であり、ヒント文字列を `value` に載せる欄
    /// (E2E-CMP の `#field_single` が witness)では外れる。詳細は StepExecutor.readbackTarget
    func testTypeEchoesExistingValueInTheNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false, existingValue: "東京タワー")
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "type", locator: FlowLocator(id: "target"), text: "レストラン"))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("東京タワー"), note)
        XCTAssertFalse(note.contains("東京タワーレストラン"),
                       "観測していない連結後の値を予告している: \(note)")
    }

    /// secureTextField: 既存値の中身は出さず、あることだけを言う
    func testTypeMasksExistingValueForSecureField() async throws {
        let driver = AdvisoryProbeDriver(disabled: false, existingValue: "s3cr3t", secure: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "type", locator: FlowLocator(id: "target"), text: "more"))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("already holds a value"), note)
        XCTAssertFalse(note.contains("s3cr3t"), "秘匿欄の実値が漏れている: \(note)")
    }

    /// 空値なら注記を足さない(毎回付くと意味を失う)
    func testTypeWithNoExistingValueAddsNoNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "type", locator: FlowLocator(id: "target"), text: "hello"))
        XCTAssertNil(outcome.driverFallback, "空値なのに注記が付いた: \(outcome.driverFallback ?? "")")
    }
}

/// **advisoryKind の優先順を等号で固定する**。DSL(`occlusionAdvisory`)と
/// MCP(`RefGuard.overlapWarning`)が両方これを呼ぶので、順序を入れ替える変異・
/// どれか1形を落とす変異のどちらでも、ここか上の occlusionAdvisory 群のテストが落ちる。
/// **各対は両方の条件が同時に成り立つ木で確かめる**(片方だけの木では「たまたま順序が
/// 合っていた」を区別できない)
final class TapAdvisoryKindPriorityTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)

    /// **zeroFrame は offscreen より先**。高さ0(zeroFrame の条件)かつ中心が画面外
    /// (offscreen の条件)という形で、frame の退化を先に言うこと
    func testZeroFrameBeatsOffscreen() {
        let e = ElementInfo(ref: 1, type: "button", identifier: "z", label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 100, y: -1000, width: 40, height: 0), depth: 2)
        XCTAssertNotNil(TapTargetGeometry.offscreenAdvisory(for: e, screen: screen),
                        "この形では offscreen 条件も同時に成り立つこと(対照の前提)")
        guard case .zeroFrame = TapTargetGeometry.advisoryKind(for: e, in: [e], screen: screen) else {
            return XCTFail("zeroFrame が先に勝つべき")
        }
    }

    /// **overlayCovering は missedContent より先**。対象は非対話容器(`other`)で、
    /// 自分の子(小さな画像)は中心を覆わない(missedContent の条件)が、同時に
    /// 後から描かれた別要素が中心を覆う(overlayCovering の条件)。子の有無は
    /// overlayCovering 側の判定に影響しないので、両条件は互いに独立に成立する
    func testOverlayCoveringBeatsMissedContent() {
        let target = ElementInfo(ref: 1, type: "other", identifier: "target", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 2)
        let child = ElementInfo(ref: 2, type: "image", identifier: "child", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 80, y: 80, width: 10, height: 10), depth: 3)
        // **target と同じ矩形にしない**: `occluder` は矩形の完全一致を遮蔽と言わない
        // (積み重なりは stackedRefs の担当なので、ここで同じ矩形にすると occluder が
        // overlay を候補から外し、この対照が overlayCovering を1件も検証しないテストになる)
        let overlay = ElementInfo(ref: 3, type: "clickable", identifier: "overlay", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 30, y: 30, width: 40, height: 40), depth: 2)
        let withOverlay = [target, child, overlay]
        XCTAssertNotNil(TapTargetGeometry.missesItsOwnContent(target, in: withOverlay, screen: screen),
                        "この形では missedContent 条件も同時に成り立つこと(対照の前提)")
        guard case .overlayCovering(let hit) = TapTargetGeometry.advisoryKind(
            for: target, in: withOverlay, screen: screen) else {
            return XCTFail("overlayCovering が先に勝つべき")
        }
        XCTAssertEqual(hit.ref, overlay.ref)
        // 陰性対照: overlay を除くと missedContent が代わりに発火する(条件自体は独立に成立)
        guard case .missedContent(let inner) = TapTargetGeometry.advisoryKind(
            for: target, in: [target, child], screen: screen) else {
            return XCTFail("overlay が無ければ missedContent が発火するはず")
        }
        XCTAssertEqual(inner.ref, child.ref)
    }

    /// **nestedAction は stacked より先**。対象自身が3件の同一矩形(stacked の条件)の1つで、
    /// かつその内側に別アクションの小さな帯を持つ(nestedAction の条件)。同一矩形の相手は
    /// `sameFrame` 除外で overlayCovering には掛からないので、この2つだけが競合する
    func testNestedActionBeatsStacked() {
        let target = ElementInfo(ref: 1, type: "cell", identifier: "row1", label: "行1",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 2)
        let chip = ElementInfo(ref: 2, type: "button", identifier: "chip", label: nil,
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 40, y: 40, width: 20, height: 20), depth: 3)
        let dup2 = ElementInfo(ref: 3, type: "cell", identifier: "row2", label: "行2",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 2)
        let dup3 = ElementInfo(ref: 4, type: "cell", identifier: "row3", label: "行3",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 2)
        let elements = [target, chip, dup2, dup3]
        XCTAssertTrue(OcclusionGeometry.stackedRefs(elements).contains(target.ref),
                     "この形では stacked 条件も同時に成り立つこと(対照の前提)")
        guard case .nestedAction(let nested) = TapTargetGeometry.advisoryKind(
            for: target, in: elements, screen: screen) else {
            return XCTFail("nestedAction が先に勝つべき")
        }
        XCTAssertEqual(nested.ref, chip.ref)
        // 陰性対照: chip を除くと stacked が代わりに発火する
        let withoutChip = [target, dup2, dup3]
        guard case .stacked = TapTargetGeometry.advisoryKind(
            for: target, in: withoutChip, screen: screen) else {
            return XCTFail("chip が無ければ stacked が発火するはず")
        }
    }

    /// **stacked は sliver より先**。同じ細帯(縁で切れたラベル付きタブ)が3件同一矩形に
    /// 積まれた形にすると、stacked と sliver の両条件が同時に成り立つ
    func testStackedBeatsSliver() {
        func sliverShaped(_ ref: Int, _ label: String) -> ElementInfo {
            ElementInfo(ref: ref, type: "tab", identifier: nil, label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 1071, y: 100, width: 9, height: 137), depth: 1)
        }
        let elements = [sliverShaped(1, "サンライズ瀬戸1"), sliverShaped(2, "サンライズ瀬戸2"),
                        sliverShaped(3, "サンライズ瀬戸3")]
        let target = elements[0]
        XCTAssertTrue(TapTargetGeometry.isClippedSliver(target, screen: screen),
                     "この形では sliver 条件も同時に成り立つこと(対照の前提)")
        guard case .stacked = TapTargetGeometry.advisoryKind(
            for: target, in: elements, screen: screen) else {
            return XCTFail("stacked が先に勝つべき")
        }
        // 陰性対照: 2件だけ(stackedFrameMinimum 未満)なら sliver が代わりに発火する
        let onlyTwo = [elements[0], elements[1]]
        guard case .sliver = TapTargetGeometry.advisoryKind(
            for: target, in: onlyTwo, screen: screen) else {
            return XCTFail("stacked の下限を割れば sliver が発火するはず")
        }
    }
}

/// **注記が出るときは解決先を名乗る**(2026-08-21 の受け手報告)。
/// 連鎖セレクタ(`#id||.textField[1]`)や型+順序では、書いた文字列から解決先が読めないので、
/// 「無効だ」と言われてもどの要素の話か分からない —— 容器と入力欄が同じ矩形に重なる画面
/// (Material の TextInputLayout / TextInputEditText)で実際に詰まった。
/// **注記が無いステップには付けない**(通常の出力量を増やさない)
final class TapResolvedTargetNamingTests: XCTestCase {

    private final class TapDriver: AppDriver, @unchecked Sendable {
        let elements: [ElementInfo]
        /// ブリッジ申告のキーボード矩形(2つ目の注記を出すために使う)
        let keyboardFrame: FTRect?
        init(elements: [ElementInfo], keyboardFrame: FTRect? = nil) {
            self.elements = elements
            self.keyboardFrame = keyboardFrame
        }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil,
                             screen: FTRect(x: 0, y: 0, width: 1080, height: 2400),
                             elements: elements, truncatedCount: 0,
                             keyboardFrame: keyboardFrame)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func field(ref: Int, id: String, type: String, enabled: Bool) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: 42, y: 417, width: 996, height: 147), depth: 1)
    }

    /// 無効な要素を叩いたときは「どれを掴んだか」まで出す
    func testNamesTheResolvedTargetWhenAnAdvisoryFires() async throws {
        let driver = TapDriver(elements: [field(ref: 8, id: "txtMailAddress",
                                                type: "other", enabled: false)])
        let executor = StepExecutor(driver: driver)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "txtMailAddress"), timeout: 1)

        let note = await executor.execute(step).driverFallback ?? ""

        XCTAssertTrue(note.contains("resolved to #txtMailAddress (other)"),
                      "解決先と型を名乗ること: \(note)")
        XCTAssertTrue(note.contains("disabled"), note)
    }

    /// **1回だけ**名乗る。**注記が2つ出る木で確かめる** —— 1つしか出ない木だと
    /// 「毎回名乗る」実装でも通ってしまい判定にならない(受け手の実例は
    /// 「無効」+「中心が覆われている」の2つが同時に出ていた)
    func testNamesTheTargetOnlyOnce() async throws {
        let target = field(ref: 8, id: "txtMailAddress", type: "other", enabled: false)
        // キーボードの下 = 座標に依らず言える2つ目の注記(遮蔽判定は木の形に依存するので、
        // ここではブリッジ申告のキーボード矩形を使って確実に2本出す)
        let driver = TapDriver(elements: [target],
                               keyboardFrame: FTRect(x: 0, y: 380, width: 1080, height: 2020))
        let executor = StepExecutor(driver: driver)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "txtMailAddress"), timeout: 1)

        let note = await executor.execute(step).driverFallback ?? ""

        XCTAssertTrue(note.contains("disabled"), "前提: 無効の注記: \(note)")
        XCTAssertTrue(note.contains("keyboard"), "前提: 2つ目の注記も出ること: \(note)")
        XCTAssertEqual(note.components(separatedBy: "resolved to").count - 1, 1, note)
    }

    /// 陰性対照: 注記が無ければ名乗らない(通常のタップの出力は増えない)
    func testStaysSilentWithoutAnAdvisory() async throws {
        let driver = TapDriver(elements: [field(ref: 9, id: "textInputEditText",
                                                type: "textField", enabled: true)])
        let executor = StepExecutor(driver: driver)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "textInputEditText"), timeout: 1)

        let note = await executor.execute(step).driverFallback ?? ""

        XCTAssertFalse(note.contains("resolved to"), note)
    }
}
