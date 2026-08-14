// tap-target occlusion 判定(中心点内包で「撃つと何に当たるか」を名指しする)。
// MCP(`RefGuard`。転送のみ)と DSL(`TapTargetGeometry.occlusionAdvisory`)が共有する。
// `OcclusionSuspicion.covering` とは別軸(面積重なり率0.4・FM を呼ぶかの前段) —— 統合しない
// 理由はそちらの型 doc を参照。塗り順の実体は `PaintOrder`、包含/系譜の実体は `TapTargetGeometry`。

import Foundation

public enum OcclusionGeometry {

    /// 中心を覆う別要素。**除くのは自分の祖先と子孫だけ**。
    /// 「自分より深いものだけ」に絞ると外す —— 実測では残像 `#row_11`(リストの奥)に重なるのは
    /// 下部タブ `#tab_controls` で、**タブのほうが浅い**。容器(リスト・画面全体)を数えない
    /// 目的には祖先の除外で足りる
    public static func occluder(of element: ElementInfo, in elements: [ElementInfo],
                         screen: FTRect) -> ElementInfo? {
        let cx = element.frame.x + element.frame.width / 2
        let cy = element.frame.y + element.frame.height / 2
        let excluded = TapTargetGeometry.lineage(of: element, in: elements)
        // **いちばん手前を返す**(2026-08-08。DSL の `OcclusionSuspicion.covering` と揃えた)。
        // 配列順で最初の候補を返すと、重なりが複数あるとき中間層を名指しして、実際に見えている
        // 最前面を素通しする。実データでは「包んでいるシート」ではなく**タップを受け取った広告行**が
        // 答えになる。塗り順が採れる場では最前面は計算できるので、当てずっぽうを残す理由が無い
        let isOccluder: (ElementInfo) -> Bool = { other in
            guard !excluded.contains(other.ref),
                  other.frame.x <= cx, cx <= other.frame.x + other.frame.width,
                  other.frame.y <= cy, cy <= other.frame.y + other.frame.height
            else { return false }
            if isBlankLeafContainer(other, in: elements) { return false }
            if reportsContentExtent(other) { return false }
            // **描かれていないものは何も覆えない**(2026-08-06 の外部フィードバック2件目)。
            // 相手自身がスクロール容器の外に出ている(= 残像)なら、矩形が重なっていても
            // 実際にはそこに無い。実例: 設定アプリの検索で「閉じる」を弾いていた
            // `clickable (16,484 370x52)` は、スクロールで画面外へ出たリスト行の容器だった。
            // **この判定を先に置く**のが要点 —— 包含判定は 1pt の差で外れるほど際どく
            // (閉じる y483..521 対 clickable y484..536)、閾値では守り切れない
            if StepExecutor.isOutsideContainer(other, in: elements) { return false }
            // **容器の内側でも、原点へ潰れているだけなら描かれていない**。`isOutsideContainer`
            // は容器の**外**しか見ないので、容器の**原点にクランプ**された残骸(自身が
            // 容器より小さく、同じ原点の同 depth 兄弟が3つ以上いる = `hasClampedCoordinates`
            // と同じ現象)は素通ししていた。実測(2026-08-14・ios-news_feed): フィード先頭で
            // 画面外の行が全部 (0,103) に潰れて木に残る画面で、overlay 警告52件中30件が
            // 犯人としてこのクランプ幽霊を名指ししていた(実体は上部カルーセル)。
            // `stackedRefs` の「中身を持つものが3個以上」という絞り込みは警告の表示側の話で、
            // ここは「この座標に本当に描かれているか」の判定なので条件を合わせない
            // **判定は2つとも通す**: 矩形の完全一致(hasClampedCoordinates)と、
            // 原点だけ同じで大きさが違う形(isOriginClamped)。片方だけだと、印は付くのに
            // 犯人としては名指しされ続ける、という食い違いが残る
            if StepExecutor.hasClampedCoordinates(other, in: elements) { return false }
            if isOriginClamped(other, in: elements) { return false }
            // **スクロール容器は、その点に自分の中身が無いなら何も隠していない**(2026-08-14)。
            // iOS は z を出さないので塗り順は木の順序で代用するしかなく、**フレームが上の
            // chrome の下へ潜り込む容器**(content inset を持つ表・コレクション)が、その上に
            // 描かれているタブ帯を「覆っている」と報告していた。実測(ios-news_feed):
            // `#crui_channelView_tableView` (0,0 393x769) がチャンネルタブ(y=59..100)を
            // 覆うという報告が7件。表の最初の行は y=103 で、タブの位置に中身は1つも無い。
            // **中身の有無で見る**のが要点 —— 容器そのものを弾くと真陽性を落とす
            // (ios-browser_startpage の `StartPageCollectionView` は背後の本文リンクを
            // 実際に覆っており、そこには中身のタイルが描かれている)
            if other.scrollable == true,
               !hasDescendantCovering(x: cx, y: cy, of: other, in: elements) { return false }
            // **矩形がぴったり同じ相手は遮蔽と言わない**。同寸同位置は「上に載った物」ではなく
            // ラッパーか、同じ枠を奪い合う入れ替わり(実測・Apple マップの検索結果:
            // `#ResultsViewTable` と `#SearchAutocompleteView` はどちらも (0,62 402x812) で、
            // 出ていない方が出ている方を覆っていることになっていた)。**本物の積み重なりは
            // `stackedRefs` が別に見ている**ので、ここで拾わなくても取りこぼさない
            if sameFrame(other.frame, element.frame) { return false }
            // ここから先は「自分を丸ごと包む相手」の話。包まないなら素直に遮蔽
            guard TapTargetGeometry.contains(other.frame, element.frame) else { return true }
            // **奥にある相手は覆えない**(drawnAbove。z があればそれ、無ければ木の順序)。
            // 奥にある入れ物は覆えない —— これが無いと、**視覚的には親だが木では兄弟**の
            // ラッパーが遮蔽物になる。実測(2026-08-07・Apple マップの1画面目):
            // `#MapsSearchBar`(ref 4・画面の 8.7%)が中の `#userProfileButton`(ref 8)を
            // 覆っていると報告し、⚠️scroll-leftover を出していた。タップは正常だった
            if !PaintOrder.drawnAbove(other, element) { return false }
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
            return screenArea > 0 && otherArea < screenArea * TapTargetGeometry.fullScreenContainerAreaRatio
        }
        // `max(by:)` の述語は「$0 が $1 より奥か」= $1 が手前なら $0 < $1。
        // `drawnAbove` は z か ref の全順序なので、これで最前面がひとつ決まる
        return elements.filter(isOccluder).max { PaintOrder.drawnAbove($1, $0) }
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
    public static func overlayCovering(_ element: ElementInfo, in elements: [ElementInfo],
                                screen: FTRect) -> ElementInfo? {
        guard !isUntappableGhost(element, in: elements, screen: screen) else { return nil }
        guard let hit = occluder(of: element, in: elements, screen: screen),
              PaintOrder.drawnAbove(hit, element) else { return nil }
        return hit
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
    public static func isUntappableGhost(_ element: ElementInfo, in elements: [ElementInfo],
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
    public static func stackedRefs(_ elements: [ElementInfo]) -> Set<Int> {
        var byFrame: [String: [ElementInfo]] = [:]
        for element in elements {
            byFrame[frameKey(element.frame), default: []].append(element)
        }
        var flagged: Set<Int> = []
        for (_, group) in byFrame where group.count >= stackedFrameMinimum {
            let chain = TapTargetGeometry.lineage(of: group[0], in: elements)
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
        return flagged.union(originClampedRefs(elements))
    }

    /// **原点だけが同じで大きさが違うクランプ**の ref。上の `stackedRefs` は矩形の*完全一致*しか
    /// 見ないので、行の高さがまちまちなリスト(実アプリのフィードはたいていそう)では
    /// 群が3件に届かず**無印のまま出る**。
    ///
    /// 実測(2026-08-14・iOS 実機の SmartNews。フィクスチャ `ios-news_feed`): 画面外の行 65 件が
    /// 全部 `(0,103)` へ潰れているのに、完全一致で印が付くのは 42 件だけだった。残りを撃つと
    /// 実際に上部カルーセルの販促カードへ飛ぶ(実機で確認)。
    ///
    /// **条件は「機構そのもの」**(`hasClampedCoordinates` と同じ考え方): 同じ原点に**同 depth の
    /// 兄弟が3つ以上**居て、かつ**その原点を貸している自分より大きい祖先候補**が居ること。
    /// 原点の一致だけなら容器と子で普通に起きるので、3件の同 depth 兄弟という条件が効く。
    ///
    /// **コーパス全数で誤検知0**(2026-08-14 に測ってから入れた): 他の39枚は1件も増えず、
    /// witness の `ios-news_feed` だけが +18(全部 (0,103) のクランプ広告コピー)。
    ///
    /// **これは警告であって拒否ではない**(新しい検知は警告から)。DSL の候補除外
    /// (`StepExecutor.hasClampedCoordinates`)は**広げていない** —— あちらは解決そのものを
    /// 拒む強い経路なので、同じ根拠で格上げする前に別途 witness が要る
    static func originClampedRefs(_ elements: [ElementInfo]) -> Set<Int> {
        Set(elements.filter { isOriginClamped($0, in: elements) }.map(\.ref))
    }

    /// 1要素ぶんの判定(`originClampedRefs` と**同じ規則**。遮蔽候補の除外はこちらを使う ——
    /// 集合を作り直すと `occluder` の呼び出しごとに全数を走査することになる)
    public static func isOriginClamped(_ element: ElementInfo,
                                       in elements: [ElementInfo]) -> Bool {
        guard lendsItsOrigin(to: element, in: elements) else { return false }
        // **無地のラッパーは数えない**(2026-08-14 に and-camera_canvas を足して判明)。
        // 矩形一致の側には最初からあった条件を、原点側に付け忘れていた ——
        // Google カメラのプレビューは重ね合わせ層 14 枚が全部 (0,288 1080x1440) に並ぶ普通の形で、
        // ラベルを持つのは `viewfinder_frame` の1つだけ。**入れたばかりの検知が次の画面で
        // 誤検知を出す**という台帳の警告そのものを踏んだので、同じ条件を写す
        // 数えるのは**中身を持つ兄弟だけ**(無地の兄弟を別に数えても、常に
        // `withContent <= siblings` なので条件が二重になるだけ = 変異で殺せない分岐が残る)
        var withContent = 0
        for other in elements
        where other.depth == element.depth
            && abs(other.frame.x - element.frame.x) <= 0.5
            && abs(other.frame.y - element.frame.y) <= 0.5
            && (!(other.label ?? "").isEmpty || !(other.value ?? "").isEmpty) {
            withContent += 1
            if withContent >= stackedFrameMinimum { return true }
        }
        return false
    }

    /// 容器の**子孫**がその点を覆っているか(= その位置に実際に中身が描かれているか)。
    /// スナップショットは preorder + depth なので、容器の直後から depth が戻るまでが子孫
    private static func hasDescendantCovering(x: Double, y: Double, of container: ElementInfo,
                                              in elements: [ElementInfo]) -> Bool {
        guard let start = elements.firstIndex(where: { $0.ref == container.ref })
        else { return false }
        var index = elements.index(after: start)
        while index < elements.endIndex, elements[index].depth > container.depth {
            let frame = elements[index].frame
            if frame.x <= x, x <= frame.x + frame.width,
               frame.y <= y, y <= frame.y + frame.height { return true }
            index = elements.index(after: index)
        }
        return false
    }

    /// 自分より浅く、原点が一致し、自分より大きい要素(= クランプ先の容器)が居るか
    private static func lendsItsOrigin(to element: ElementInfo,
                                       in elements: [ElementInfo]) -> Bool {
        let frame = element.frame
        return elements.contains { container in
            container.depth < element.depth
                && abs(container.frame.x - frame.x) <= 0.5
                && abs(container.frame.y - frame.y) <= 0.5
                && container.frame.width >= frame.width && container.frame.height >= frame.height
                && (container.frame.width > frame.width + 0.5
                    || container.frame.height > frame.height + 0.5)
        }
    }

    /// 積み重なりとみなす下限。**3**にしてある: 2個は「容器＋その子」で普通に起きる形で、
    /// 一本鎖の除外を抜けた 2個(兄弟が偶然同寸同位置)まで拾うと誤検知側へ倒れる
    public static let stackedFrameMinimum = 3

    /// 丸めた矩形のキー(1pt 未満の差は同じ位置とみなす)
    private static func frameKey(_ frame: FTRect) -> String {
        "\(frame.x.rounded()),\(frame.y.rounded()),"
            + "\(frame.width.rounded()),\(frame.height.rounded())"
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

    /// **描かれる範囲ではなく「中身の全長」を frame に申告する型**。遮蔽候補から外す。
    ///
    /// `pickerWheel`(XCUITest)は回転ドラムの content 全長を出すので、**自分の入れ物を
    /// 上下にはみ出す**。実測(2026-08-12・Apple マップの経路オプション画面):
    /// `datePicker` (41,246.7 320x216) の中の pickerWheel 3本はいずれも
    /// (y 209.2, 高さ 291) —— 上へ 37.5pt・下へ 37.8pt はみ出し、**その上に並ぶ
    /// セグメンテッドコントロール「今すぐ出発」(26,204.3 116x32)の中心 (84,220.3) を
    /// 覆っている**と判定していた。タップは正常に通る(同日 ft_batch で実測)ので純粋な誤検知。
    ///
    /// **入れ物ごと外すのではない**のが要点 —— `datePicker` やシート自体は候補に残るので、
    /// 「ピッカーが下の入力欄を覆っている」本物の形は取りこぼさない。
    ///
    /// 「親をはみ出したら中身の全長」という一般則にはしていない: この木は中間ノードが
    /// フィルタで落ちており、depth からの親復元が当てにならない(`enclosesAnInnerWrapper` の
    /// doc と同じ理由)。当てにならない親で clip すると、本物の遮蔽を黙って消す側へ倒れる
    private static func reportsContentExtent(_ element: ElementInfo) -> Bool {
        element.type == "pickerWheel"
    }

    /// `candidate` と `element` の**間に**もう1枚、element を包む小さい入れ物があるか。
    /// あるなら candidate はいちばん内側ではない = 外枠。
    ///
    /// **見落としの側に倒れる形**は自覚している: モーダルが「行の中のボタン」を覆う場合、
    /// 行が内側の入れ物になってモーダルが外枠と判定される。それでもこちらを採るのは、
    /// ①よくある遮蔽(スクロールで潜る・浮遊ボタン)は**部分的な重なり**なのでこの分岐に来ない
    /// ②実アプリで出た誤検知は全部この形だった(2026-08-07・Apple マップの1画面目で3件)
    /// ③これは警告であって拒否ではない、の3点による
    public static func enclosesAnInnerWrapper(of element: ElementInfo, candidate: ElementInfo,
                                       in elements: [ElementInfo]) -> Bool {
        // **祖先は数える**(むしろ本命): `#MapsSearchTextField` を包む `#MapsSearchBar` は
        // その祖先で、それごと包む `#HomeView` が外枠だと分かる。
        // 除くのは自分と子孫だけ —— 同一矩形の子を「内側の入れ物」と数えると何でも外枠になる
        let descendants = Set(StepExecutor.descendants(of: element, in: elements).map(\.ref))
        let candidateArea = candidate.frame.width * candidate.frame.height
        return elements.contains { inner in
            guard inner.ref != candidate.ref, inner.ref != element.ref,
                  !descendants.contains(inner.ref),
                  TapTargetGeometry.contains(inner.frame, element.frame),
                  TapTargetGeometry.contains(candidate.frame, inner.frame) else { return false }
            return inner.frame.width * inner.frame.height < candidateArea
        }
    }

    private static func sameFrame(_ a: FTRect, _ b: FTRect) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}
