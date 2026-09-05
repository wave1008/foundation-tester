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
    /// タップ対象の誤検知が0件だった。
    ///
    /// 実測(Apple マップの場所カード): カードを送ると `#MUScrollableStackView` (0,72 402x802) の
    /// **上へ抜けた行が frame ごと木に残る**(`#PlaceCollectionCell` (16,-169 171x217) 等)。
    /// 一覧では可視の行と見分けが付かず、ref タップは "done" を返して何も起きない
    ///
    /// **容器の外側の帯に固定された chrome は除く**(`StepExecutor.isChromePinnedOutside` の doc)。
    /// ここで見つかる `scroller` は定義上 `scrollable == true` を申告しているので、
    /// `containerIsViewport` は常に true(推測容器と違い viewport かどうかで悩む余地が無い)
    public static func outsideDeclaredScroller(_ element: ElementInfo,
                                               in elements: [ElementInfo],
                                               screen: FTRect) -> ElementInfo? {
        guard element.frame.width > 0, element.frame.height > 0,
              let scroller = ancestors(of: element, in: elements)
                  .first(where: { $0.scrollable == true }),
              ScrollGeometry.intersection(element.frame, scroller.frame) == nil,
              hasSiblingsInside(at: element.depth, inside: scroller, in: elements),
              !StepExecutor.isChromePinnedOutside(element, container: scroller.frame,
                                                  containerIsViewport: true,
                                                  in: elements, screen: screen)
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

    /// **プラットフォームに「引き当てられない」と言われて意味がある要素か**。
    ///
    /// ライブのクエリ(`GET /hittable`)は identifier / label + frame で**一意に**引き当てるので、
    /// **名前を持たない容器は覆いが無くても普通に引き当てられない** —— 実測(2026-08-28・
    /// 覆いの無い iOS 設定 root)で 53 要素中 12 件が unresolved だった。そのまま信号にすると
    /// 誤検知だらけになる。
    ///
    /// 操作可能型かつ名前を持つものに絞ると分離する: **13 画面・111 件で誤検知 0** /
    /// アプリスイッチャーで覆うと同じ画面の **12/12 が unresolvable**。
    /// 型の集合は `BridgeSnapshotThinning.operableTypes` の1箇所を使う(2つ目を作らない)
    public static func platformShouldResolve(_ element: ElementInfo) -> Bool {
        guard BridgeSnapshotThinning.operableTypes.contains(element.type) else { return false }
        let name = (element.identifier ?? "") + (element.label ?? "")
        return !FlowMatchMode.normalizeInvisibleCharacters(name).isEmpty
    }

    /// **撃つ前に言える「たぶん何も起きない/別の物に当たる」**を1文にする。空 = 心当たり無し。
    /// **申告由来(keyboard → overlay window)を先頭**に合成する —— どちらも木の遮蔽判定では
    /// 原理的に拾えず(覆っている実体が `elements` に載っていない)、確度が最も高いため。
    /// `keyboardFrame` を渡さない呼び出しは従来どおり disabled から始まる。
    ///
    /// 判断はしない —— 呼び出し側が注記に混ぜるか警告にするかを決める。
    /// DSL は**ステップ注記**に混ぜる(失敗にはしない): 無効な要素をわざと叩いて
    /// 「反応しないこと」を確かめる書き方は正当で、`enabledIsFalse` も用意されている。
    ///
    /// keyboard/disabled は座標に依らず言えるので先頭に残す。座標に依る残り(zero-frame〜sliver)は
    /// `occlusionAdvisory` へ委ねる(実測は各判定関数の doc を参照)
    /// **`overlayWindows` に既定値を置かない** —— 呼び忘れはコンパイルで止める。
    /// 申告が無い経路(iOS・旧ブリッジ)は呼び出し側が `.none` を明示的に渡す
    public static func advisory(for element: ElementInfo, in elements: [ElementInfo],
                                screen: FTRect,
                                keyboardOcclusion: KeyboardOcclusion,
                                overlayWindows: OverlayWindowOcclusion,
                                isAndroid: Bool) -> String? {
        keyboardOcclusion.advisory(for: element)
            ?? overlayWindows.advisory(for: element)
            ?? disabledAdvisory(for: element)
            ?? occlusionAdvisory(for: element, in: elements, screen: screen, isAndroid: isAndroid)
    }

    /// **座標に依る警告の優先順チェーン、当たった形**(強い事実から先に、最初の1件だけ)。
    /// `occlusionAdvisory`(DSL)と `RefGuard.overlapWarning`(MCP)は**両方これを呼ぶ**
    /// —— 順序と当たり判定はここに1箇所だけ置き、文言は呼び出し側がそれぞれ持つ
    /// (同じ判定に対して言い回しが違うため。詳細は各呼び出し側)
    public enum TapAdvisoryKind {
        case zeroFrame
        case offscreen
        case scrolledOut(ElementInfo)
        case overlayCovering(ElementInfo)
        case missedContent(ElementInfo)
        case nestedAction(ElementInfo)
        case stacked
        case clippedByContainer(ElementInfo)
        case sliver
    }

    /// **座標に依る警告の優先順チェーン**(強い事実から先に、最初の1件だけ)。
    /// 順序: zeroFrame → offscreen → scrolledOut → overlayCovering → missedContent →
    /// nested → stacked → clippedByContainer → sliver。**frame の中心を撃つ経路でしか言えない**
    /// (`StepExecutor.visibleTapRect` で寄せた場合は呼ばない —— 撃つ点が変わるので嘘になる)
    public static func advisoryKind(for element: ElementInfo, in elements: [ElementInfo],
                                    screen: FTRect) -> TapAdvisoryKind? {
        if element.frame.width <= 0 || element.frame.height <= 0 { return .zeroFrame }
        if offscreenAdvisory(for: element, screen: screen) != nil { return .offscreen }
        if let scroller = outsideDeclaredScroller(element, in: elements, screen: screen) {
            return .scrolledOut(scroller)
        }
        if let over = OcclusionGeometry.overlayCovering(element, in: elements, screen: screen) {
            return .overlayCovering(over)
        }
        if let inner = missesItsOwnContent(element, in: elements, screen: screen) {
            return .missedContent(inner)
        }
        if let nested = nestedActionCoveringCentre(element, in: elements) {
            return .nestedAction(nested)
        }
        if OcclusionGeometry.stackedRefs(elements).contains(element.ref) { return .stacked }
        if let container = clippedAtContainerEdge(element, in: elements) {
            return .clippedByContainer(container)
        }
        if isClippedSliver(element, screen: screen) { return .sliver }
        return nil
    }

    /// 縁で切り詰められた高さの実質的な下限差(pt/dp)。**4pt 以下は丸め・padding の差**として
    /// 広さの根拠にしない(実測: 実機 iPhone 13 の witness で同型ボタン間の丸め差は
    /// 数pt 未満、48→43 の 5pt が有意)
    static let containerEdgeShortfallFloor: Double = 4

    /// 「行の高さ」を借りてよい兄弟の幅の比(両方向)。同じ列に並ぶ行は幅が揃う(実測: ログアウト
    /// 358=358・Android 設定行 1080=1080)が、幅 22 の「広告」バッジは同じ depth の
    /// リンク(幅 41〜176)と高さを比べる意味が無い(ios-browser_nationwide で誤検知になった形)
    static let sameRowWidthRatio: Double = 0.8

    /// **容器の縁で切り詰められたタップ対象**(返すのは容器 = 名指し用)。
    ///
    /// 実測(2026-08-31・実機 iPhone 13, 390x844, XCUITest, Compose): アカウント画面の
    /// `#screen_account` (0,47 390x683) の下端で `button "ログアウト" id=btn_logout` が
    /// 43pt(スクロール前は 48pt)しか報告されない —— 同じ画面の他のボタンは56/48pt。
    /// 中心 (195,708)・(195,725) いずれを撃っても何も起きなかった(ブリッジは frame を
    /// **容器で切ってから**送るので、overflow していた分の座標はどこにも残らず、
    /// `isClippedByViewport` も `straddleJump` も既存の遮蔽判定も1つも発火しない)。
    ///
    /// **「縁が一致 + 高さ不足」でしか判定できない**(overflow を直接見る手が無い)。
    /// 高さ不足の根拠(shortfall witness)は2通り: ⒜ 同じ depth・同じ型の兄弟が2件以上、
    /// 容器の中に収まっていて自分より `containerEdgeShortfallFloor` を超えて高い
    /// (「本来の行の高さ」を他の行から推測する)/ ⒝ 子孫のラベルが同じ縁で
    /// `StepExecutor.minimumVisibleTapExtent` 未満に潰れている(実測: `#btn_save` (16,759 358x48)
    /// の中の staticText "保存" (181,755 28x3) — 行自体は普通の高さでも中の文字だけが
    /// 縁で潰れる形。⒜ が使えない)。
    ///
    /// **警告専用**(新しい検知は拒否でなく警告から): 撃つのは止めない
    static func clippedAtContainerEdge(_ element: ElementInfo,
                                       in elements: [ElementInfo]) -> ElementInfo? {
        guard platformShouldResolve(element) else { return nil }
        // **容器は「要素を幾何的に含む祖先」を近い順に**(`StepExecutor.clippingContainer` は
        // 使わない): あちらの「直前で depth が浅い要素 = 親」の近似は、平坦化された Compose の木で
        // 直前の見出しラベル(実測: `staticText "アカウント"` d11・95x22)を親と誤認して nil を返す。
        // 含んでいない祖先は縁の一致を論じる相手ではない
        let candidates = ancestors(of: element, in: elements).filter {
            $0.frame.width > 0 && $0.frame.height > 0 && contains($0.frame, element.frame)
        }
        for container in candidates
        where clippedAtEdge(of: container.frame, element: element, in: elements) {
            return container
        }
        return nil
    }

    private static func clippedAtEdge(of containerFrame: FTRect, element: ElementInfo,
                                      in elements: [ElementInfo]) -> Bool {
        let elementBottom = element.frame.y + element.frame.height
        let containerBottom = containerFrame.y + containerFrame.height
        let atBottom = abs(elementBottom - containerBottom) <= 1
        let atTop = abs(element.frame.y - containerFrame.y) <= 1
        guard atBottom || atTop else { return false }

        let taller = elements.filter { sibling in
            sibling.ref != element.ref && sibling.depth == element.depth
                && sibling.type == element.type && contains(containerFrame, sibling.frame)
                && sibling.frame.height > element.frame.height + containerEdgeShortfallFloor
                && sameRowWidth(sibling.frame.width, element.frame.width)
        }
        if taller.count >= 2 { return true }

        let tol = 1.0
        return StepExecutor.descendants(of: element, in: elements).contains { child in
            guard let label = child.label,
                  !FlowMatchMode.normalizeInvisibleCharacters(label).isEmpty,
                  child.frame.height < StepExecutor.minimumVisibleTapExtent,
                  child.frame.x >= element.frame.x - tol,
                  child.frame.x + child.frame.width <= element.frame.x + element.frame.width + tol
            else { return false }
            let childBottom = child.frame.y + child.frame.height
            return (atBottom && abs(childBottom - containerBottom) <= 1)
                || (atTop && abs(child.frame.y - containerFrame.y) <= 1)
        }
    }

    static func sameRowWidth(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return false }
        return min(a, b) / max(a, b) >= sameRowWidthRatio
    }

    /// `clippedByContainer` の文言専用: 当たった縁が下端か(判定自体は
    /// `clippedAtContainerEdge` で確定済みなので、ここは表示のための再計算)
    public static func isClippedAtBottomEdge(_ element: ElementInfo, container: ElementInfo) -> Bool {
        abs((element.frame.y + element.frame.height)
            - (container.frame.y + container.frame.height)) <= 1
    }

    /// **DSL 用の文言**(ステップ注記なので主語は "the target")。`advisoryKind` の kind ごとに
    /// 写すだけで、判定そのものはしない
    public static func occlusionAdvisory(for element: ElementInfo, in elements: [ElementInfo],
                                         screen: FTRect, isAndroid: Bool) -> String? {
        guard let kind = advisoryKind(for: element, in: elements, screen: screen) else { return nil }
        switch kind {
        case .zeroFrame:
            return "its reported frame has zero width/height — the tap may land on whatever"
                + " is at that point"
        case .offscreen:
            return offscreenAdvisory(for: element, screen: screen)
        case .scrolledOut(let scroller):
            return "the target is reported entirely outside \(describe(scroller)), the scroll"
                + " container it belongs to — it is a leftover from scrolling, not what is"
                + " currently drawn there"
        case .overlayCovering(let over):
            return "the target's centre is covered by \(describe(over)), so this may have hit"
                + " \(describe(over)) instead"
        case .missedContent:
            return missedContentAdvisory(for: element, in: elements, screen: screen)
        case .nestedAction(let nested):
            return "\(describe(nested)) sits inside the target and covers its centre, so this"
                + " may have triggered \(describe(nested)) instead"
        case .stacked:
            // **「完全一致」と断定しない**: 判定は矩形の完全一致に加えて
            // 「原点だけが同じで大きさが違う」形も見るようになったので、断定すると
            // 広げた分について嘘になる(実アプリのフィードは行の高さがまちまち)
            return "the target is stacked on the same spot as other elements, so at most one of"
                + " them is really drawn there — the rest are clamped leftovers"
        case .clippedByContainer(let container):
            let edge = isClippedAtBottomEdge(element, container: container) ? "bottom" : "top"
            let h = Int(element.frame.height.rounded())
            if isAndroid {
                return "the target is cut off at the \(edge) edge of \(describe(container)) — only"
                    + " \(h) of its height is drawn (px), but on Android the visible part is"
                    + " normally still tappable at its visible centre, so the tap most likely hit"
                    + " the target. Scroll it fully into view first if the result looks wrong"
            }
            return "the target is cut off at the \(edge) edge of \(describe(container)) — only"
                + " \(h) of its height is drawn (pt on iOS / px on Android), so the tap may land on"
                + " whatever is drawn there instead"
                + " of the target. Scroll it fully into view first"
        case .sliver:
            return "the target is clipped to a thin sliver at the edge of its container —"
                + " it is narrower than it looks and the tap may miss"
        }
    }

    /// 人が読める名指し(`#id` があればそれ、無ければ型 + ラベル)。MCP(`RefGuard.describe`)は
    /// ここへの転送。ラベルはゼロ幅文字を除いて比較と揃える

    /// **上のクロムの下へスクロールで潜っている疑い**があるか(= `AppDriver.hittable` を
    /// 聞きに行くゲート)。**警告そのものではない** —— ここは粗くてよく、断定は
    /// プラットフォームのヒットテストに委ねる。
    ///
    /// 動機(2026-08-14 実測・iOS カレンダーの月表示): 前月の行が y=47 に報告され、
    /// ナビゲーションバー(y=61..106)の `#BackButton` が中心を覆っているのに、
    /// **ナビバーは木の前にある**ので `PaintOrder.drawnAbove` が false になり遮蔽として
    /// 名指しされない。`ft_tap` は警告ゼロで成功を返し、実際には戻るボタンが押されて
    /// 画面が変わった(**沈黙の誤操作**)。
    ///
    /// **iOS だけに掛ける**(`z` を持たない木だけ)。Android は塗り順が実測で採れていて
    /// `drawnAbove` が権威なので、黙っているのが正しい判断であり、そもそも聞く先も無い。
    /// 実測でも Android だけで32件鳴っていた(`and-place_expanded` 17・`and-results` 15)。
    ///
    /// **条件は5つ**: ⑴ 木が z を持たない ⑵ 現状の遮蔽判定が黙っている
    /// ⑶ victim がスクロール容器の中 ⑷ 中心を覆う相手が居て、自分の子孫でも
    /// 自分を丸ごと収める相手でもなく、**木の順序ではそれが下**にある(= 木では前後を
    /// 決められない当のケース)⑸ その相手が**画面の縁の帯に居る**(= chrome)。
    ///
    /// **費用は固定コーパスで測る**(発火した要素をタップしたときだけ 72〜146ms の照会を払う):
    /// 3094 要素中 82 件 = 2.7%(2026-09-01)。⑷ を「容器の外」にしていた頃は 14 件だったが、
    /// その条件は sticky ヘッダの形を**構造的に**取りこぼしていた(doc の実測)
    public static func suspectedHiddenUnderChrome(_ element: ElementInfo,
                                                  in elements: [ElementInfo],
                                                  screen: FTRect) -> Bool {
        // ⑴ z があるならそれが権威(Android)。聞く必要が無い
        guard elements.allSatisfy({ $0.z == nil }) else { return false }
        // ⑵ 既に遮蔽として名指しできているなら、この経路は要らない
        guard OcclusionGeometry.overlayCovering(element, in: elements, screen: screen) == nil
        else { return false }
        // ⑶ victim がスクロール容器の中(= スクロールで潜り得る位置に居る)
        guard ancestors(of: element, in: elements).contains(where: { $0.scrollable == true })
        else { return false }
        let cx = element.frame.x + element.frame.width / 2
        let cy = element.frame.y + element.frame.height / 2
        let inner = Set(StepExecutor.descendants(of: element, in: elements).map(\.ref))
        // ⑷ 中心を覆う相手が居て、**木の順序ではそれが下**にあること(クランプ残骸は
        //    「描かれていない」ので数えない)。子孫と、**自分を丸ごと収める相手**は
        //    普通の入れ子なので除く。
        //
        //    **「容器の外に居る相手」では拾えない**(2026-09-01・実機 iPhone 13 で実測):
        //    sticky ヘッダは victim と**同じ root scrollView の中**に居る(ヘッダ depth 10 /
        //    victim depth 12 / scrollView depth 7)。検索結果を送ると `#btn_wishlist_…` が
        //    (332,85) と報告されるがヘッダの下に潜っており、ref タップは警告ゼロで
        //    「クリア」ボタンに当たって検索語を消した。SwiftUI/Compose の sticky ヘッダは
        //    容器の内側に居るのが普通なので、外という条件ではこの形が丸ごと落ちる。
        //    **系譜で除いてもいけない**: 平坦な木では depth からの祖先復元がこの欄を
        //    victim の「親」にしてしまう(実際には収めていない)。収めているかは幾何で見る。
        //
        //    代わりに `PaintOrder.drawnAbove` が false であることを条件にする ——
        //    ⑵ を通ってここへ来た時点で「木の順序では下にある相手が中心を覆っている」形しか
        //    残っておらず、それは**木では手前/奥を決められない**当のケース。断定はしない
        return elements.contains { other in
            other.ref != element.ref && !inner.contains(other.ref)
                && !contains(other.frame, element.frame)
                && pinnedNearScreenEdge(other, screen: screen)
                && other.frame.x <= cx && cx <= other.frame.x + other.frame.width
                && other.frame.y <= cy && cy <= other.frame.y + other.frame.height
                && !PaintOrder.drawnAbove(other, element)
                && !OcclusionGeometry.isOriginClamped(other, in: elements)
        }
    }

    /// 画面の縁に貼り付いた帯(= chrome)とみなす幅。画面高に対する比。
    ///
    /// 根拠: iOS のステータス+ナビゲーションバーは最大 106pt(844pt 画面の 12.6%)、
    /// 下部のタブバー+セーフエリアは実測 100pt(11.8%)。0.2 はその 1.7 倍の余裕を見た値。
    /// **尽きたとき**(画面のもっと内側に貼り付くヘッダで見逃す)は、数字を上げる前に
    /// 「貼り付いているか」を木から言える材料(スクロールしても動かない、等)を探すこと ——
    /// 上げるほど、ただ重なっているだけの兄弟にヒットテストを払い始める
    static let chromeBandRatio: Double = 0.2

    /// 覆っている相手が**画面の縁の帯に居る**か。chrome(バー・sticky ヘッダ)は画面に固定される
    /// ので、この条件が「ただ重なっている兄弟」と分ける。**これが無いと、商品写真の上に重ねた
    /// お気に入りボタンのような普通の重なりまで毎回ヒットテストを払う**(2026-09-01 実測の木で
    /// カード内のハート4件が該当した)
    static func pinnedNearScreenEdge(_ element: ElementInfo, screen: FTRect) -> Bool {
        guard screen.height > 0 else { return false }
        let band = screen.height * chromeBandRatio
        return element.frame.y <= screen.y + band
            || element.frame.y + element.frame.height >= screen.y + screen.height - band
    }

    // MARK: - type の宛先

    /// **ブリッジのソース集合には置かない**(TypeReadback.swift はランナーが
    /// コンパイルするので、ホスト専用の関数を足すと dylib に無駄が入り指紋ゲートが鳴る)
    /// **入力欄でないものへ打とうとしている**ときの警告(内側の入力欄を名指しする)。
    ///
    /// 実測(2026-08-14・iOS ヘルスケアの初期設定・Simulator): 行は
    /// `clickable id=…HeightEntry` が「姓/名/身長…」のラベルと入力欄を包む形で、**id を持つのは
    /// 包み側だけ**(欄は無ラベル・プレースホルダが5つとも "オプション")。素直に
    /// `type '#…HeightEntry' '170'` と書くと **ok が返るのに欄の値は "168 cm"** になった ——
    /// 行タップでホイールピッカーが開き、要求した文字とは無関係な値が確定していた。
    ///
    /// **検証が両側とも空になる**のが原因: ホスト側の読み返しは
    /// 「`!verifiesTypedText` かつ対象が入力型」でしか走らず(StepExecutor)、xcuitest は
    /// 自前検証を名乗るので前段で外れる。そのランナーの検証も、値を持たない包み要素に対しては
    /// 何とも突き合わせられない。
    ///
    /// **内側に入力欄がちょうど1つあるときだけ**言う(0個 = そもそも入力欄でない可能性が高く、
    /// Compose のように型が `clickable` で報告される本物の欄を誤って責める。2個以上 = どれを
    /// 指すべきか言えない)。**警告であって拒否ではない** —— 包みへ打って通っている既存の
    /// 書き方を壊さない
    public static func nonInputTypeTargetNote(_ target: ElementInfo,
                                          in elements: [ElementInfo]) -> String? {
        guard !TypeReadback.isTextInput(target) else { return nil }
        guard let index = elements.firstIndex(where: { $0.ref == target.ref }) else { return nil }
        var inner: [ElementInfo] = []
        var cursor = elements.index(after: index)
        while cursor < elements.endIndex, elements[cursor].depth > target.depth {
            if TypeReadback.isTextInput(elements[cursor]) { inner.append(elements[cursor]) }
            cursor = elements.index(after: cursor)
        }
        guard inner.count == 1, let field = inner.first else { return nil }
        // **書ける形で名指しする**(2026-08-14 の実画面で判明): 内側の欄は無ラベル・無 id の
        // ことが多く、素の `describe` だと "textField" としか言えない —— 同型が5つ並ぶ画面では
        // 選べないので助言にならない。包み側の id があればスコープ記法、無ければ ref を出す。
        // **id の記法エスケープは `FTSelector.serialize` に委ねる** —— 手で
        // `"#\(id)"` と組み立てると、id が(稀だが)`*` で始まる/終わるとき `#` 短縮形は
        // ワイルドカードに化ける(`FTSelector.idToken` の規約)。唯一の正しい変換元を通す
        let how: String
        if let id = target.identifier, !id.isEmpty {
            how = "\(FTSelector.serialize(FlowLocator(id: id))) >> .\(field.type)"
        } else {
            how = "ref \(field.ref)"
        }
        return "the target is a \(target.type), not a text field — typing into a container relies"
            + " on focus landing on the field inside it, which is not guaranteed (the value can"
            + " end up something you did not type). Target the field itself: \(how)"
    }

    /// **人が読む名指しであって、セレクタとして貼れる保証はしない**。
    /// `#id` はそのまま貼れることが多いが、ラベル側は `型 "ラベル"` という複合表示で、
    /// 記法として読まれる先頭文字(`#`/`.` 等)のエスケープも通していない —— ここを直すなら
    /// `SelectorNaming` を使う経路(MCP の graded セレクタ)へ寄せるべきで、この関数は
    /// あくまで「どれの話をしているか」を短く言うためのもの
    /// **申告が無い木でキーボードの帯を推定する**(送る判断専用)。
    /// `KeyboardOcclusion` は「申告が無い = キーボード無し」の意味を守る(警告の意味を
    /// 変えないため)。しかしランナーは `elementType == .keyboard` のノードでしか申告せず、
    /// キーボードが `other id=inputView` として出る画面がある(E2E-iOS の UIKit 入力で実測:
    /// `[17] other id=inputView (0,573 402x301)`)。そこで**送る判断のときだけ** chrome から
    /// 推定する —— 送った結果は呼び手が撮り直して再判定するので、外れても撃つ前に戻せる。
    ///
    /// **画面の下端に接している帯だけ**採る(同名要素が画面の別の場所にあると矩形が暴発する。
    /// `effectiveKeyboardFrame` の同名 chrome の扱いと同じ警戒)
    public static func keyboardBandFromChrome(in elements: [ElementInfo], screen: FTRect,
                                              tolerance: Double = 4) -> FTRect? {
        let chrome = elements.filter {
            guard let id = $0.identifier else { return false }
            return keyboardChromeIdentifiers.contains(id)
        }
        guard let first = chrome.first else { return nil }
        let minX = chrome.reduce(first.frame.x) { min($0, $1.frame.x) }
        let minY = chrome.reduce(first.frame.y) { min($0, $1.frame.y) }
        let maxX = chrome.reduce(first.frame.x + first.frame.width) {
            max($0, $1.frame.x + $1.frame.width)
        }
        let maxY = chrome.reduce(first.frame.y + first.frame.height) {
            max($0, $1.frame.y + $1.frame.height)
        }
        guard maxY >= screen.y + screen.height - tolerance else { return nil }
        return FTRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// **送るときに指を当てる領域**(覆いを避けた容器の残り)。
    /// `StepExecutor.dragGesture` は容器の下端付近から指を動かし始めるので、容器をそのまま
    /// 渡すと**覆いの上をなぞる**ことになり何も動かない(2026-08-27 に実測: キーボードが
    /// 573..874 を占める画面で、容器 117..817 の下端付近 712 から始まっていた)。
    /// 下側の帯なら覆いの上、上側の帯なら覆いの下を返す。ドラッグに足りない高さなら nil
    public static func uncoverDragArea(container: FTRect, cover: FTRect,
                                       minimumHeight: Double = 120) -> FTRect? {
        let containerBottom = container.y + container.height
        let coverBottom = cover.y + cover.height
        let area: FTRect
        if cover.y > container.y + container.height / 2 {
            area = FTRect(x: container.x, y: container.y,
                          width: container.width, height: cover.y - container.y)
        } else {
            area = FTRect(x: container.x, y: coverBottom,
                          width: container.width, height: containerBottom - coverBottom)
        }
        return area.height >= minimumHeight ? area : nil
    }

    /// `advisoryKind` が `.overlayCovering` を選んだときの覆いだけを返す薄い口。
    /// **チェーンの優先順を迂回しない**ため、直接 `OcclusionGeometry.overlayCovering` を
    /// 呼ばずにここを通す(zero-frame・画面外・容器外が先に当たる形では nil)
    public static func overlayCoveringForUncover(_ element: ElementInfo, in elements: [ElementInfo],
                                                 screen: FTRect) -> ElementInfo? {
        guard case .overlayCovering(let over)? = advisoryKind(for: element, in: elements,
                                                              screen: screen) else { return nil }
        return over
    }

    /// **覆いを1回のスクロールで外せるか**(外せるなら送る量。`StepExecutor.dragGesture` の
    /// jump 規約 = 正なら指を上へ = 対象は画面の上へ動く)。
    ///
    /// 対象にできるのは「容器の縁に貼り付いた**帯**が中心を覆っている」形だけ
    /// —— タブバー・下部の固定ボタン・上部のナビゲーションバーで、**実アプリで頻出**
    /// (2026-08-27 に受け手の SUT の 4.7 インチ実機で7本が巻き添えで落ちた: 画面下端の
    /// ログアウトがタブバーに潜り、タップがタブ「カート」に当たっていた)。
    ///
    /// 次の3つは**送っても外せない**ので nil を返す(呼び手は従来どおり警告付きで撃つ):
    /// - 覆いが**操作可能でない**(暗幕・装飾)—— 送っても同じ物が付いてくることが多く、
    ///   「別の物に当たる」実害も薄い
    /// - 覆いが**容器の半分以上**を占める(全画面のモーダル。送っても外に出ない)
    /// - 覆いが対象の**上下どちらとも言えない**(横方向の重なり・中心を跨ぐ)
    ///
    /// `minimumJump` は `dragGesture` が 50pt 未満のドラッグを捨てるため(0.9 掛けも入る)。
    /// **足りない分を切り上げて送る**のは、送りすぎても呼び手が撮り直して再判定するから。
    public static func uncoverScrollJump(target: ElementInfo, coveredBy over: ElementInfo,
                                         container: FTRect,
                                         minimumJump: Double = 60, margin: Double = 8) -> Double? {
        // 操作可能でない覆い(暗幕・装飾)は送っても実害が薄く、送っても同じ物が付いてくる
        guard BridgeSnapshotThinning.operableTypes.contains(over.type) else { return nil }
        return uncoverScrollJump(target: target, coveredBy: over.frame, container: container,
                                 minimumJump: minimumJump, margin: margin)
    }

    /// 覆いを**矩形**で渡す版。ソフトキーボードのように木の要素として渡せない覆い用
    /// (`KeyboardOcclusion.frame`)。操作可能かの判定は呼び手の責務 —— キーボードは
    /// 常にタッチを飲むので、呼び手はその判定を持たない
    public static func uncoverScrollJump(target: ElementInfo, coveredBy over: FTRect,
                                         container: FTRect,
                                         minimumJump: Double = 60, margin: Double = 8) -> Double? {
        guard container.height > 0 else { return nil }
        guard over.height < container.height / 2 else { return nil }
        // **どちら向きに送るかは「覆いが容器の中心線のどちら側にあるか」で決まる**。
        // 「覆いが対象の上か下か」では決まらない —— 中心を覆っている以上、覆いの矩形は
        // 必ず対象の中心を含むので、上下どちらの比較も成り立たない(最初の実装の誤り)。
        // **「容器の縁に接しているか」でも決まらない** —— タブバーの下端は
        // セーフエリアぶん内側にあり、内容を潜らせた容器の下端とは揃わない
        // (2026-08-27 に E2E-iOS の witness で実測: 帯 778..840 / 容器 200..873)。
        // 中心線を跨ぐ覆い(中央のダイアログ等)は「どちらへ送っても外れない」ので nil
        let containerCentre = container.y + container.height / 2
        let overBottom = over.y + over.height
        if over.y > containerCentre {
            // 下側の帯(タブバー・固定フッタ・ソフトキーボード)= 対象を上へ逃がす
            let needed = target.frame.y + target.frame.height - over.y + margin
            guard needed > 0 else { return nil }
            let jump = max(needed, minimumJump)
            return jump < container.height ? jump : nil
        }
        if overBottom < containerCentre {
            // 上側の帯(ナビゲーションバー)= 対象を下へ逃がす
            let needed = overBottom - target.frame.y + margin
            guard needed > 0 else { return nil }
            let jump = max(needed, minimumJump)
            return jump < container.height ? -jump : nil
        }
        return nil
    }

    public static func describe(_ element: ElementInfo) -> String {
        if let id = element.identifier, !id.isEmpty { return "#\(id)" }
        if let label = element.label.map(FlowMatchMode.normalizeInvisibleCharacters), !label.isEmpty {
            return "\(element.type) \"\(label)\""
        }
        return element.type
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

    /// スクロール探索の「見つかった」ゲート専用の画面外判定。`StepExecutor.isClippedByViewport`
    /// と同じサイズ免除を**軸ごとに**重ねる ——ある軸のサイズが `0 < size <= screen` に収まる
    /// ときだけ、その軸の中心はみ出しを判定に使う。収まらない(oversized/ゼロ)軸は判定から外す。
    /// **isClippedByViewport の全体免除とは意味が違う**: あちらは「寄せ(nudge)を諦める」判定で
    /// 要素全体の可否を1つに畳んでよいが、ここは「found を疑うか」の判定なので、収まる軸で
    /// 中心が画面外なら oversized な相方の軸に免除を借りて found と言ってはいけない
    /// (実例: 画面 402x874 で高さ1000のページャセルが x=800 = 横に完全に画面外。縦が
    /// oversized でも、収まる横軸の画面外は無視できない)。両軸とも oversized/ゼロなら
    /// 判定材料が無いので nil(従来の全体免除と同じ帰結)。MCP 側の scroll_to 再照合
    /// (`MCPServer+Snapshot.swift`)もこれへ揃える(単独の `offscreenAdvisory` ではなくこちら)
    public static func offscreenScrollGateAdvisory(for element: ElementInfo, screen: FTRect) -> String? {
        guard let c = offscreenScrollGateCentre(for: element, screen: screen) else { return nil }
        return "its centre (\(Int(c.x)), \(Int(c.y))) is outside the visible screen,"
            + " so this almost certainly did nothing"
    }

    /// `offscreenScrollGateAdvisory` の**判定だけ**(文言を持たない)。ゲートが効くとき要素の中心を返す。
    /// **共有するのは判定であって文言ではない**: 探索の「見つかった」ゲート・MCP の再照合・
    /// `requireVisible` の幾何 Tier-0(`StepExecutor.occlusionFlip`)が同じ述語を使い、
    /// 「撃っても何も起きない」「見えていない」は呼び手が自分の言葉で書く
    public static func offscreenScrollGateCentre(for element: ElementInfo,
                                                 screen: FTRect) -> (x: Double, y: Double)? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        let frame = element.frame
        let widthFits = frame.width > 0 && frame.width <= screen.width
        let heightFits = frame.height > 0 && frame.height <= screen.height
        guard widthFits || heightFits else { return nil }
        let cx = frame.x + frame.width / 2
        let cy = frame.y + frame.height / 2
        let pad = offscreenCentreTolerance
        let xInside = cx >= screen.x - pad && cx <= screen.x + screen.width + pad
        let yInside = cy >= screen.y - pad && cy <= screen.y + screen.height + pad
        guard (widthFits && !xInside) || (heightFits && !yInside) else { return nil }
        return (cx, cy)
    }

    /// 「中心が中身のどこにも乗らない」。**frame の中心を撃つときにしか言えない** ——
    /// 呼び出し側が見えている部分の中心へ寄せる(`StepExecutor.visibleTapRect`)場合、
    /// 撃つ点が変わるので「背後へ抜けた」は嘘になる(2026-08-08 のレビュー)
    public static func missedContentAdvisory(for element: ElementInfo, in elements: [ElementInfo],
                                             screen: FTRect) -> String? {
        guard let inner = missesItsOwnContent(element, in: elements, screen: screen) else {
            return nil
        }
        // **`describe` と同じ「名指し」であってセレクタの保証はしない**(2026-08-15。
        // ラベルはエスケープを通していない)。「代わりにこれを狙え」という助言だが、
        // 対象は読み手が見て選ぶための短い名前で、DSL に書ける保証まで負わせていない
        let name = inner.identifier.map { "#\($0)" } ?? inner.label.map { "\"\($0)\"" } ?? inner.type
        return "the target is not interactive and its centre is not over any of its own content,"
            + " so the touch went to whatever is behind it (aim at \(name) instead)"
    }

    /// キーボード chrome とみなす identifier。**申告 keyboardFrame と交差するものだけ**を
    /// 対象にする(無条件に identifier で拾うと、画面の別の場所にある同名要素で矩形が暴発する)
    public static let keyboardChromeIdentifiers: Set<String> = ["inputView", "SystemInputAssistantView"]

    /// `KeyboardOcclusion.resolve(reported:in:).frame` の薄いラッパー(既存呼び出し・単体テスト互換用)
    public static func effectiveKeyboardFrame(reported: FTRect?,
                                              in elements: [ElementInfo]) -> FTRect? {
        KeyboardOcclusion.resolve(reported: reported, in: elements).frame
    }

    /// 「中心がソフトキーボードの下」の**中心点だけの判定**。木からは判定できない
    /// (キーボードはスナップショットの対象外)ので、ブリッジが申告する `keyboardFrame` でだけ
    /// 言える。**警告のみ**(新しい検知は拒否でなく警告から。start-new-detections-as-warnings)。
    ///
    /// 実測(2026-08-08・iOS): キーボード下の候補行 ref タップが警告なしで顔文字キーに当たった。
    /// ツリー内の inputView は子孫が全部除外された空葉になり、既存の空葉コンテナ除外
    /// (`OcclusionGeometry.isBlankLeafContainer`。誤検知対策)で遮蔽候補から外れる —— だからツリー由来の
    /// 遮蔽判定では原理的に拾えない。
    ///
    /// **chrome 自身の除外はこの関数の責務ではない** —— それは `KeyboardOcclusion.advisory(for:)`
    /// が呼び出し前に行う。直接呼ぶ側(単体テスト等)は中心点だけで判定される
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

    /// **画面端に接した**細い帯の閾値。sliverThinDimension(10)より緩めるが、
    /// デザイン上ただ細いだけの要素(端に接していない)を巻き込まないよう画面端接触を必須にする
    /// (2026-08-10。実測: Google マップのモードタブ「2 時間 26」が (1068,449 12x59)・画面幅1080で
    /// 幅12px、素の閾値10を取りこぼした)
    public static let edgeSliverThinDimension: Double = 14
    /// 画面端とみなす許容誤差(pt/px)。縁の丸め差を「接していない」と誤判定しないための猶予
    public static let edgeSliverTolerance: Double = 1

    public static func isClippedSliver(_ element: ElementInfo, screen: FTRect) -> Bool {
        let label = FlowMatchMode.normalizeInvisibleCharacters(element.label ?? "")
        guard label.count >= 2 else { return false }
        let w = element.frame.width
        let h = element.frame.height
        if (w <= sliverThinDimension && h >= sliverLongDimension)
            || (h <= sliverThinDimension && w >= sliverLongDimension) {
            return true
        }
        guard screen.width > 0 else { return false }
        let tol = edgeSliverTolerance
        let atLeftOrRight = element.frame.x <= screen.x + tol
            || element.frame.x + element.frame.width >= screen.x + screen.width - tol
        guard atLeftOrRight, w <= edgeSliverThinDimension, h >= sliverLongDimension else {
            return false
        }
        return true
    }
}

/// 実効矩形(chrome で広げた申告 keyboardFrame)と、chrome 自身・その部分木の ref を
/// **1つにまとめた値**。常にセットで使われる —— 地球儀キー・変換候補バーのような chrome の
/// 部品は矩形の中に入るが、それらは「覆っている側」であって「覆われている側」ではないため、
/// 矩形だけを持ち回ると chrome 自身を chrome の下に隠れていると誤って言ってしまう。
///
/// ブリッジ申告の `keyboardFrame` は `.keyboard` ノードの frame だけで、**キー面のみ**を指す
/// (サジェストバー `SystemInputAssistantView` と、地球儀/Dictate 行を含む `inputView` の
/// 下端を含まない)。実測(iOS 3フィクスチャ): 申告 y=583..816 に対し、木にある chrome の frame
/// 和は y=538..874(画面高 874 = 下端まで)。
public struct KeyboardOcclusion: Sendable {
    /// 実効矩形。申告(reported)が無ければ nil
    public let frame: FTRect?
    /// chrome 自身と部分木の ref。この集合には「隠れている」と言わない
    private let excluded: Set<Int>
    /// Android の adjustResize で窓がキーボード上端まで縮み、覆われた要素が木から
    /// **消えている**(遮蔽ではなく脱落)形。根拠は非 excluded 要素の最下端(maxBottom)が
    /// 実効矩形の上端に一致し(差 ≤ 1pt/dp。`TapTargetGeometry.contains` と同じ丸め許容)、
    /// かつ実効矩形の上端より下へはみ出す要素が1つも無いこと。iOS は窓が縮まないため
    /// 常に false(はみ出す要素が残る。実測: Pixel 4a 実機 1267=1267 / 固定コーパス
    /// `and-form_keyboard` 1541=1541 が true・iOS 6画面と `and-maps_suggest_ime`・
    /// `and-browser_urlmenu` は要素がはみ出すため false)。
    /// **「隠れているものは数えられない」ので true だからといって「下に何も無い」とは言えない**
    public let windowResizedAboveKeyboard: Bool

    public static let none = KeyboardOcclusion(frame: nil, excluded: [], windowResizedAboveKeyboard: false)

    /// chrome が木に無ければ申告どおり・除外なし(旧ブリッジ・空葉除外で消えた場合の
    /// 後退防止。`ios-browser_startpage` と Android 全機種がこのケース)
    public static func resolve(reported: FTRect?, in elements: [ElementInfo]) -> KeyboardOcclusion {
        guard let reported else { return .none }
        let seeds = chromeElements(intersecting: reported, in: elements)
        guard !seeds.isEmpty else {
            return KeyboardOcclusion(frame: reported, excluded: [],
                                      windowResizedAboveKeyboard: resizedAboveKeyboard(
                                        frame: reported, excluded: [], in: elements))
        }
        let minX = seeds.reduce(reported.x) { min($0, $1.frame.x) }
        let minY = seeds.reduce(reported.y) { min($0, $1.frame.y) }
        let maxX = seeds.reduce(reported.x + reported.width) { max($0, $1.frame.x + $1.frame.width) }
        let maxY = seeds.reduce(reported.y + reported.height) { max($0, $1.frame.y + $1.frame.height) }
        let expanded = FTRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        // 広げた実効矩形で chrome を拾い直す —— 申告(reported)とは縁がちょうど接するだけの
        // chrome(SystemInputAssistantView が申告の直上に隣接する形)は seeds に入らないが、
        // 実効矩形には完全に収まる。ここで拾い直さないと、その部分木(地球儀キー等)が
        // 除外から漏れる
        let chrome = chromeElements(intersecting: expanded, in: elements)
        var excluded: Set<Int> = []
        for c in chrome {
            excluded.insert(c.ref)
            excluded.formUnion(StepExecutor.descendants(of: c, in: elements).map(\.ref))
        }
        return KeyboardOcclusion(frame: expanded, excluded: excluded,
                                  windowResizedAboveKeyboard: resizedAboveKeyboard(
                                    frame: expanded, excluded: excluded, in: elements))
    }

    private static func resizedAboveKeyboard(frame: FTRect, excluded: Set<Int>,
                                             in elements: [ElementInfo]) -> Bool {
        let candidates = elements.filter { !excluded.contains($0.ref) }
        guard !candidates.isEmpty else { return false }
        let maxBottom = candidates.reduce(-Double.greatestFiniteMagnitude) {
            max($0, $1.frame.y + $1.frame.height)
        }
        guard abs(maxBottom - frame.y) <= 1 else { return false }
        return !candidates.contains { $0.frame.y + $0.frame.height > frame.y + 1 }
    }

    private static func chromeElements(intersecting rect: FTRect,
                                       in elements: [ElementInfo]) -> [ElementInfo] {
        elements.filter {
            guard let id = $0.identifier,
                  TapTargetGeometry.keyboardChromeIdentifiers.contains(id) else { return false }
            return ScrollGeometry.intersection(rect, $0.frame) != nil
        }
    }

    /// 「中心がソフトキーボードの下」。**chrome 自身とその部分木には言わない**
    /// (地球儀キー・変換候補バー等は覆っている側であり、覆われているとは言えない)
    public func advisory(for element: ElementInfo) -> String? {
        guard !excluded.contains(element.ref) else { return nil }
        return TapTargetGeometry.keyboardCoveredAdvisory(element, keyboardFrame: frame)
    }

    public func covers(_ element: ElementInfo) -> Bool { advisory(for: element) != nil }
}
