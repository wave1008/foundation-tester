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
        if StepExecutor.isOutsideContainer(found, in: fresh) { return .ghost(found) }
        return .found(found, moved: distance(target.frame, found.frame))
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

    static func ghostMessage(ref: Int, found: ElementInfo) -> String {
        "[\(ref)] \(describe(found)) is reported outside its scroll container — it is a leftover"
            + " from scrolling, not what is drawn at those coordinates. Tapping it would hit"
            + " whatever is really there. Scroll it into view (ft_scroll_to) and re-snapshot."
    }

    static func movedNote(found: ElementInfo, moved: Double) -> String {
        " (\(describe(found)) had moved \(Int(moved.rounded()))px since the snapshot;"
            + " retargeted to where it is now)"
    }
}
