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

    // MARK: - 共有した幾何(実体は FTCore.TapTargetGeometry / FTCore.OcclusionGeometry)
    //
    // **DSL(StepExecutor)と同じ定義を使う**ために FTCore へ出した。ここは転送だけにして
    // 呼び出し側を書き換えない —— 掃討ゲート(SweepHarnessTests)が「移しても件数が変わらない」
    // ことを実アプリのコーパスで検証する。占有判定(occluder/overlayCovering/isUntappableGhost/
    // stackedRefs/enclosesAnInnerWrapper)の実体は FTCore.OcclusionGeometry。

    static let fullScreenContainerAreaRatio = TapTargetGeometry.fullScreenContainerAreaRatio
    static let interactiveTypes = TapTargetGeometry.interactiveTypes

    static func contains(_ outer: FTRect, _ inner: FTRect) -> Bool {
        TapTargetGeometry.contains(outer, inner)
    }

    static func lineage(of element: ElementInfo, in elements: [ElementInfo]) -> Set<Int> {
        TapTargetGeometry.lineage(of: element, in: elements)
    }

    static func missesItsOwnContent(_ element: ElementInfo, in elements: [ElementInfo],
                                    screen: FTRect) -> ElementInfo? {
        TapTargetGeometry.missesItsOwnContent(element, in: elements, screen: screen)
    }

    static func isClippedSliver(_ element: ElementInfo, screen: FTRect) -> Bool {
        TapTargetGeometry.isClippedSliver(element, screen: screen)
    }

    static func nestedActionCoveringCentre(_ element: ElementInfo,
                                           in elements: [ElementInfo]) -> ElementInfo? {
        TapTargetGeometry.nestedActionCoveringCentre(element, in: elements)
    }

    static func outsideDeclaredScroller(_ element: ElementInfo,
                                        in elements: [ElementInfo]) -> ElementInfo? {
        TapTargetGeometry.outsideDeclaredScroller(element, in: elements)
    }

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

    static func isUntappableGhost(_ element: ElementInfo, in elements: [ElementInfo],
                                  screen: FTRect) -> Bool {
        OcclusionGeometry.isUntappableGhost(element, in: elements, screen: screen)
    }

    static func stackedRefs(_ elements: [ElementInfo]) -> Set<Int> {
        OcclusionGeometry.stackedRefs(elements)
    }

    static let stackedFrameMinimum = OcclusionGeometry.stackedFrameMinimum

    static func overlayCovering(_ element: ElementInfo, in elements: [ElementInfo],
                                screen: FTRect) -> ElementInfo? {
        OcclusionGeometry.overlayCovering(element, in: elements, screen: screen)
    }

    static func occluder(of element: ElementInfo, in elements: [ElementInfo],
                         screen: FTRect) -> ElementInfo? {
        OcclusionGeometry.occluder(of: element, in: elements, screen: screen)
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
    /// 判定の実体は `FTCore.PaintOrder` にある(DSL の `OcclusionSuspicion` と共有。
    /// 別々に持つと、同じ画面で MCP と DSL の遮蔽判定が食い違う)
    static func drawnAbove(_ candidate: ElementInfo, _ element: ElementInfo) -> Bool {
        PaintOrder.drawnAbove(candidate, element)
    }

    static func enclosesAnInnerWrapper(of element: ElementInfo, candidate: ElementInfo,
                                       in elements: [ElementInfo]) -> Bool {
        OcclusionGeometry.enclosesAnInnerWrapper(of: element, candidate: candidate, in: elements)
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
    // ゼロ幅文字を落とす理由(visibleLabelsHint と同じ)ごと実体は FTCore 側。describe は
    // tap の警告・goneMessage・遮蔽/ghost の警告が全部通る口なので、ここが最後の砦
    static func describe(_ element: ElementInfo) -> String {
        TapTargetGeometry.describe(element)
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



    /// **無効な要素を叩こうとしている**ときの警告。木には `disabled` と印字しているのに、
    /// 操作経路は `enabled` を一度も見ておらず、押しても何も起きない要素へ "done" を返していた
    /// (2026-08-07 の棚卸しで確認。E2E-CMP の契約上「押しても何も起きない」ボタンに対し
    /// tap / press / double_tap の3つとも無警告で成功していた。実アプリでも
    /// Apple マップの経路画面に `#CardButtonTypeShare disabled` がある)。
    ///
    /// **拒否ではなく警告**にする —— 「無効な要素が反応しないこと」を確かめる操作は正当で、
    /// DSL 側にも `enabledIsFalse` がある
    static func disabledWarning(_ element: ElementInfo) -> String {
        guard !element.enabled else { return "" }
        return " (warning: \(describe(element)) is disabled, so this almost certainly did nothing)"
    }

    /// **中心が画面の外にある要素を撃とうとしている**ときの警告。ウィンドウ外のタッチは
    /// hitTest に乗らず黙って落ちる(判定は TapTargetGeometry.offscreenAdvisory = DSL と共有)。
    /// 実測(2026-08-08): カレンダーでヘッダ裏へ抜けた `#slot_07`(中心 y=-18)への
    /// ft_tap が無警告の "done" を返し、画面は 1px も変わらなかった
    static func offscreenWarning(_ element: ElementInfo, screen: FTRect) -> String {
        guard let advisory = TapTargetGeometry.offscreenAdvisory(for: element, screen: screen) else {
            return ""
        }
        return " (warning: \(describe(element)) — \(advisory);"
            + " bring it into view with ft_scroll_to and re-snapshot)"
    }

    /// **中心がソフトキーボードの下にある要素を撃とうとしている**ときの警告。木からは判定できない
    /// (キーボードはスナップショットの対象外)ので、ブリッジが申告する `keyboardFrame` でだけ言える
    /// (判定は KeyboardOcclusion = DSL と共有。chrome 自身とその部分木には言わない)。
    /// 実測(2026-08-08・iOS): キーボード下の候補行 ref タップが警告なしで顔文字キーに当たった
    static func keyboardWarning(_ element: ElementInfo, keyboardOcclusion: KeyboardOcclusion) -> String? {
        guard let advisory = keyboardOcclusion.advisory(for: element) else { return nil }
        return " (warning: \(describe(element)) — \(advisory))"
    }

    /// **木に出ないオーバーレイ・ウィンドウの下にある要素を撃とうとしている**ときの警告。
    /// キーボードと同じ理由でブリッジ申告からしか言えない(判定は `OverlayWindowOcclusion`
    /// = DSL と共有)。実測(2026-08-28・実機 Pixel 4a の Chrome): テキスト選択の
    /// フローティングツールバーの下にある段落への ft_tap が無警告の "done" を返し、
    /// 実際には「Select all」に当たってページ全体が選択された
    static func overlayWindowWarning(_ element: ElementInfo,
                                     overlayWindows: OverlayWindowOcclusion) -> String? {
        guard let advisory = overlayWindows.advisory(for: element) else { return nil }
        return " (warning: \(describe(element)) — \(advisory);"
            + " ft_screenshot shows the overlay, which is why it is not in the element list)"
    }

    /// keyboard + overlay window + disabled の組。**この順序で4箇所から呼ばれる** ——
    /// 申告由来の2つを先にするのは、木からは判定できず ghost/overlap 側では検知できない
    /// 唯一の警告だから。**`overlayWindows` に既定値を置かない**(呼び忘れをコンパイルで止める)
    static func preTapWarnings(_ element: ElementInfo, keyboardOcclusion: KeyboardOcclusion,
                               overlayWindows: OverlayWindowOcclusion) -> String {
        (keyboardWarning(element, keyboardOcclusion: keyboardOcclusion) ?? "")
            + (overlayWindowWarning(element, overlayWindows: overlayWindows) ?? "")
            + disabledWarning(element)
    }

    /// **申告されたスクロール容器の外へ送り出された要素を撃とうとしている**ときの警告
    /// (判定は TapTargetGeometry.outsideDeclaredScroller)。`ghostWarning` と同じ事象だが、
    /// あちらの入口は容器の**推測**(`StepExecutor.isOutsideContainer`)なので、申告のある
    /// UIKit/SwiftUI の木では nil に落ちて1件も捕まえていなかった。
    ///
    /// 実測(2026-08-09・Apple マップ): カードを送って `#MUScrollableStackView` (0,72 402x802) の
    /// 上へ抜けた `link "ウィキペディア"` (16,-2 85x18) への ft_tap が無警告の "done" を返し、
    /// 実際には中心 (58,7) = ステータスバーに当たってカードが先頭へ飛んだ
    static func scrolledOutWarning(_ element: ElementInfo, in elements: [ElementInfo]) -> String {
        guard let scroller = outsideDeclaredScroller(element, in: elements) else { return "" }
        return " (warning: \(describe(element)) is reported entirely outside \(describe(scroller)),"
            + " which is the scroll container it belongs to — it is a leftover from scrolling,"
            + " not what you see. Bring it into view with ft_scroll_to and re-snapshot)"
    }

    /// **判定は `TapTargetGeometry.advisoryKind` の1箇所だけ**(DSL の `occlusionAdvisory` と共有)。
    /// ここは kind を MCP の文言(要素を名指しし、ft_screenshot / ft_scroll_to という MCP の
    /// ツール名で逃げ道を書く)へ写すだけ —— 順序・当たり判定を書き直さない
    static func overlapWarning(found: ElementInfo, in elements: [ElementInfo], screen: FTRect) -> String {
        guard let kind = TapTargetGeometry.advisoryKind(for: found, in: elements, screen: screen)
        else { return "" }
        switch kind {
        case .zeroFrame:
            // **DSL にだけあり MCP のタップ時には出ていなかった形**(2026-08-15 に合流)
            return " (warning: \(describe(found))'s reported frame has zero width/height,"
                + " so the tap may land on whatever is at that point — verify with ft_screenshot)"
        case .offscreen:
            // 画面外の中心は「何にも当たらない」= 遮蔽・中身外しより強い事実なので先に言う
            return offscreenWarning(found, screen: screen)
        case .scrolledOut:
            // **容器の外**: これが真なら frame そのものが今の描画位置ではないので、
            // 以下の遮蔽・中身外しはその古い frame を前提にした話になり、名指しが嘘になる
            return scrolledOutWarning(found, in: elements)
        case .overlayCovering(let over):
            return " (warning: \(describe(over)) is drawn over the center of \(describe(found)),"
                + " so this may have hit \(describe(over)) instead — verify with ft_screenshot,"
                + " or scroll the element clear of the overlay first)"
        case .missedContent(let inner):
            return " (warning: \(describe(found)) is not interactive and its center is not over any"
                + " of its own content, so this tap went to whatever is behind it."
                + " Target the content instead, e.g. \(describe(inner)))"
        case .nestedAction(let nested):
            // **子孫が中心を横取りしている**。`overlayCovering` は子孫を除外するので届かない
            // (2026-08-09 に Apple マップの検索候補で実害。TapTargetGeometry の解説を参照)
            return " (warning: \(describe(nested)) sits inside \(describe(found)) and covers its"
                + " center, so this may have triggered \(describe(nested)) instead of"
                + " \(describe(found)) — verify with ft_screenshot, and target the part you"
                + " actually want)"
        case .stacked:
            // **「完全一致」と断定しない**: 判定は原点だけが同じで大きさが違う
            // クランプも見るようになった(OcclusionGeometry.originClampedRefs)。DSL 側の
            // 同じ文面(TapTargetGeometry.occlusionAdvisory)と揃える
            return " (warning: \(describe(found)) is stacked on the same spot as other elements,"
                + " so at most one of them is really drawn there — the rest are clamped"
                + " leftovers. Bring it into view with ft_scroll_to and re-snapshot)"
        case .clippedByContainer(let container):
            // **判定は TapTargetGeometry.clippedAtContainerEdge の1箇所**(実測は同関数の doc)。
            // ブリッジは frame を容器で切ってから送るので overflow の座標は残らず、
            // 縁の一致 + 高さ不足の shortfall witness でしか拾えない
            let edge = TapTargetGeometry.isClippedAtBottomEdge(found, container: container)
                ? "bottom" : "top"
            let h = Int(found.frame.height.rounded())
            return " (warning: \(describe(found)) is cut off at the \(edge) edge of"
                + " \(describe(container)), only \(h) of its height is drawn, so this may have hit"
                + " whatever is drawn there instead — scroll it fully into view with"
                + " ft_scroll_to, and verify with ft_screenshot)"
        case .sliver:
            // **DSL にだけあり MCP のタップ時には出ていなかった形**(2026-08-15 に合流)
            return " (warning: \(describe(found)) is clipped to a thin sliver at the edge of its"
                + " container, so it is narrower than it looks and the tap may miss —"
                + " verify with ft_screenshot)"
        }
    }

    static func movedNote(found: ElementInfo, moved: Double, cause: String) -> String {
        " (\(describe(found)) had moved \(Int(moved.rounded()))px since the snapshot;"
            + " retargeted to where it is now\(cause))"
    }

    /// **同一 identifier で再ターゲットしたら、ラベルが変わっていないかも見る**(2026-08-10 の
    /// 実アプリ監査)。`match(_:in:)` は identifier があればそれだけで引き直すので、検索候補が
    /// 更新された画面では**同じ id・違う行**を掴むことがある。実測: 「立川駅、最近表示した項目」を
    /// 狙ったタップが「立川駅 南口、立川市」に化けたが、位置の話(movedNote)しかしていなかった。
    /// **動いていなくても出す**(ラベルだけ変わって位置が同じ形も同じ危険)
    static func labelChangeNote(old: String?, new: String?) -> String? {
        guard let old = old?.trimmingCharacters(in: .whitespacesAndNewlines), !old.isEmpty,
              let new = new?.trimmingCharacters(in: .whitespacesAndNewlines), !new.isEmpty,
              old != new else { return nil }
        return "; caution: its label has changed from"
            + " \"\(SnapshotRenderer.truncate(old, SnapshotRenderer.labelDisplayLimit))\" to"
            + " \"\(SnapshotRenderer.truncate(new, SnapshotRenderer.labelDisplayLimit))\""
            + " since the snapshot — the list may have refreshed and this can be a different row;"
            + " verify the outcome"
    }

    /// **原因は断定できないが、範囲は言える**: 同じ分だけ動いた要素が他にもあるなら
    /// スクロール等の画面全体の移動、その要素だけならレイアウト変化。
    /// 「なぜ動いたか」の手掛かりが欲しいという要望への、嘘をつかない答え
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
