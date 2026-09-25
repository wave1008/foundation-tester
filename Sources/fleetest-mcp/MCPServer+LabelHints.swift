// MCPServer+LabelHints.swift
// 曖昧なラベル・重複 id・グループ描画の注記。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// 曖昧と呼ぶ下限。**2**: 2件でも `tap("他のフィルタ")` は
    /// 一意に選べず、危険度は3件と変わらない。実測(Google マップの検索結果)では
    /// `"他のフィルタ"` が別 frame の2件あるのに黙っていた。
    /// 雑音は「入れ子の一本鎖」を除外して抑える(下記)
    static let ambiguousLabelMinimum = 2

    /// 群の全メンバーが index-based(`.indexed`)か「そもそも書けない」(`graded` が nil)で、
    /// かつ index-based なメンバーが**全員同じスコープ接頭辞**(`graded.selector` の最後の
    /// `" >> "` より前。無ければ空文字)を持つときだけ、代替セレクタの列挙を ref の列へ畳む。
    /// 1件でも `.stable` があれば nil(呼び手は通常の列挙描画へ落ちる)。
    /// **判定・整形の両方をここに閉じる**(呼び手が条件を自前で再実装しない)。
    /// 実測(Apple マップ監査): 同じ容器に並ぶ同型セルが10件あると、
    /// index 違いだけの代替セレクタ6行が並び、注記が本文より長くなっていた
    ///
    /// `gradedShown` は**明細描画と共有する**先頭 `ambiguousMatchesShown` 件の採番結果。
    /// 同じ要素を二度 `graded` に掛けない —— 実アプリ画面では1件の採番が候補の検証2周
    /// (`picksExactly`/`picksOnlyOne`)を払う(`SelectorNaming.typeLabelCounts` の doc 参照)。
    /// 打ち切りの外側は畳めるかの判定にしか使わないので、そこだけ遅延で引く。
    /// 空で呼べば全件を自分で引く(結果は同じ。共有しないぶん遅いだけ)
    static func compactGroupLine(label: String, matches: [ElementInfo],
                                 gradedShown: [(selector: String, durability: Durability)?] = [],
                                 naming: SelectorNaming, in snapshot: SnapshotResponse) -> String? {
        var scope: String?
        var anyIndexed = false
        for (offset, element) in matches.enumerated() {
            let cached = offset < gradedShown.count
                ? gradedShown[offset] : naming.graded(for: element, in: snapshot)
            guard let graded = cached else { continue }
            guard graded.durability == .indexed else { return nil }
            anyIndexed = true
            let prefix: String
            if let range = graded.selector.range(of: " >> ", options: .backwards) {
                prefix = String(graded.selector[..<range.lowerBound])
            } else {
                prefix = ""
            }
            // **スコープが割れたら畳まない**。「全員索引形なら畳めるはず」と
            // 緩めて実測したが、**撤回した** —— 固定コーパス 40 枚で減るのは 1,555B(最悪画面
            // `ios-maps_transit_steps_expanded` で 2,690→2,290)なのに対し、
            // 失うのは上のテストが witness を持つ識別情報そのもの(Google マップのタブ帯は
            // **どのタブの子かが祖先名にしか乗っていない**)。畳んだ瞬間に5件が区別できなくなる。
            // **再提案しない**(測ったうえで割に合わないと決めた)
            if let existing = scope {
                guard existing == prefix else { return nil }
            } else {
                scope = prefix
            }
        }
        let shownRefs = matches.prefix(ambiguousMatchesShown).map { "[\($0.ref)]" }
            .joined(separator: " ")
        let cut = matches.count > ambiguousMatchesShown
            ? " (+\(matches.count - ambiguousMatchesShown) more matches not shown)" : ""
        let reason: String
        if anyIndexed {
            let scopeClause = (scope?.isEmpty == false) ? "repeats inside \(scope!); " : ""
            reason = "\(scopeClause)every alternative is index-based, so tap by ref instead."
        } else {
            reason = "none of these have a selector on this screen; tap by ref instead."
        }
        return "  \(label) ×\(matches.count): \(shownRefs)\(cut) — \(reason)"
    }

    /// `ambiguousLabelsNote` と `duplicateIDsNote` が共有する描画本体。差分はグループ化キー
    /// (呼び出し側で `label` に整形済み — `"\"foo\""` か `"#foo"`)と3つの文言だけなので、
    /// ここは凡例ヘッダ・グループごとの明細・打ち切り行・`anyStable` フッタだけを持つ。
    /// **グループ化とフィルタは呼び出し側の責務のまま**(ここへ寄せない)
    /// `brief`: **事実と群は出すが、要素ごとの代替セレクタの列挙だけ畳む**。
    /// A/B の計測用の口(`FT_MCP_NOTES_BRIEF` の宣言参照)で、既定は false。
    /// **`abbreviated` とは畳む対象が違う** —— あちらはヘッダの凡例、こちらは明細。
    /// 実測(`ios-maps_transit_steps_expanded`)では、注記 3,621B のうち明細が主因で、
    /// 短縮形にしても 2,894B にしか下がらない
    private static func renderGroups(_ sortedGroups: [(label: String, matches: [ElementInfo])],
                                     naming: SelectorNaming, in snapshot: SnapshotResponse,
                                     fullHeader: String, shortHeader: String,
                                     overflowNoun: String, abbreviated: Bool,
                                     brief: Bool = false) -> String {
        guard !sortedGroups.isEmpty else { return "" }
        var lines: [String] = [abbreviated ? shortHeader : fullHeader]
        var anyStable = false
        if brief {
            // **既に畳まれている群には触らない**(実測で踏んだ): 全群が
            // `compactGroupLine` で畳まれる画面(セレクタが1つも書けない web の格子等)で
            // 末尾の総括を足すと、**畳んだはずの brief のほうが長くなる**(固定コーパス 40 枚中
            // 10 枚が負だった)。brief は full の**厳密な部分集合**でなければ、A/B が
            // 「明細の有無」ではなく「定型文の差」を測ってしまう
            var foldedAny = false
            for (label, matches) in sortedGroups.prefix(ambiguousLabelsShown) {
                let gradedShown = matches.prefix(ambiguousMatchesShown)
                    .map { naming.graded(for: $0, in: snapshot) }
                if let compact = compactGroupLine(label: label, matches: matches,
                                                  gradedShown: gradedShown, naming: naming,
                                                  in: snapshot) {
                    lines.append(compact)
                    continue
                }
                foldedAny = true
                let shownRefs = matches.prefix(ambiguousMatchesShown).map { "[\($0.ref)]" }
                    .joined(separator: " ")
                let cut = matches.count > ambiguousMatchesShown
                    ? " (+\(matches.count - ambiguousMatchesShown) more matches not shown)" : ""
                lines.append("  \(label) ×\(matches.count): \(shownRefs)\(cut)")
            }
            if sortedGroups.count > ambiguousLabelsShown {
                lines.append("  (+\(sortedGroups.count - ambiguousLabelsShown) more"
                    + " \(overflowNoun)(s) not shown — ft_snapshot again after narrowing the"
                    + " screen to see them)")
            }
            if foldedAny {
                lines.append("  Tap these by ref. To get a selector for one of them,"
                    + " ft_tap prints the selector it recommends for the element it hit.")
            }
            return lines.joined(separator: "\n") + "\n"
        }
        // **畳んだ行は既に「tap by ref instead」と言っている**(compactGroupLine)。全部が
        // 畳まれた回に末尾の総括まで出すと、同じ助言が N+1 回並ぶ(監査で実測:
        // Google マップの経路一覧で5群すべてが畳まれ、その下にもう一度同じ文が出ていた)
        var allCompact = true
        for (label, matches) in sortedGroups.prefix(ambiguousLabelsShown) {
            // **採番は1要素につき1回**: 畳めるかの判定と明細描画で二度引かない(compactGroupLine の doc)
            let gradedShown = matches.prefix(ambiguousMatchesShown)
                .map { naming.graded(for: $0, in: snapshot) }
            if let compact = compactGroupLine(label: label, matches: matches,
                                              gradedShown: gradedShown, naming: naming,
                                              in: snapshot) {
                lines.append(compact)
                continue
            }
            allCompact = false
            // **索引形も書き出す**。「索引形は最も弱い格付けなので ref だけにする」と
            // 削って実測したが、**撤回した** —— 固定コーパスで 3,401B(明細の 42%)を占める
            // 最大の塊ではあるが、**その長さの元凶であるスコープ接頭辞が識別情報そのもの**
            // (`#explore_tab_strip_button >> .other` と `#saved_tab_strip_button >> .other` は
            // 「どのタブの子か」だけが違う)。落とすと5件が区別できなくなる ——
            // compactGroupLine の同スコープ要求と**同じ理由で同じテストが捕まえる**。
            // **再提案しない**(2回試して2回とも同じ砦に当たった)
            let shown = zip(matches.prefix(ambiguousMatchesShown), gradedShown)
                .map { element, graded -> String in
                    guard let graded else { return "[\(element.ref)] —" }
                    if graded.durability == .stable { anyStable = true }
                    return "[\(element.ref)] \(graded.selector)\(graded.durability.mark)"
                }.joined(separator: " / ")
            let cut = matches.count > ambiguousMatchesShown
                ? " (+\(matches.count - ambiguousMatchesShown) more matches not shown)" : ""
            lines.append("  \(label) ×\(matches.count): \(shown)\(cut)")
        }
        if sortedGroups.count > ambiguousLabelsShown {
            lines.append("  (+\(sortedGroups.count - ambiguousLabelsShown) more \(overflowNoun)(s)"
                + " not shown — ft_snapshot again after narrowing the screen to see them)")
        }
        if !anyStable, !allCompact {
            lines.append("  none of the above have a stable selector on this screen —"
                + " prefer tapping by ref for these.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 同一ラベルが複数に一致するときの要約注記(欠陥⑩)。id の重複は別パッケージが
    /// 行内に `×N` として個別に出すので、こちらは**ラベルだけ**を扱う。
    /// 実測: 経路検索の候補一覧で「東京駅」が9件一致し、素のラベルでは一意に指せなかった
    /// `abbreviated`(F-6 の対象拡大): 明細行(ラベルごとの候補列挙)と末尾の
    /// 「+N more」は既定と同じまま、ヘッダの凡例だけ「初出の注記を見よ」に圧縮する
    static func ambiguousLabelsNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false,
                                    brief: Bool = false,
                                    cache: SnapshotAnnotationCache? = nil) -> String {
        var groups: [String: [ElementInfo]] = [:]
        for e in snapshot.elements {
            // **ゼロ幅文字を落としてから数える**。一覧の行は
            // `SnapshotRenderer.renderElement` が除去済みの形で出すので、生ラベルのまま
            // 注記に出すと**同じラベルが1つの応答の中で2表記**になる(実測: Google マップの
            // `"​​埼京線​"`)。読み手はこれを別物と読む。数える側も揃える —— ゼロ幅の有無だけが
            // 違う2件は `FlowMatchMode.matches` では区別できず、実際に曖昧だから
            let label = SnapshotRenderer.displayText(e.label ?? "")
            guard !label.isEmpty else { continue }
            groups[label, default: []].append(e)
        }
        let ambiguous = groups
            .filter { $0.value.count >= ambiguousLabelMinimum && !isSingleChain($0.value, in: snapshot) }
            // **全員が飾りの葉なら列挙しない**(実アプリ監査): 地図 POI の
            // 「〜の路線」×3 のような群はセレクタの書き先にならないのに行を占めていた。
            // 1件でも操作対象・型付きが混じる群は全員出す(片側だけ隠すと
            // ×N の数と明細が食い違う)。判定は bulk fold と同じ SnapshotRenderer.isDecorativeLeaf
            .filter { !$0.value.allSatisfy { SnapshotRenderer.isDecorativeLeaf($0, in: snapshot.elements) } }
            // **セレクタとして誰も書かないラベルは列挙しない**(実アプリ監査):
            // Google マップの経路詳細では区切りの `" · "` ×3 が代替セレクタ付きで注記の上位を
            // 占めていた。飾り葉フィルタ(上)は `type == "other"` 限定なので staticText の
            // 区切りは素通りする —— **あちらを広げない**(staticText を飾り扱いにすると
            // 見出しや値という正当なセレクタ対象まで消える)。ここで語の有無だけを見る。
            // **ただし操作可能要素が1つでも混じる群は残す**(上の飾り葉フィルタと同じ
            // 「1件でも実対象が混じれば全員出す」規律): '+'/'−' のような記号だけラベルの
            // ボタン群が丸ごと注記から消えていた
            .filter { !isSymbolOnlyLabel($0.key)
                || $0.value.contains { BridgeSnapshotThinning.operableTypes.contains($0.type) } }
            .sorted { groupPrecedes(key: $0.key, count: $0.value.count,
                                    otherKey: $1.key, otherCount: $1.value.count) }
        guard !ambiguous.isEmpty else { return "" }
        // **「一意に指せない」で終わらせない**: MCP の出力はシナリオへ書く文字列を
        // 供給するためにあるので、代わりに書ける形まで出す。機構は `writableSelector` =
        // ft_tap の推奨セレクタ(E)と同じ実装
        // **cache 経由なら duplicateIDsNote と同じ SelectorNaming を共有する**:
        // 両方の群に出る要素の graded を二重に検証しない
        let naming = cache?.selectorNaming(snapshot) ?? SelectorNaming(snapshot)
        return renderGroups(ambiguous.map { (label: "\"\($0.key)\"", matches: $0.value) },
                            naming: naming, in: snapshot,
                            fullHeader: "note: these labels match multiple elements, so a plain label"
                                + " selector cannot pick one uniquely. Write one of these instead"
                                + " (\"—\" = this element has no stable selector; use a labelled"
                                + " ancestor or a coordinate. \"~\" = index-based, so it breaks if"
                                + " the number of same-type siblings changes — usable, but the"
                                + " weakest of the three):",
                            shortHeader: "note: ambiguous labels — write one of these instead"
                                + " (legend in the first snapshot's note):",
                            overflowNoun: "ambiguous label", abbreviated: abbreviated, brief: brief)
    }

    /// 重複 id の要約注記。`#id` はこのツールが最も推奨するセレクタなので、行末の `×N` だけ
    /// では足りない —— 実測: 時刻ピッカーの「時」「分」が両方 `id=numberpicker_input` で、
    /// 読み手はどちらも `#numberpicker_input` で指せると誤読し、別の欄が操作された。
    /// 除外(isSingleChain)・上限・代替セレクタの出し方は ambiguousLabelsNote と**まったく同じ
    /// 仕組み**(SelectorNaming.graded)を使い回す —— 採番規則を2つ持たない。
    /// `abbreviated` はラベル版と同じ意味(F-6)
    static func duplicateIDsNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false,
                                 brief: Bool = false,
                                 cache: SnapshotAnnotationCache? = nil) -> String {
        var groups: [String: [ElementInfo]] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            groups[id, default: []].append(e)
        }
        let flags = cache?.ghostFlags(snapshot) ?? ghostFlags(snapshot)
        let bulkFolded = cache?.foldedGroups(snapshot, flagging: flags, collapsingBulk: true)
            ?? SnapshotRenderer.foldedGroups(snapshot, flagging: flags, collapsingBulk: true)
        let duplicated = groups
            .filter { $0.value.count >= ambiguousLabelMinimum && !isSingleChain($0.value, in: snapshot) }
            // **畳まれる群は列挙しない**。実測(Apple マップの経路プランナー): 地図ピンの
            // `#VKPointFeature ×165` が注記の先頭を占めていた —— 木では1行 + ラベル索引に
            // 畳まれている群で、`#id` の書き先にもならない。判定は render と同じ
            // `SnapshotRenderer.foldedGroups`(2つ目の「畳まれるか」を作らない)。
            // **expandBulk の値では切り替えない**: 個別列挙させたい回でも、165 行ぶんの
            // 「一意でない」は読み手の役に立たない
            .filter { bulkFolded[$0.key] == nil }
            .sorted { groupPrecedes(key: $0.key, count: $0.value.count,
                                    otherKey: $1.key, otherCount: $1.value.count) }
        guard !duplicated.isEmpty else { return "" }
        let naming = cache?.selectorNaming(snapshot) ?? SelectorNaming(snapshot)
        return renderGroups(duplicated.map { (label: "#\($0.key)", matches: $0.value) },
                            naming: naming, in: snapshot,
                            fullHeader: "note: these ids are shared by multiple elements, so a plain"
                                + " #id selector cannot pick one uniquely. Write one of these instead"
                                + " (\"—\" = this element has no stable selector; use a labelled"
                                + " ancestor or a coordinate. \"~\" = index-based, so it breaks if"
                                + " the number of same-type siblings changes — usable, but the"
                                + " weakest of the three):",
                            shortHeader: "note: duplicate ids — write one of these instead"
                                + " (legend in the first snapshot's note):",
                            overflowNoun: "duplicate id", abbreviated: abbreviated, brief: brief)
    }

    /// 注記に並べる群の順序。件数の多い順で、**同数タイは key の昇順**。
    /// タイを決めないと順序が Dictionary の反復順(プロセスごとに変わる)に委ねられ、
    /// 同じ木でも実行ごとに並びが入れ替わる —— `ambiguousLabelsShown` で打ち切るので
    /// **どの群が出るか**まで変わる。**同一プロセス内では再現しない**ので、テストは
    /// この比較関数を直接固定する(注記の文字列を2回比べても差は出ない)
    static func groupPrecedes(key: String, count: Int, otherKey: String, otherCount: Int) -> Bool {
        count == otherCount ? key < otherKey : count > otherCount
    }

    /// 曖昧ラベル注記に並べる上限。**打ち切ったことは必ず言う**(黙って切ると
    /// 「これで全部」と読まれる)
    static let ambiguousLabelsShown = 5
    static let ambiguousMatchesShown = 6

    /// 同じラベルの群が**入れ子の一本鎖**か(容器とその中身が同じラベルを名乗る形)。
    /// 下限を2へ下げると、`button "自宅、追加"` とその子 `#IconImage-TitleLabel-SubtitleLabel`
    /// のようなラッパー対が全部鳴る —— どちらを掴んでも同じものなので曖昧ではない。
    /// `RefGuard.stackedRefs` が同じ理由で使っている除外と同型
    /// **前提が崩れる形が1つある**(実機 Android の YouTube で実測): 祖先が
    /// **画面規模の面**で、子孫が**その中の小さな操作子**のとき、「どちらを掴んでも同じ」は
    /// 成り立たない。実測 —— 広告再生中の `clickable "Skip" #player_overlays (0,136 1080x1683)`
    /// と `clickable "Skip" #skip_ad_button (888,1555 192x132)` が同じラベルを名乗り、
    /// 前者は再生面のトグル・後者は広告スキップで**別の動作**なのに、一本鎖なので曖昧警告が
    /// 出ず、`tap 'Skip'` は木の順序で**面のほう**へ解決する。
    ///
    /// 条件は3つとも要る(**コーパス全数で誤検知0**を測ってから入れた):
    /// ⑴ 群のうち**2つ以上が操作可能型** —— 片方が staticText なら触れても祖先が受け取るので
    ///   無害(大小を `interactive` から採るので 75 件の誤検知はそこで消えている。この guard 自体は
    ///   不変条件の明示で、外しても振る舞いは変わらない = 変異では殺せない)
    /// ⑵ 大きいほうの**中心が小さいほうの外**にある(中に入るなら撃つ場所が同じ)
    /// ⑶ 大きいほうが**画面規模**(`fullScreenContainerAreaRatio`)—— これが無いと
    ///   `and-browser_weektable` の入れ子リンク(面積比2倍)が鳴る。実測の witness は
    ///   画面の 72% を占める再生面で、比は約 72 倍
    static func isSingleChain(_ group: [ElementInfo], in snapshot: SnapshotResponse) -> Bool {
        guard let first = group.first else { return true }
        let chain = TapTargetGeometry.lineage(of: first, in: snapshot.elements)
        guard group.allSatisfy({ chain.contains($0.ref) }) else { return false }
        return !chainHidesADifferentTarget(group, in: snapshot)
    }

    /// 一本鎖でも「どちらを掴んでも同じ」が成り立たない形か(`isSingleChain` の doc 参照)
    static func chainHidesADifferentTarget(_ group: [ElementInfo],
                                           in snapshot: SnapshotResponse) -> Bool {
        func area(_ e: ElementInfo) -> Double { e.frame.width * e.frame.height }
        let interactive = group.filter { TapTargetGeometry.interactiveTypes.contains($0.type) }
        guard interactive.count >= 2,
              let big = interactive.max(by: { area($0) < area($1) }),
              let small = interactive.min(by: { area($0) < area($1) })
        else { return false }
        let screenArea = snapshot.screen.width * snapshot.screen.height
        guard screenArea > 0,
              area(big) >= screenArea * TapTargetGeometry.fullScreenContainerAreaRatio
        else { return false }
        let cx = big.frame.x + big.frame.width / 2
        let cy = big.frame.y + big.frame.height / 2
        let centreInsideSmall = small.frame.x <= cx && cx <= small.frame.x + small.frame.width
            && small.frame.y <= cy && cy <= small.frame.y + small.frame.height
        return !centreInsideSmall
    }

    /// 語を1文字も含まないラベル(記号・約物・空白だけ)。曖昧ラベル一覧の唯一の除外判定。
    /// 判定は Unicode の英数字(L\* / N\*)で、仮名・漢字・ハングルも「語」に含まれる ——
    /// 日本語アプリのラベルを丸ごと落とさないため、`isLetter` ではなく alphanumerics を使う
    static func isSymbolOnlyLabel(_ label: String) -> Bool {
        !label.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
