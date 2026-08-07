// ref で指した要素を「撃つ直前に撮り直して照合する」ための純ロジック。
//
// なぜ要るか(2026-08-06 の探索で3形とも実機ならぬ Simulator/Emulator 上で決定的に再現した):
//   1. Android の Compose は縦横どちらのスクロール後も a11y ツリーが**古いまま固まる**。
//      ft_snapshot が返す frame はスクロール前のもので、その ref を叩くと**別の行**が発火し、
//      ツールは "tap done" を返す(#row_03 を叩いて selected=row_10 になった)
//   2. Compose iOS は容器の外へ出た行を**フルフレームのまま木に残す**(ghost)。
//      xcuitest エンジンはそれを座標で叩くので、下部タブバーの上に重なった ghost を叩くと
//      **タブが切り替わる**(ios-inapp は要素起動なので当たる = エンジンで結果が割れる)
//   3. 上2つはどちらも**沈黙した誤操作**で、後段の検証だけが落ちて原因が遠い
//
// 対策は「ref を信用しない」こと。**ref はスナップショットごとに振り直される**ので、
// 覚えた要素の同一性(identifier → label+型 → 型+frame)で撮り直した木から引き直し、
// 引けなければ撃たずに理由を返す。ghost 判定は StepExecutor.isOutsideContainer と共有する
// (MCP 側に別の閾値を置くと DSL と定義が割れる)。

import FTCore

enum RefGuard {

    /// 撮り直した木での照合結果
    enum Outcome {
        /// 同じ要素を引き直せた(moved = 前回から動いた距離 pt/px)
        case found(ElementInfo, moved: Double)
        /// 木から消えた
        case gone
        /// スクロール容器の**完全に外**に居る(ghost)。座標を撃つと別の要素に当たる
        case ghost(ElementInfo)
    }

    /// 「動いた」と注記する下限。1px 未満は丸め差なので黙る
    static let movedThreshold: Double = 1.0

    /// 覚えていた要素 `target` を、撮り直した木 `fresh` から引き直す
    static func relocate(_ target: ElementInfo, in fresh: [ElementInfo], screen: FTRect) -> Outcome {
        guard let found = match(target, in: fresh) else { return .gone }
        if isUntappableGhost(found, in: fresh, screen: screen) { return .ghost(found) }
        return .found(found, moved: distance(target.frame, found.frame))
    }

    /// **撃つと別の要素に当たる**ことが具体的に言えるときだけ ghost 扱いする。
    ///
    /// 当初は `isOutsideContainer` だけで判定していたが、**ホーム画面の dock を弾いた**
    /// (2026-08-06 の外部フィードバックで発覚)。dock のアイコンは容器の推測から外れる位置に
    /// 出るが、その座標には**それ自身しか無い**ので普通にタップできる。
    /// `isOutsideContainer` は DSL では「掴み直して送り直す」= やり直しの合図に使われており、
    /// 外しても次の周回で回復する。MCP はそれを**拒否**へ格上げしたので、同じ閾値では強すぎた
    /// —— **2026-08-06 に拒否をやめ、警告に落とした**(誤検知が5形続いたため。`ghostWarning`)。
    /// 以下の除外規則は「何に当たるかもしれないか」を言うために残している。
    ///
    /// そこで危険の定義そのものを条件にする —— **中心に別の要素が重なっている**こと。
    /// 実測: E2E の残像行 `#row_11` の中心 (201,818) には下部タブ `#tab_controls` が重なる(拒否)。
    /// springboard の `#Safari` の中心 (157,805) には何も重ならない(通す)。
    static func isUntappableGhost(_ element: ElementInfo, in elements: [ElementInfo],
                                  screen: FTRect) -> Bool {
        guard StepExecutor.isOutsideContainer(element, in: elements) else { return false }
        return occluder(of: element, in: elements, screen: screen) != nil
    }

    /// **同じ矩形に積まれた要素**の ref。これだけの数が同じ場所に描かれることは有り得ないので、
    /// 少なくとも一部は「本来の位置を出せずクランプされた残骸」。
    ///
    /// isUntappableGhost では捕まらない —— クランプ先は**容器の内側**なので
    /// `isOutsideContainer` が false になる。実測(E2E-iOS のスクロール画面・xcuitest):
    /// `#row_09`〜`#row_11` の clickable は容器の外に出て印が付くが、**行 09〜行 40 の
    /// staticText 29 個は全部 (16,270 330x56)**(= 行 01 の位置)に畳まれ、無印のまま出ていた。
    /// その ref を叩くと `selected=row_01` になり、ツールは成功を返す(2026-08-06 に実測)。
    ///
    /// **入れ子の一本鎖は数えない**: 容器とその唯一の子が同じ矩形になるのは普通で
    /// (Android のダイアログは `action_bar_root`→`content`→`parentPanel`→`customPanel`→`custom`
    /// が全部同じ矩形)、これを弾くと正常な木が丸ごと警告になる
    static func stackedRefs(_ elements: [ElementInfo]) -> Set<Int> {
        var byFrame: [String: [ElementInfo]] = [:]
        for element in elements {
            byFrame[frameKey(element.frame), default: []].append(element)
        }
        var flagged: Set<Int> = []
        for (_, group) in byFrame where group.count >= stackedFrameMinimum {
            let chain = lineage(of: group[0], in: elements)
            if group.allSatisfy({ chain.contains($0.ref) }) { continue }
            // **無地のラッパーは数えない**(欠陥⑤): 同一矩形の入れ子ラッパー連鎖(Android では
            // ありふれた形。実測: `#expandingscrollview_container`/`#cardui_cardlist`/
            // `#recycler_view`/`#home_bottom_sheet_container` の4件で、実際は普通のボトムシート)
            // を件数だけで積み重なりと誤認していた。label/value のどちらかを持つものだけを数え、
            // それが下限に届くときだけ印を付ける(印を付ける対象は従来どおり群の全要素)
            let withContent = group.filter { !($0.label ?? "").isEmpty || !($0.value ?? "").isEmpty }
            guard withContent.count >= stackedFrameMinimum else { continue }
            flagged.formUnion(group.map(\.ref))
        }
        return flagged
    }

    /// 積み重なりとみなす下限。**3**にしてある: 2個は「容器＋その子」で普通に起きる形で、
    /// 一本鎖の除外を抜けた 2個(兄弟が偶然同寸同位置)まで拾うと誤検知側へ倒れる
    static let stackedFrameMinimum = 3

    /// 丸めた矩形のキー(1pt 未満の差は同じ位置とみなす)
    private static func frameKey(_ frame: FTRect) -> String {
        "\(frame.x.rounded()),\(frame.y.rounded()),"
            + "\(frame.width.rounded()),\(frame.height.rounded())"
    }

    /// **容器の中に居るのに、後から描かれた別要素に中心を覆われている**要素の遮蔽物。
    ///
    /// `isUntappableGhost` は「容器の外」を入口条件にしているので、この形を1つも捕まえない。
    /// 実測(E2E-iOS のホーム・xcuitest): `#nav_heal` (16,788 370x62) は縦リストの中にあるが、
    /// 下部タブ `#tab_controls` (134,778 134x62) がその中心 (201,819) に重なっており、
    /// ref 指定のタップは**コントロールタブへ遷移**して "tap done" が返っていた。
    ///
    /// **木の順序(= 描画順)で後ろにあるものだけ**を遮蔽とみなすのが要点。これを外すと、
    /// 先に並ぶ大きな背景パネルが端の要素を「覆っている」ことになり、
    /// 2026-08-06 に拒否をやめる原因になった誤検知の形に逆戻りする。
    /// 祖先・子孫の除外、残像の除外、丸ごと包む相手の除外は `occluder` と共有する
    static func overlayCovering(_ element: ElementInfo, in elements: [ElementInfo],
                                screen: FTRect) -> ElementInfo? {
        guard !isUntappableGhost(element, in: elements, screen: screen) else { return nil }
        guard let hit = occluder(of: element, in: elements, screen: screen),
              drawnAbove(hit, element) else { return nil }
        return hit
    }

    /// **何も描いていない葉コンテナ**は遮蔽候補から除外する: label・value が空で子孫を持たない
    /// 非対話的容器(`other`)は、実際には画面に何も描いていない。
    /// 実測: `#compass_container`(全幅・非 clickable・葉)が起動直後の「スキップ」ボタンと
    /// 検索サジェスト先頭候補の両方を遮蔽扱いしたが、どちらもタップは正常に成功していた。
    /// **`image` や対話型(`clickable` 等)は対象外**(ラベルの無い装飾アイコンでも実際に描かれている)
    private static func isBlankLeafContainer(_ element: ElementInfo, in elements: [ElementInfo]) -> Bool {
        guard element.type == "other",
              (element.label ?? "").isEmpty, (element.value ?? "").isEmpty
        else { return false }
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return true }
        let next = elements.index(after: index)
        return next >= elements.endIndex || elements[next].depth <= element.depth
    }

    /// 完全包含でも「容器」とみなす面積比の下限。実測: app bar (0,0 1080x290) は画面
    /// (1080x2424) の約 12% で、これを容器扱いすると下に潜った行への遮蔽が丸ごと無警告になる。
    /// 全画面の toolbar/collectionView・`#AdditionalDimmingOverlay` は 100% なので下回らない
    static let fullScreenContainerAreaRatio = 0.5

    /// 中心を覆う別要素。**除くのは自分の祖先と子孫だけ**。
    /// 「自分より深いものだけ」に絞ると外す —— 実測では残像 `#row_11`(リストの奥)に重なるのは
    /// 下部タブ `#tab_controls` で、**タブのほうが浅い**。容器(リスト・画面全体)を数えない
    /// 目的には祖先の除外で足りる
    static func occluder(of element: ElementInfo, in elements: [ElementInfo],
                         screen: FTRect) -> ElementInfo? {
        let cx = element.frame.x + element.frame.width / 2
        let cy = element.frame.y + element.frame.height / 2
        let excluded = lineage(of: element, in: elements)
        return elements.first { other in
            guard !excluded.contains(other.ref),
                  other.frame.x <= cx, cx <= other.frame.x + other.frame.width,
                  other.frame.y <= cy, cy <= other.frame.y + other.frame.height
            else { return false }
            if isBlankLeafContainer(other, in: elements) { return false }
            // **描かれていないものは何も覆えない**(2026-08-06 の外部フィードバック2件目)。
            // 相手自身がスクロール容器の外に出ている(= 残像)なら、矩形が重なっていても
            // 実際にはそこに無い。実例: 設定アプリの検索で「閉じる」を弾いていた
            // `clickable (16,484 370x52)` は、スクロールで画面外へ出たリスト行の容器だった。
            // **この判定を先に置く**のが要点 —— 包含判定は 1pt の差で外れるほど際どく
            // (閉じる y483..521 対 clickable y484..536)、閾値では守り切れない
            if StepExecutor.isOutsideContainer(other, in: elements) { return false }
            // **矩形がぴったり同じ相手は遮蔽と言わない**。同寸同位置は「上に載った物」ではなく
            // ラッパーか、同じ枠を奪い合う入れ替わり(実測・Apple マップの検索結果:
            // `#ResultsViewTable` と `#SearchAutocompleteView` はどちらも (0,62 402x812) で、
            // 出ていない方が出ている方を覆っていることになっていた)。**本物の積み重なりは
            // `stackedRefs` が別に見ている**ので、ここで拾わなくても取りこぼさない
            if sameFrame(other.frame, element.frame) { return false }
            // ここから先は「自分を丸ごと包む相手」の話。包まないなら素直に遮蔽
            guard contains(other.frame, element.frame) else { return true }
            // **奥にある相手は覆えない**(drawnAbove。z があればそれ、無ければ木の順序)。
            // 奥にある入れ物は覆えない —— これが無いと、**視覚的には親だが木では兄弟**の
            // ラッパーが遮蔽物になる。実測(2026-08-07・Apple マップの1画面目):
            // `#MapsSearchBar`(ref 4・画面の 8.7%)が中の `#userProfileButton`(ref 8)を
            // 覆っていると報告し、⚠️scroll-leftover を出していた。タップは正常だった
            if !drawnAbove(other, element) { return false }
            // **塗り順が実測で採れているなら、ここから下の幾何ヒューリスティクスは使わない**。
            // 下の2つは「木の順序では手前/奥が分からない」ことへの当て推量で、真値がある場に
            // 混ぜると真値を打ち消す —— 実測(2026-08-07・Google マップ): シート(z=76)が
            // `#mylocation_button`(z=17)を覆っているのに、地図側の容器 `#qu_mylocation_container`
            // が「内側の入れ物」に当たって外枠と誤判定し、警告が消えた。
            // 包含していて、かつ手前に描かれているなら、それは覆っている
            if other.z != nil, element.z != nil { return true }
            // **いちばん内側の入れ物より外側なら外枠**。相手が「自分を包むもっと小さい何か」ごと
            // 包んでいるなら、それは上に載った物ではなくレイアウトの外枠。
            // 面積でも depth でも切り分けられない —— app bar の形(`#transit_station_title_name` を
            // 包む `#header_container`)と、カードの形(`#userProfileButton` を包む `#HomeView`)は
            // **depth も包含関係も同じ**で、違うのは「間にもう1枚あるか」だけ:
            //   app bar: 包むのは header_container だけ            → いちばん内側 = 遮蔽として残す
            //   カード:  HomeView ⊃ MapsSearchBar ⊃ userProfileButton → 外枠として外す
            // **depth からの親復元は使えない**: 中間ノードはフィルタで落ちており、実測では
            // アバターの「親」がシートグラバー(152,847 96x23)になっていた
            if enclosesAnInnerWrapper(of: element, candidate: other, in: elements) { return false }
            // **画面規模の相手だけが容器**。完全包含でも面積が画面の
            // fullScreenContainerAreaRatio 未満なら容器ではなく遮蔽 —— app bar の下に潜った行は
            // まさにこの形で、面積を見ずに「包む相手はみな容器」とすると丸ごと無警告になっていた。
            // 実測: 閉じる (351,485 38x38) を包む相手は Toolbar (0,0 402x874) = 画面そのもの
            let otherArea = other.frame.width * other.frame.height
            let screenArea = screen.width * screen.height
            return screenArea > 0 && otherArea < screenArea * fullScreenContainerAreaRatio
        }
    }

    /// `candidate` が `element` より手前に描かれているか。
    ///
    /// **ブリッジが塗り順(`z`)を申告するなら必ずそれを使う**。ツリー順は描画順の代理として
    /// 使ってきたが、production では裏返る —— Google マップは地図の FAB(ref 81〜86)を
    /// シート(ref 17〜61)より**後**に出すのに、描画はシートが手前。2026-08-07 に
    /// `#mylocation_button` を無警告でタップして裏の広告を踏み、**Chrome が起動**した。
    ///
    /// `z` を持たないエンジン(iOS の XCUITest / in-app には描画順を読む API が無い)では
    /// 従来どおり ref 順へ落ちる。**両者が揃っているときだけ z を信じる**のは、
    /// 片方だけ nil の木(打ち切りや別ブリッジの混在)で大小が無意味になるため
    static func drawnAbove(_ candidate: ElementInfo, _ element: ElementInfo) -> Bool {
        if let candidateZ = candidate.z, let elementZ = element.z { return candidateZ > elementZ }
        return candidate.ref > element.ref
    }

    /// outer が inner を完全に含むか(縁の丸め差 1pt は許容)
    static func contains(_ outer: FTRect, _ inner: FTRect) -> Bool {
        outer.x <= inner.x + 1 && outer.y <= inner.y + 1
            && outer.x + outer.width >= inner.x + inner.width - 1
            && outer.y + outer.height >= inner.y + inner.height - 1
    }

    /// `candidate` と `element` の**間に**もう1枚、element を包む小さい入れ物があるか。
    /// あるなら candidate はいちばん内側ではない = 外枠。
    ///
    /// **見落としの側に倒れる形**は自覚している: モーダルが「行の中のボタン」を覆う場合、
    /// 行が内側の入れ物になってモーダルが外枠と判定される。それでもこちらを採るのは、
    /// ①よくある遮蔽(スクロールで潜る・浮遊ボタン)は**部分的な重なり**なのでこの分岐に来ない
    /// ②実アプリで出た誤検知は全部この形だった(2026-08-07・Apple マップの1画面目で3件)
    /// ③これは警告であって拒否ではない、の3点による
    static func enclosesAnInnerWrapper(of element: ElementInfo, candidate: ElementInfo,
                                       in elements: [ElementInfo]) -> Bool {
        // **祖先は数える**(むしろ本命): `#MapsSearchTextField` を包む `#MapsSearchBar` は
        // その祖先で、それごと包む `#HomeView` が外枠だと分かる。
        // 除くのは自分と子孫だけ —— 同一矩形の子を「内側の入れ物」と数えると何でも外枠になる
        let descendants = Set(StepExecutor.descendants(of: element, in: elements).map(\.ref))
        let candidateArea = candidate.frame.width * candidate.frame.height
        return elements.contains { inner in
            guard inner.ref != candidate.ref, inner.ref != element.ref,
                  !descendants.contains(inner.ref),
                  contains(inner.frame, element.frame),
                  contains(candidate.frame, inner.frame) else { return false }
            return inner.frame.width * inner.frame.height < candidateArea
        }
    }

    /// 自分・祖先・子孫の ref(preorder + depth から復元する)
    static func lineage(of element: ElementInfo, in elements: [ElementInfo]) -> Set<Int> {
        var result: Set<Int> = [element.ref]
        guard let index = elements.firstIndex(where: { $0.ref == element.ref }) else { return result }
        var depth = element.depth
        for ancestor in elements[..<index].reversed() where ancestor.depth < depth {
            result.insert(ancestor.ref)
            depth = ancestor.depth
        }
        var i = elements.index(after: index)
        while i < elements.endIndex, elements[i].depth > element.depth {
            result.insert(elements[i].ref)
            i = elements.index(after: i)
        }
        return result
    }

    /// 同一性の照合。**強い手掛かりから順に**当てて、候補が複数なら最も近い frame を採る。
    /// 型を必ず見るのは、同じラベルの Button と StaticText が並ぶ形(E2E の `#txt_shared_label` /
    /// `#btn_shared_label`)で取り違えないため
    static func match(_ target: ElementInfo, in fresh: [ElementInfo]) -> ElementInfo? {
        if let id = target.identifier, !id.isEmpty {
            if let hit = nearest(to: target, among: fresh.filter { $0.identifier == id }) { return hit }
            // identifier があるのに1つも無い = 消えた。ラベルで拾い直すと**別の要素**を掴む
            return nil
        }
        if let label = target.label, !label.isEmpty {
            let sameLabel = fresh.filter { $0.label == label && $0.type == target.type }
            if let hit = nearest(to: target, among: sameLabel) { return hit }
            return nil
        }
        // id もラベルも無い要素(装飾・容器)。**動いていないことだけ**を根拠に同一とみなす
        return fresh.first { $0.type == target.type && sameFrame($0.frame, target.frame) }
    }

    private static func nearest(to target: ElementInfo,
                                among candidates: [ElementInfo]) -> ElementInfo? {
        candidates.min { distance($0.frame, target.frame) < distance($1.frame, target.frame) }
    }

    private static func sameFrame(_ a: FTRect, _ b: FTRect) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// frame 中心どうしの距離
    static func distance(_ a: FTRect, _ b: FTRect) -> Double {
        let dx = (a.x + a.width / 2) - (b.x + b.width / 2)
        let dy = (a.y + a.height / 2) - (b.y + b.height / 2)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 失敗メッセージ用の人が読める識別(`#id` があればそれ、無ければ型とラベル)
    static func describe(_ element: ElementInfo) -> String {
        if let id = element.identifier, !id.isEmpty { return "#\(id)" }
        if let label = element.label, !label.isEmpty { return "\(element.type) \"\(label)\"" }
        return element.type
    }

    /// **打ち切りも「消えた」の原因になる**(欠陥①と同型): 画面が密になるとブリッジの
    /// 要素上限に押し出され、画面には出ているのに木から落ちる。原因を「画面が変わった」と
    /// 断定すると、そこで探索が止まる
    static func goneMessage(ref: Int, target: ElementInfo, truncatedCount: Int = 0) -> String {
        let truncated = truncatedCount > 0
            ? " (or it was pushed out of the tree: \(truncatedCount) element(s) were omitted"
                + " by the snapshot limit)"
            : ""
        return "[\(ref)] \(describe(target)) is no longer in the tree — the screen changed after"
            + " that ft_snapshot\(truncated). Take a fresh ft_snapshot and use the new ref."
    }

    /// **撃つ。ただし何に当たったかもしれないかを言う**(2026-08-06 に拒否から後退)。
    ///
    /// 木の幾何だけでは「実際に描かれているか」を決められない、というのが5形の誤検知で
    /// 示された結論。相手が残像でなく、包含でもなく、それでも描かれていないことがある
    /// (キーボードの下・スクロールアウト)。**キーボードはスナップショットから除外されている**
    /// ので frame すら取れず、原理的に判定材料が足りない。
    ///
    /// 押せる要素を押せなくする害は、誤操作を見逃す害と**別種で、こちらは確実に起きる**。
    /// 情報だけ渡して判断はエージェントに委ねる —— 一覧の行にも印が付いているので、
    /// 「怪しいものを撃った」ことは黙って通り過ぎない
    static func ghostWarning(found: ElementInfo, in elements: [ElementInfo], screen: FTRect) -> String {
        let hit = occluder(of: found, in: elements, screen: screen)
            .map { " (possibly \(describe($0)))" } ?? ""
        return " (warning: \(describe(found)) is reported outside its scroll container, so this"
            + " may have hit whatever is really drawn there\(hit) — verify with ft_screenshot,"
            + " or use ft_scroll_to to bring it into view first)"
    }

    static func ghostMessage(ref: Int, found: ElementInfo, in elements: [ElementInfo],
                             screen: FTRect) -> String {
        let hit = occluder(of: found, in: elements, screen: screen)
            .map { " — the tap would land on \(describe($0))" } ?? ""
        let f = found.frame
        // **逃げ道も書く**が、順序を守る(外部フィードバック 2026-08-06)。
        // 先に「本来の直し方」、次に「確かめたうえでの回避」。座標タップを無条件に勧めると、
        // 判定が正しいとき **覆っている要素を黙って叩く**ことになり、このガードの意味が消える
        return "[\(ref)] \(describe(found)) is outside its scroll container and something else is"
            + " drawn at its coordinates\(hit). It is a leftover from scrolling, not what you see."
            + " Bring it into view with ft_scroll_to and re-snapshot."
            + " If ft_screenshot shows it really is visible there, this check was wrong —"
            + " tap the coordinates directly (x: \(Int(f.x + f.width / 2)),"
            + " y: \(Int(f.y + f.height / 2))), which skips the check, and please report it."
    }

    /// ghost ではないが**別の物に当たったかもしれない**2形の注記。空文字なら心当たり無し。
    ///
    /// ghostWarning と同じ方針で**撃ってから言う**(拒否しない)。木の幾何だけでは
    /// 「本当に描かれているか」を決められないという 2026-08-06 の結論は、この2形にも効く。
    static func overlapWarning(found: ElementInfo, in elements: [ElementInfo], screen: FTRect) -> String {
        if let over = overlayCovering(found, in: elements, screen: screen) {
            return " (warning: \(describe(over)) is drawn over the center of \(describe(found)),"
                + " so this may have hit \(describe(over)) instead — verify with ft_screenshot,"
                + " or scroll the element clear of the overlay first)"
        }
        if stackedRefs(elements).contains(found.ref) {
            return " (warning: \(describe(found)) shares its exact frame with other elements,"
                + " so at most one of them is really drawn there — the rest are clamped"
                + " leftovers. Bring it into view with ft_scroll_to and re-snapshot)"
        }
        return ""
    }

    static func movedNote(found: ElementInfo, moved: Double, cause: String) -> String {
        " (\(describe(found)) had moved \(Int(moved.rounded()))px since the snapshot;"
            + " retargeted to where it is now\(cause))"
    }

    /// **原因は断定できないが、範囲は言える**: 同じ分だけ動いた要素が他にもあるなら
    /// スクロール等の画面全体の移動、その要素だけならレイアウト変化。
    /// 「なぜ動いたか」の手掛かりが欲しいという要望(2026-08-06)への、嘘をつかない答え
    static func movedTogether(_ target: ElementInfo, _ found: ElementInfo,
                              before: [ElementInfo], after: [ElementInfo]) -> String {
        let dy = found.frame.y - target.frame.y
        let dx = found.frame.x - target.frame.x
        // **比べる相手は同じ深さの兄弟だけ**。画面全体で数えると、固定ヘッダやタブバーのような
        // 動かない chrome が多数派になり、スクロールでも「動いていない」と誤答する
        // (実測: リストが 295px スクロールしたのに、動かない要素 13 対 動いた要素 7 で誤判定)
        var samePairs = 0
        var otherPairs = 0
        for old in before where old.ref != target.ref && old.depth == target.depth {
            guard let id = old.identifier, !id.isEmpty,
                  let now = after.first(where: { $0.identifier == id }) else { continue }
            otherPairs += 1
            if abs((now.frame.y - old.frame.y) - dy) < 2, abs((now.frame.x - old.frame.x) - dx) < 2 {
                samePairs += 1
            }
        }
        guard otherPairs >= 2 else { return "" }
        // 兄弟の過半が同じ分だけ動いた = 面ごと動いた(スクロール等)
        return samePairs * 2 >= otherPairs
            ? "; \(samePairs) of \(otherPairs) siblings shifted by the same amount,"
                + " so the container scrolled rather than this element alone"
            : "; its siblings did not shift, so the layout changed around it"
    }
}
