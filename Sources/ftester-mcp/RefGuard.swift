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
    /// 外しても次の周回で回復する。MCP はそれを**拒否**へ格上げしたので、同じ閾値では強すぎた。
    ///
    /// そこで危険の定義そのものを条件にする —— **中心に別の要素が重なっている**こと。
    /// 実測: E2E の残像行 `#row_11` の中心 (201,818) には下部タブ `#tab_controls` が重なる(拒否)。
    /// springboard の `#Safari` の中心 (157,805) には何も重ならない(通す)。
    static func isUntappableGhost(_ element: ElementInfo, in elements: [ElementInfo]) -> Bool {
        guard StepExecutor.isOutsideContainer(element, in: elements) else { return false }
        return occluder(of: element, in: elements) != nil
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
            !excluded.contains(other.ref)
                && other.frame.x <= cx && cx <= other.frame.x + other.frame.width
                && other.frame.y <= cy && cy <= other.frame.y + other.frame.height
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

    static func goneMessage(ref: Int, target: ElementInfo) -> String {
        "[\(ref)] \(describe(target)) is no longer in the tree — the screen changed after that"
            + " ft_snapshot. Take a fresh ft_snapshot and use the new ref."
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
