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
    static func relocate(_ target: ElementInfo, in fresh: [ElementInfo]) -> Outcome {
        guard let found = match(target, in: fresh) else { return .gone }
        if isUntappableGhost(found, in: fresh) { return .ghost(found) }
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
    static func isUntappableGhost(_ element: ElementInfo, in elements: [ElementInfo]) -> Bool {
        guard StepExecutor.isOutsideContainer(element, in: elements) else { return false }
        return occluder(of: element, in: elements) != nil
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
    static func overlayCovering(_ element: ElementInfo,
                                in elements: [ElementInfo]) -> ElementInfo? {
        guard !isUntappableGhost(element, in: elements) else { return nil }
        guard let hit = occluder(of: element, in: elements), hit.ref > element.ref else { return nil }
        return hit
    }

    /// 中心を覆う別要素。**除くのは自分の祖先と子孫だけ**。
    /// 「自分より深いものだけ」に絞ると外す —— 実測では残像 `#row_11`(リストの奥)に重なるのは
    /// 下部タブ `#tab_controls` で、**タブのほうが浅い**。容器(リスト・画面全体)を数えない
    /// 目的には祖先の除外で足りる
    static func occluder(of element: ElementInfo, in elements: [ElementInfo]) -> ElementInfo? {
        let cx = element.frame.x + element.frame.width / 2
        let cy = element.frame.y + element.frame.height / 2
        let excluded = lineage(of: element, in: elements)
        return elements.first { other in
            guard !excluded.contains(other.ref),
                  other.frame.x <= cx, cx <= other.frame.x + other.frame.width,
                  other.frame.y <= cy, cy <= other.frame.y + other.frame.height
            else { return false }
            // **描かれていないものは何も覆えない**(2026-08-06 の外部フィードバック2件目)。
            // 相手自身がスクロール容器の外に出ている(= 残像)なら、矩形が重なっていても
            // 実際にはそこに無い。実例: 設定アプリの検索で「閉じる」を弾いていた
            // `clickable (16,484 370x52)` は、スクロールで画面外へ出たリスト行の容器だった。
            // **この判定を先に置く**のが要点 —— 包含判定は 1pt の差で外れるほど際どく
            // (閉じる y483..521 対 clickable y484..536)、閾値では守り切れない
            if StepExecutor.isOutsideContainer(other, in: elements) { return false }
            // **自分を丸ごと包む相手は遮蔽ではなく容器**(2026-08-06 の外部フィードバック)。
            // 設定アプリの検索を開いた状態で「閉じる」ボタンが弾かれた —— 覆っていたのは
            // `#AdditionalDimmingOverlay` や全画面の toolbar/collectionView で、
            // どれも矩形としては中心を含むが、実際にはボタンより後ろに描かれている。
            // 実測: 閉じる (351,485 38x38) を包む相手は Toolbar (0,0 402x874) 等だけ。
            // 本物の遮蔽(残像 #row_11 に重なる下部タブ)は**一部しか重ならない**
            return !contains(other.frame, element.frame)
        }
    }

    /// outer が inner を完全に含むか(縁の丸め差 1pt は許容)
    static func contains(_ outer: FTRect, _ inner: FTRect) -> Bool {
        outer.x <= inner.x + 1 && outer.y <= inner.y + 1
            && outer.x + outer.width >= inner.x + inner.width - 1
            && outer.y + outer.height >= inner.y + inner.height - 1
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

    static func goneMessage(ref: Int, target: ElementInfo) -> String {
        "[\(ref)] \(describe(target)) is no longer in the tree — the screen changed after that"
            + " ft_snapshot. Take a fresh ft_snapshot and use the new ref."
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
    static func ghostWarning(found: ElementInfo, in elements: [ElementInfo]) -> String {
        let hit = occluder(of: found, in: elements).map { " (possibly \(describe($0)))" } ?? ""
        return " (warning: \(describe(found)) is reported outside its scroll container, so this"
            + " may have hit whatever is really drawn there\(hit) — verify with ft_screenshot,"
            + " or use ft_scroll_to to bring it into view first)"
    }

    static func ghostMessage(ref: Int, found: ElementInfo, in elements: [ElementInfo]) -> String {
        let hit = occluder(of: found, in: elements).map { " — the tap would land on \(describe($0))" } ?? ""
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
    static func overlapWarning(found: ElementInfo, in elements: [ElementInfo]) -> String {
        if let over = overlayCovering(found, in: elements) {
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
