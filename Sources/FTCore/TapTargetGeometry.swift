// TapTargetGeometry.swift
// 「その座標を撃つと本当に狙った物へ当たるか」を木の幾何だけで判定する共有ロジック。
// **MCP(RefGuard)と DSL(StepExecutor)の両方が使う** —— 別々に持つと、同じ画面で
// 「危ないタップ」の定義が食い違う(塗り順を PaintOrder へ寄せたのと同じ理由)。
//
// ここにあるのは**幾何と木の形だけ**で、警告するか・拒否するか・注記に留めるかは呼び出し側が決める。

import Foundation

public enum TapTargetGeometry {

    /// 完全包含でも「容器」とみなす面積比の下限。実測: app bar (0,0 1080x290) は画面
    /// (1080x2424) の約 12% で、これを容器扱いすると下に潜った行への遮蔽が丸ごと無警告になる。
    /// 全画面の toolbar/collectionView・`#AdditionalDimmingOverlay` は 100% なので下回らない
    public static let fullScreenContainerAreaRatio = 0.5

    /// タップを受け止める型(ブリッジの型語彙。`other` は含めない)
    public static let interactiveTypes: Set<String> = [
        "clickable", "button", "cell", "link", "switch", "checkBox", "radioButton", "tab",
    ]

    /// outer が inner を完全に含むか(縁の丸め差 1pt は許容)
    public static func contains(_ outer: FTRect, _ inner: FTRect) -> Bool {
        outer.x <= inner.x + 1 && outer.y <= inner.y + 1
            && outer.x + outer.width >= inner.x + inner.width - 1
            && outer.y + outer.height >= inner.y + inner.height - 1
    }

    /// 祖先を**近い順**に(preorder + depth から復元する)
    public static func ancestors(of element: ElementInfo, in elements: [ElementInfo]) -> [ElementInfo] {
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return [] }
        var depth = element.depth
        var result: [ElementInfo] = []
        for ancestor in elements[..<index].reversed() where ancestor.depth < depth {
            result.append(ancestor)
            depth = ancestor.depth
        }
        return result
    }

    /// 自分・祖先・子孫の ref(preorder + depth から復元する)
    public static func lineage(of element: ElementInfo, in elements: [ElementInfo]) -> Set<Int> {
        var result: Set<Int> = [element.ref]
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return result }
        result.formUnion(ancestors(of: element, in: elements).map(\.ref))
        var i = elements.index(after: index)
        while i < elements.endIndex, elements[i].depth > element.depth {
            result.insert(elements[i].ref)
            i = elements.index(after: i)
        }
        return result
    }

    /// 木の並び(preorder + depth)で葉か。**bulk 集約の前提**: 子を持つ要素を1行に畳むと
    /// 子の行だけが親を失って残る
    public static func isLeaf(_ element: ElementInfo, in elements: [ElementInfo]) -> Bool {
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return true }
        let next = elements.index(after: index)
        return next >= elements.endIndex || elements[next].depth <= element.depth
    }

    /// ghost ではないが**別の物に当たったかもしれない**2形の注記。空文字なら心当たり無し。
    ///
    /// ghostWarning と同じ方針で**撃ってから言う**(拒否しない)。木の幾何だけでは
    /// 「本当に描かれているか」を決められないという 2026-08-06 の結論は、この2形にも効く。
    /// **中身のどこでもない点を叩こうとしている**か。対話的でない容器(`other`)で、
    /// 子孫を持つのに**中心がそのどれの上にも無い**とき、タップは背後(地図・背景)へ抜ける。
    ///
    /// 実測(2026-08-07・Google マップ Android): `#layers_fab_button` は全幅 (0,442 1080x157) の
    /// 非 clickable コンテナで、中身は右端の FAB 1つだけ。中心 (540,520) は地図の上にあり、
    /// `ft_tap` は "done" を返しながら**海上の座標にピンを落として place page を開いた**。
    /// 名前が `..._button` で終わるのでエージェントが選びがちな形。
    ///
    /// **子の中心へ寄せる自動補正はしない** —— 黙って別の物を叩くのと同じになる。
    /// 遮蔽でも ghost でも積み重なりでもないので、既存の3つには1つも掛からない
    public static func missesItsOwnContent(_ element: ElementInfo, in elements: [ElementInfo],
                                    screen: FTRect) -> ElementInfo? {
        guard element.type == "other" else { return nil }
        let children = StepExecutor.descendants(of: element, in: elements)
        guard !children.isEmpty else { return nil }
        let cx = element.frame.x + element.frame.width / 2
        let cy = element.frame.y + element.frame.height / 2
        func covers(_ e: ElementInfo) -> Bool {
            e.frame.x <= cx && cx <= e.frame.x + e.frame.width
                && e.frame.y <= cy && cy <= e.frame.y + e.frame.height
        }
        guard !children.contains(where: covers) else { return nil }
        // **囲っている対話要素がタップを受け止めるなら黙る**: 中心が空白でも、外側の
        // 行やカードが clickable なら押した結果は妥当。**画面規模のものは数えない** ——
        // 地図やキャンバスは全画面 clickable で、そこへ抜けること自体が今回の実害
        // (実測: `#business_place_card` の中心は空白だが、包む place card が clickable で
        // 正しく開く。一方 `#layers_fab_button` を包むのは全画面の地図だけだった)
        let screenArea = screen.width * screen.height
        let absorbed = lineage(of: element, in: elements).contains { ref in
            guard ref != element.ref, let ancestor = elements.first(where: { $0.ref == ref }),
                  interactiveTypes.contains(ancestor.type), covers(ancestor) else { return false }
            let area = ancestor.frame.width * ancestor.frame.height
            return screenArea <= 0 || area < screenArea * fullScreenContainerAreaRatio
        }
        guard !absorbed else { return nil }
        // 「代わりにこれを狙え」は**自分の矩形の内側にある子**から選ぶ。木の depth だけで
        // 子孫を採ると、間引きの副作用で**視覚的に無関係な要素**が混ざる
        // (実測: `#search_omnibox_container` の子孫にページ下端のカード束が入っていた)
        return children
            .filter { contains(element.frame, $0.frame) }
            .max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    /// 入れ子の別アクションとみなす面積比の上限。**0.25** は実測で決めた:
    /// 行を丸ごと包み直すだけのラッパー(`#Maps.PlaceTableViewCell` の中の無名 button は 0.99)と、
    /// 行の主ラベル(`#MultiTextView` は 0.31〜0.49 で、押しても行と同じ場所が開く)を外し、
    /// **行の中に別の遷移先を持つ小さな帯**だけを残す値。実アプリのコーパス全数(18枚)に当てて
    /// 発火は1件(`#PinnedItemSection` の中心が `#PinnedTile` に乗る = 真陽性)
    public static let nestedActionAreaRatio = 0.25

    /// **自分の子孫が中心を横取りしている**か。`occluder` は祖先と子孫を除外するので
    /// (親子の重なりは正常な入れ子で、数えると何でも遮蔽になる)、この形を1つも捕まえない。
    ///
    /// 実測(2026-08-09・Apple マップの検索候補): `#Maps.PlaceTableViewCell` (20,138 362x155) の
    /// 中心 (201,215) は、同じセルの中の `#FeaturedInMultipleGuidesContextLineItem`
    /// (80,202 205x18) の内側にある。ref タップは**場所カードではなくガイド一覧を開き**、
    /// 警告は一切出なかった(兄弟の重なりである `#FavoriteButton` × `#TransitDepartureRow` では
    /// 出ていたので、差は「子孫かどうか」だけだった)。
    ///
    /// **対話的な親にだけ言う**: 非対話の容器が中身を外す形は `missesItsOwnContent` の担当で、
    /// あちらは「中心がどの子にも乗らない」= ここと排他。両方に数えられることはない
    public static func nestedActionCoveringCentre(_ element: ElementInfo,
                                                  in elements: [ElementInfo]) -> ElementInfo? {
        guard interactiveTypes.contains(element.type) else { return nil }
        let area = element.frame.width * element.frame.height
        guard area > 0 else { return nil }
        let cx = element.frame.x + element.frame.width / 2
        let cy = element.frame.y + element.frame.height / 2
        return StepExecutor.descendants(of: element, in: elements)
            .filter { child in
                guard interactiveTypes.contains(child.type) else { return false }
                let f = child.frame
                guard f.width * f.height < area * nestedActionAreaRatio else { return false }
                return f.x <= cx && cx <= f.x + f.width && f.y <= cy && cy <= f.y + f.height
            }
            .min { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    /// **スクロール容器の外へ送り出された要素**。返すのはその容器(名指しに使う)。
    ///
    /// `StepExecutor.isOutsideContainer` とは**容器の採り方が違う**: あちらは申告が無い
    /// Compose/Flutter のために「木の並びから容器を推測する」ので、推測が当たらない木では
    /// nil に落ちる。ここは逆に **`scrollable` を申告している祖先だけ**を見る ——
    /// 推測しないぶん取りこぼすが、当たったときは確実で、実アプリのコーパス全数で
    /// タップ対象の誤検知が0件だった(2026-08-09)。
    ///
    /// 実測(Apple マップの場所カード): カードを送ると `#MUScrollableStackView` (0,72 402x802) の
    /// **上へ抜けた行が frame ごと木に残る**(`#PlaceCollectionCell` (16,-169 171x217) 等)。
    /// 一覧では可視の行と見分けが付かず、ref タップは "done" を返して何も起きない
    public static func outsideDeclaredScroller(_ element: ElementInfo,
                                               in elements: [ElementInfo]) -> ElementInfo? {
        guard element.frame.width > 0, element.frame.height > 0,
              let scroller = ancestors(of: element, in: elements)
                  .first(where: { $0.scrollable == true }),
              ScrollGeometry.intersection(element.frame, scroller.frame) == nil,
              hasSiblingsInside(at: element.depth, inside: scroller, in: elements)
        else { return nil }
        return scroller
    }

    /// **祖先を depth から復元するのは、ブリッジが中間ノードを間引くと嘘になる**
    /// (`clippingContainer` が同じ理由で「中に居る兄弟が2つ以上」を要求している)。
    ///
    /// 実測(2026-08-09・Google マップ Android の検索結果): スポンサーカードの本文
    /// (`"5.0 星 (25)"` 等・depth 20〜22)は、カード容器が間引かれた結果、直前に並ぶ
    /// **写真カルーセル `#recycler_view` (0,975 1080x352)・depth 19** の子孫に見える。
    /// 本物の子は写真3枚(depth 24)だけで、本文は容器の外に落ちるため、素の判定では
    /// **10件まとめて「スクロールで抜けた」**になっていた。
    ///
    /// そこで「その depth の兄弟が2つ以上、容器の中に居る」ことを条件にする ——
    /// 間引きで繋がっただけの相手は、その depth の仲間が容器の中に1つも居ない
    static func hasSiblingsInside(at depth: Int, inside scroller: ElementInfo,
                                   in elements: [ElementInfo]) -> Bool {
        StepExecutor.descendants(of: scroller, in: elements)
            .filter { $0.depth == depth
                && ScrollGeometry.intersection($0.frame, scroller.frame) != nil }
            .count >= 2
    }

    /// **撃つ前に言える「たぶん何も起きない/別の物に当たる」**を1文にする。空 = 心当たり無し。
    /// **keyboard を先頭**に合成する(木の遮蔽判定では原理的に拾えず、確度が最も高いため)。
    /// `keyboardFrame` を渡さない呼び出しは従来どおり disabled から始まる。
    ///
    /// 判断はしない —— 呼び出し側が注記に混ぜるか警告にするかを決める。
    /// DSL は**ステップ注記**に混ぜる(失敗にはしない): 無効な要素をわざと叩いて
    /// 「反応しないこと」を確かめる書き方は正当で、`enabledIsFalse` も用意されている。
    ///
    /// 2つとも実測に基づく(2026-08-07):
    /// - `disabled`: 木には印字しているのに操作経路が `enabled` を一度も見ておらず、
    ///   E2E-CMP の契約上「押しても何も起きない」ボタンへ tap/press/doubleTap の3つとも
    ///   無警告で成功を返していた
    /// - 中身外し: `#layers_fab_button`(全幅・中身は右端の FAB だけ)を叩くと、
    ///   中心が地図の上にあるので**海上の座標にピンが落ちて place page が開いた**
    public static func advisory(for element: ElementInfo, in elements: [ElementInfo],
                                screen: FTRect, keyboardFrame: FTRect? = nil) -> String? {
        keyboardCoveredAdvisory(element, keyboardFrame: keyboardFrame)
            ?? disabledAdvisory(for: element)
            ?? offscreenAdvisory(for: element, screen: screen)
            ?? missedContentAdvisory(for: element, in: elements, screen: screen)
    }

    /// 「そもそも無効」。**撃つ座標に依らない**ので、どの経路でも同じことが言える
    public static func disabledAdvisory(for element: ElementInfo) -> String? {
        element.enabled ? nil : "the target is disabled, so this almost certainly did nothing"
    }

    /// 「中心が画面の外」。ウィンドウ外のタッチは hitTest に乗らず**黙って落ちる**ので、
    /// frame の中心を撃つ経路では確実に空振りになる。これも**frame の中心を撃つときにしか
    /// 言えない**(`visibleTapRect` で見えている部分へ寄せたなら撃つ点は画面内)。
    ///
    /// 実測(2026-08-08・Compose iOS のカレンダー): ヘッダ裏へスクロールで抜けた
    /// `#slot_07` (0,-46 402x56) — 中心 y=-18 — への ref タップが "done" を返し、
    /// 画面は 1px も変わらなかった。スクロール直後の木は縁の外の要素を frame ごと残すので、
    /// エージェントが古い位置感覚のまま撃つとこの形になる
    /// 画面の縁の丸め誤差を「画面外」と言わないための猶予(pt/px)。
    /// 実測(Apple マップの ios-home): 下端バーの `#SubtitleLabel` は中心が 874.3 と
    /// screen.height=874 を **0.3pt** だけ超える —— 見えているラベルに「ほぼ確実に空振り」は嘘
    public static let offscreenCentreTolerance = 2.0

    public static func offscreenAdvisory(for element: ElementInfo, screen: FTRect) -> String? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        let cx = element.frame.x + element.frame.width / 2
        let cy = element.frame.y + element.frame.height / 2
        let pad = offscreenCentreTolerance
        let inside = cx >= screen.x - pad && cx <= screen.x + screen.width + pad
            && cy >= screen.y - pad && cy <= screen.y + screen.height + pad
        guard !inside else { return nil }
        return "its centre (\(Int(cx)), \(Int(cy))) is outside the visible screen,"
            + " so this almost certainly did nothing"
    }

    /// 「中心が中身のどこにも乗らない」。**frame の中心を撃つときにしか言えない** ——
    /// 呼び出し側が見えている部分の中心へ寄せる(`StepExecutor.visibleTapRect`)場合、
    /// 撃つ点が変わるので「背後へ抜けた」は嘘になる(2026-08-08 のレビュー)
    public static func missedContentAdvisory(for element: ElementInfo, in elements: [ElementInfo],
                                             screen: FTRect) -> String? {
        guard let inner = missesItsOwnContent(element, in: elements, screen: screen) else {
            return nil
        }
        let name = inner.identifier.map { "#\($0)" } ?? inner.label.map { "\"\($0)\"" } ?? inner.type
        return "the target is not interactive and its centre is not over any of its own content,"
            + " so the touch went to whatever is behind it (aim at \(name) instead)"
    }

    /// 「中心がソフトキーボードの下」。木からは判定できない(キーボードはスナップショットの
    /// 対象外)ので、ブリッジが申告する `keyboardFrame` でだけ言える。**警告のみ**(新しい検知は
    /// 拒否でなく警告から。start-new-detections-as-warnings)。
    ///
    /// 実測(2026-08-08・iOS): キーボード下の候補行 ref タップが警告なしで顔文字キーに当たった。
    /// ツリー内の inputView は子孫が全部除外された空葉になり、既存の空葉コンテナ除外
    /// (`RefGuard.isBlankLeafContainer`。誤検知対策)で遮蔽候補から外れる —— だからツリー由来の
    /// 遮蔽判定では原理的に拾えない
    public static func keyboardCoveredAdvisory(_ element: ElementInfo,
                                               keyboardFrame: FTRect?) -> String? {
        guard let keyboardFrame else { return nil }
        let cx = element.frame.centerX
        let cy = element.frame.centerY
        guard cx >= keyboardFrame.x, cx <= keyboardFrame.x + keyboardFrame.width,
              cy >= keyboardFrame.y, cy <= keyboardFrame.y + keyboardFrame.height else { return nil }
        return "its centre (\(Int(cx)), \(Int(cy))) is under the soft keyboard — the tap will land"
            + " on the keyboard, not this element. Dismiss the keyboard first (pressEnter, or tap"
            + " outside the field), or scroll the element clear of it"
    }

    /// 容器の縁で細い帯に切れた要素(ラベルは付いているが実際には掴めないほど狭い)。
    /// 実測(2026-08-08・Apple マップ): 右端で幅9pxに切れたタブ「サンライズ瀬戸」(9x137)。
    /// アイコン(9x13 等)は縦横比条件(細い辺の対辺が `sliverLongDimension` 未満)で除外される
    public static let sliverThinDimension: Double = 10
    public static let sliverLongDimension: Double = 30

    public static func isClippedSliver(_ element: ElementInfo) -> Bool {
        let label = FlowMatchMode.stripZeroWidthCharacters(element.label ?? "")
        guard label.count >= 2 else { return false }
        let w = element.frame.width
        let h = element.frame.height
        return (w <= sliverThinDimension && h >= sliverLongDimension)
            || (h <= sliverThinDimension && w >= sliverLongDimension)
    }
}
