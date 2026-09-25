// tap-target occlusion 判定(中心点内包で「撃つと何に当たるか」を名指しする)。
// MCP(`RefGuard`。転送のみ)と DSL(`TapTargetGeometry.occlusionAdvisory`)が共有する。
// `OcclusionSuspicion.covering` とは別軸(面積重なり率0.4・FM を呼ぶかの前段) —— 統合しない
// 理由はそちらの型 doc を参照。塗り順の実体は `PaintOrder`、包含/系譜の実体は `TapTargetGeometry`。

import Foundation

public enum OcclusionGeometry {

    /// 中心を覆う別要素。**除くのは自分の祖先と子孫だけ**(「自分より深いものだけ」に絞ると、
    /// タブより浅い遮蔽物 `#tab_controls` を実測で外してしまう。容器を数えない目的には祖先の除外で足りる)
    public static func occluder(of element: ElementInfo, in elements: [ElementInfo],
                         screen: FTRect) -> ElementInfo? {
        let cx = element.frame.x + element.frame.width / 2
        let cy = element.frame.y + element.frame.height / 2
        let excluded = TapTargetGeometry.lineage(of: element, in: elements)
        // **いちばん手前を返す**(DSL の `OcclusionSuspicion.covering` と揃えた)。配列順で最初の候補を
        // 返すと中間層を名指しして実際の最前面(タップを受け取った要素)を素通しする。塗り順が
        // 採れる場では最前面を計算できるので、当てずっぽうを残す理由が無い
        let isOccluder: (ElementInfo) -> Bool = { other in
            guard !excluded.contains(other.ref),
                  other.frame.x <= cx, cx <= other.frame.x + other.frame.width,
                  other.frame.y <= cy, cy <= other.frame.y + other.frame.height
            else { return false }
            if isBlankLeafContainer(other, in: elements) { return false }
            if reportsContentExtent(other) { return false }
            // **描かれていないものは何も覆えない**(外部フィードバックで発覚)。相手がスクロール容器の
            // 外に出ている(= 残像)なら、矩形が重なっていても実際にはそこに無い(実例: 画面外へ出た
            // リスト行の容器が「閉じる」を誤って遮蔽扱いした)。**この判定を先に置く**のが要点 ——
            // 包含判定は 1pt 差で外れるほど際どく、閾値では守り切れない
            if StepExecutor.isOutsideContainer(other, in: elements, screen: screen) { return false }
            // **容器の内側でも、原点へ潰れているだけなら描かれていない**。`isOutsideContainer` は容器の
            // **外**しか見ないため、容器の**原点にクランプ**された残骸(同じ原点の同 depth 兄弟が3つ以上=
            // `hasClampedCoordinates` と同じ現象)を素通ししていた(実測・ios-news_feed: overlay 警告52件中
            // 30件がこのクランプ幽霊を誤って犯人扱いしていた)。`stackedRefs` の絞り込みは警告の表示側の話で
            // 条件を合わせない。**矩形完全一致(hasClampedCoordinates)と原点一致・大きさ違い(isOriginClamped)の
            // 両方を通す** —— 片方だけだと印は付くのに犯人としては名指しされ続ける食い違いが残る
            if StepExecutor.hasClampedCoordinates(other, in: elements) { return false }
            if isOriginClamped(other, in: elements) { return false }
            // **スクロール容器は、その点に自分の中身が無いなら何も隠していない**。iOS は z を出さないので
            // 塗り順は木の順序で代用するしかなく、content inset を持つ表がタブ帯を「覆っている」と誤報していた
            // (実測・ios-news_feed: 中身が無い座標での誤警告7件)。**中身の有無で見る**のが要点 ——
            // 容器そのものを弾くと真陽性を落とす(背後の本文リンクを実際に覆う容器もある)
            if other.scrollable == true,
               !hasDescendantCovering(x: cx, y: cy, of: other, in: elements) { return false }
            // **矩形がぴったり同じ相手は遮蔽と言わない**。同寸同位置は「上に載った物」ではなく
            // ラッパーか、同じ枠を奪い合う入れ替わり(実測・Apple マップ: 出ていない方が出ている方を
            // 覆っていることになっていた)。**本物の積み重なりは `stackedRefs` が別に見ている**
            if sameFrame(other.frame, element.frame) { return false }
            // ここから先は「自分を丸ごと包む相手」の話。包まないなら素直に遮蔽
            guard TapTargetGeometry.contains(other.frame, element.frame) else { return true }
            // **奥にある相手は覆えない**(drawnAbove。z があればそれ、無ければ木の順序)。これが無いと
            // **視覚的には親だが木では兄弟**のラッパーが遮蔽物になる(実測・Apple マップの1画面目:
            // 検索バーが中のボタンを覆っていると誤報し、タップは正常だった)
            if !PaintOrder.drawnAbove(other, element) { return false }
            // **塗り順が実測で採れているなら、ここから下の幾何ヒューリスティクスは使わない**。下の2つは
            // 「木の順序では手前/奥が分からない」ことへの当て推量で、真値がある場に混ぜると打ち消す
            // (実測・Google マップ: z のあるシートが地図側の容器を「内側の入れ物」と誤判定し警告が消えた)。
            // 包含していて、かつ手前に描かれているなら、それは覆っている
            if other.z != nil, element.z != nil { return true }
            // **いちばん内側の入れ物より外側なら外枠**。相手が「自分を包むもっと小さい何か」ごと包んで
            // いるなら、それは上に載った物ではなくレイアウトの外枠。面積でも depth でも切り分けられない ——
            // 違うのは「間にもう1枚あるか」だけ:
            //   app bar: 包むのは header_container だけ              → いちばん内側 = 遮蔽として残す
            //   カード:  HomeView ⊃ MapsSearchBar ⊃ userProfileButton → 外枠として外す
            // **depth からの親復元は使えない**(中間ノードはフィルタで落ちる。実測ではアバターの「親」が
            // 無関係なシートグラバーになっていた)
            if enclosesAnInnerWrapper(of: element, candidate: other, in: elements) { return false }
            // **画面規模の相手だけが容器**。完全包含でも面積が画面の fullScreenContainerAreaRatio 未満なら
            // 容器ではなく遮蔽 —— 面積を見ずに「包む相手はみな容器」とすると app bar の下に潜った行が
            // 丸ごと無警告になっていた(実測: 閉じるボタンを包む相手が画面そのものの Toolbar だった)
            let otherArea = other.frame.width * other.frame.height
            let screenArea = screen.width * screen.height
            return screenArea > 0 && otherArea < screenArea * TapTargetGeometry.fullScreenContainerAreaRatio
        }
        // `max(by:)` の述語は「$0 が $1 より奥か」= $1 が手前なら $0 < $1。
        // `drawnAbove` は z か ref の全順序なので、これで最前面がひとつ決まる
        return elements.filter(isOccluder).max { PaintOrder.drawnAbove($1, $0) }
    }

    /// **容器の中に居るのに、後から描かれた別要素に中心を覆われている**要素の遮蔽物。
    /// `isUntappableGhost` は「容器の外」を入口条件にするため、この形を1つも捕まえない
    /// (実測・E2E-iOS ホーム: リスト内の要素が下部タブに中心を重ねられ、ref タップがタブへ
    /// 遷移して "tap done" を返していた)。
    ///
    /// **木の順序(= 描画順)で後ろにあるものだけ**を遮蔽とみなすのが要点。これを外すと、
    /// 先に並ぶ大きな背景パネルが端の要素を「覆っている」ことになる誤検知に逆戻りする。
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
    /// `isOutsideContainer` だけでは dock のアイコンを誤って弾く —— 容器の推測から外れる位置に
    /// 出るが、その座標には**それ自身しか無い**ので普通にタップできる。`isOutsideContainer` は
    /// DSL では「掴み直して送り直す」= やり直しの合図に使われ、外れても次の周回で回復するが、
    /// MCP はそれを**警告**として使う(`ghostWarning`。拒否ではない —— 誤検知が5形続いたため)。
    /// 以下の除外規則は「何に当たるかもしれないか」を言うために残している。
    ///
    /// そこで危険の定義そのものを条件にする —— **中心に別の要素が重なっている**こと。
    /// 実測: E2E の残像行の中心には下部タブが重なる(拒否)。springboard のアイコンの中心には
    /// 何も重ならない(通す)。
    public static func isUntappableGhost(_ element: ElementInfo, in elements: [ElementInfo],
                                  screen: FTRect) -> Bool {
        guard StepExecutor.isOutsideContainer(element, in: elements, screen: screen) else { return false }
        return occluder(of: element, in: elements, screen: screen) != nil
    }

    /// **同じ矩形に積まれた要素**の ref。これだけの数が同じ場所に描かれることは有り得ないので、
    /// 少なくとも一部は「本来の位置を出せずクランプされた残骸」。
    ///
    /// isUntappableGhost では捕まらない —— クランプ先は**容器の内側**なので `isOutsideContainer`
    /// が false になる(実測・E2E-iOS スクロール画面: 29個の staticText が全部同じ矩形に畳まれ
    /// 無印のまま出ていた。その ref を叩くと別行が selected になり成功が返る)。
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
            // **無地のラッパーは数えない**: 同一矩形の入れ子ラッパー連鎖(Android ではありふれた形。
            // 実測4件はいずれも普通のボトムシート)を件数だけで積み重なりと誤認していた。
            // label/value のどちらかを持つものだけを数え、それが下限に届くときだけ印を付ける
            // (印を付ける対象は群の全要素のまま)
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
    /// 実測(iOS 実機の SmartNews。フィクスチャ `ios-news_feed`): 画面外の行 65 件が
    /// 全部 `(0,103)` へ潰れているのに、完全一致で印が付くのは 42 件だけだった。残りを撃つと
    /// 実際に上部カルーセルの販促カードへ飛ぶ(実機で確認)。
    ///
    /// **条件は「機構そのもの」**(`hasClampedCoordinates` と同じ考え方): 同じ原点に**同 depth の
    /// 兄弟が3つ以上**居て、かつ**その原点を貸している自分より大きい祖先候補**が居ること。
    /// 原点の一致だけなら容器と子で普通に起きるので、3件の同 depth 兄弟という条件が効く。
    ///
    /// **コーパス全数で誤検知0**(測ってから入れた): 他の39枚は1件も増えず、
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
        // **無地のラッパーは数えない**(and-camera_canvas を足して判明。矩形一致の側には最初からあった
        // 条件を、原点側に付け忘れていた —— Google カメラのプレビューは重ね合わせ層14枚が全部同じ矩形に
        // 並ぶ普通の形で、ラベルを持つのは1つだけだった)。数えるのは**中身を持つ兄弟だけ**
        // (無地の兄弟を別に数えても、常に `withContent <= siblings` なので条件が二重になるだけ
        // = 変異で殺せない分岐が残る)
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
    /// 非対話的容器は実際には画面に何も描いていない(実測: 全幅の非 clickable な葉コンテナが
    /// 「スキップ」ボタンとサジェスト候補の両方を誤って遮蔽扱いしたが、タップは正常に成功していた)。
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
    /// `pickerWheel`(XCUITest)は回転ドラムの content 全長を出すので、**自分の入れ物を上下に
    /// はみ出す**(実測・Apple マップの経路オプション画面: pickerWheel が上に並ぶセグメンテッド
    /// コントロールを覆っていると誤判定していたが、タップは正常に通っていた。純粋な誤検知)。
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
    /// ②実アプリで出た誤検知は全部この形だった(Apple マップの1画面目で3件)
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
