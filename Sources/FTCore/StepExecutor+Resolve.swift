// StepExecutor+Resolve.swift
// ロケータ解決(決定的)とテキスト照合・候補ヒント。本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

extension StepExecutor {

    // MARK: - ロケータ解決(決定的)

    /// label の一致品質。exact=完全一致、substring=部分一致(contains)。
    /// ハイブリッドで「primary の substring 解決」を「fallback の exact 解決」で上書きする判定に使う。
    /// id / type+index による一致は exact 扱い。
    public enum MatchQuality { case exact, substring }

    /// 戻り値: (要素, 使用したフォールバック)。プライマリで解決した場合フォールバックは nil
    /// strictForAssert: id も label もない(type+index のみの)フォールバックを除外する
    public static func resolve(step: FlowStep, in snapshot: SnapshotResponse,
                               strictForAssert: Bool = false) -> (ElementInfo, FlowLocator?)? {
        resolveDetailed(step: step, in: snapshot, strictForAssert: strictForAssert)
            .map { ($0.element, $0.usedFallback) }
    }

    /// resolve に label 一致品質(quality)を添えた版。ハイブリッドの偽陽性抑止に使う。
    public static func resolveDetailed(step: FlowStep, in snapshot: SnapshotResponse,
                                       strictForAssert: Bool = false)
        -> (element: ElementInfo, usedFallback: FlowLocator?, quality: MatchQuality)? {
        var chain: [(FlowLocator, isPrimary: Bool)] = []
        if let locator = step.locator { chain.append((locator, true)) }
        for fallback in step.fallbacks ?? [] {
            if strictForAssert, fallback.isWeakForAssert { continue }
            chain.append((fallback, false))
        }

        // **ステップの実効値を解決経路へ流す**(execute の入口で畳んである。nil = 既定 on)
        let inferring = step.containerInference ?? containerInferenceEnabled
        for (locator, isPrimary) in chain {
            if let (element, quality) = matchDetailed(locator, in: snapshot, inferring: inferring) {
                return (element, isPrimary ? nil : locator, quality)
            }
        }
        return nil
    }

    public static func match(_ locator: FlowLocator, in snapshot: SnapshotResponse) -> ElementInfo? {
        matchDetailed(locator, in: snapshot)?.0
    }

    public static func matchDetailed(_ locator: FlowLocator, in snapshot: SnapshotResponse,
                                     inferring: Bool = containerInferenceEnabled)
        -> (ElementInfo, MatchQuality)? {
        matchDetailed(locator, elements: snapshot.elements, inferring: inferring)
    }

    /// ロケータに一致する要素を 1 つ選ぶ。選択規則:
    /// 属性フィルタ(全て AND)で絞る → `[n]` 番目を採る → 相対ステップがあれば順に辿る。
    /// 相対セレクタ(`通知:rightSwitch`)では属性フィルタが**対象ではなく基準**を指す。
    public static func matchDetailed(_ locator: FlowLocator, elements: [ElementInfo],
                                     inferring: Bool = containerInferenceEnabled)
        -> (ElementInfo, MatchQuality)? {
        guard let matches = candidates(locator, elements: elements, inferring: inferring),
              !matches.isEmpty else {
            return nil
        }
        let index = locator.index ?? 0
        guard index < matches.count else { return nil }
        var current = matches[index]
        let baseQuality = Self.quality(of: current, for: locator)
        guard let steps = locator.relative, !steps.isEmpty else { return (current, baseQuality) }
        // 相対ステップの候補もスコープの中から採る(節の中は全部同じ pool で解決する)
        guard let pool = scopedPool(locator.scope, elements: elements) else { return nil }
        // 品質は**返す要素**の話なので、最後のステップの判定だけが残る
        // (基準や途中のステップを部分一致で書いても、最終的に掴んだ要素の一致品質とは無関係)
        var quality = MatchQuality.exact
        for step in steps {
            guard let next = resolveRelative(step, from: current, pool: pool) else { return nil }
            current = next.element
            quality = next.quality
        }
        return (current, quality)
    }

    /// 一致品質。**記法(部分一致かどうか)ではなく掴んだ要素**で判定する
    /// (`*ログイン*` が "ログインに失敗しました" を掴めば substring、"ログイン" を掴めば exact)。
    /// 読み手はハイブリッドの偽陽性抑止(fallback の exact を primary の substring より優先)だけ
    static func quality(of element: ElementInfo, for locator: FlowLocator) -> MatchQuality {
        guard let label = locator.label else { return .exact }
        return element.label == label ? .exact : .substring
    }

    /// 相対ステップ1つ分。フィルタ連鎖は `||` と同じく**候補集合の和**(Shirates 準拠)で、
    /// 節ごとに方向解決するのではなく**全節の候補を合わせてから方向で並べる**
    /// (`:right(.button||.switch)` = 「両者のうち最も近い1つ」。節の順は同着の並びにだけ効く)。
    /// フィルタ省略時は `.widget`(役割が確定した要素だけ = 容器やレイアウトノードを掴まない)
    static func resolveRelative(_ step: FlowRelativeStep, from anchor: ElementInfo,
                                pool: [ElementInfo]) -> (element: ElementInfo, quality: MatchQuality)? {
        let filters = (step.filter?.isEmpty ?? true)
            ? [FlowLocator(type: "widget")] : step.filter!
        var union: [(element: ElementInfo, filter: FlowLocator)] = []
        var seen: Set<Int> = []
        for filter in filters {
            for element in resolvedCandidates(filter, elements: pool) ?? [] {
                guard seen.insert(element.ref).inserted else { continue }
                union.append((element, filter))
            }
        }
        guard !union.isEmpty else { return nil }
        let ordered = directionalCandidates(union.map(\.element), anchor: anchor,
                                            direction: step.direction)
        // 序数は `:right(2)` が本線。`:right(.button&&[2])` はパースが step.ordinal へ畳むので、
        // ここに残る節ごとの `[n]` は「節で違う値を手書きした」場合だけ = 最初の1つを和集合の序数に使う。
        // 節自身が相対セレクタのときの index は基準の選択で消費済みなので見ない
        let filterIndex = filters.first { ($0.relative?.isEmpty ?? true) && $0.index != nil }?.index
        let ordinal = step.ordinal ?? ((filterIndex ?? 0) + 1)
        guard ordinal >= 1, ordinal <= ordered.count else { return nil }
        let picked = ordered[ordinal - 1]
        // 一致品質は**掴んだ要素を出した節**で判定する(和集合なので節は要素ごとに違う)
        let filter = union.first { $0.element.ref == picked.ref }?.filter ?? filters[0]
        return (picked, quality(of: picked, for: filter))
    }

    /// 節連鎖(`||`)が指す候補集合。**Shirates 準拠の和集合**で、順序は「節の順 → 節内のツリー順」、
    /// 同一要素(ref)は先に現れた節のものだけを残す(Shirates の filterBySelector と同じ規則)。
    /// 要素を1つ選ぶ経路(resolveDetailed)が「最初に解決した節」を採るのと優先順位が一致するので、
    /// `#id||ラベル` のヒール連鎖は和集合にしても先頭が変わらない。
    /// **節ごとの `[n]` はここでは見ない**(集合を数える用途では `.button[2]` も全 button を指す)
    public static func unionCandidates(_ chain: [FlowLocator], elements: [ElementInfo])
        -> [ElementInfo] {
        unionByClause(chain, elements: elements).flatMap(\.elements)
    }

    /// 「親子で重ねて数えている」ときだけ付ける案内。**直し方(型で絞る)まで書く** —
    /// これを知らないと `countIs("項目", 3)` が 6 を返す理由に辿り着けない(実際に踏んだ)
    static func nestingHint(_ matched: [ElementInfo], in all: [ElementInfo]) -> String {
        let outer = outermostCount(matched, in: all)
        guard outer != matched.count, outer > 0 else { return "" }
        // 外側だけに残る型が1つなら、そのまま書ける形で提案する
        let matchedRefs = Set(matched.map(\.ref))
        var nested: Set<Int> = []
        for element in matched {
            for descendant in descendants(of: element, in: all)
            where matchedRefs.contains(descendant.ref) { nested.insert(descendant.ref) }
        }
        let outerTypes = Set(matched.filter { !nested.contains($0.ref) }.map(\.type))
        let suggestion = outerTypes.count == 1 ? " (e.g. `.\(outerTypes.first!)&&…`)" : ""
        return ". **Parent and child are being counted as the same element** — narrowing by type gives \(outer)"
            + suggestion + ". A button and the label inside it are separate elements and both appear in the tree"
    }

    /// 数えた要素の中に**親子関係のもの**(ボタンとその内側の Text 等)が混ざっていないか。
    /// 返すのは「子孫を除いた件数」で、元の件数と違えばラベルだけで数えている疑いが濃い。
    /// **フレームワーク一般の性質**(Compose / SwiftUI / Flutter とも、ボタンとラベルが
    /// 別要素として両方ツリーに載る)なので、利用者は必ず一度は踏む。型で絞れば解決する
    public static func outermostCount(_ matched: [ElementInfo], in all: [ElementInfo]) -> Int {
        guard matched.count > 1 else { return matched.count }
        let matchedRefs = Set(matched.map(\.ref))
        var nested: Set<Int> = []
        for element in matched {
            for descendant in descendants(of: element, in: all)
            where descendant.ref != element.ref && matchedRefs.contains(descendant.ref) {
                nested.insert(descendant.ref)
            }
        }
        return matched.count - nested.count
    }

    /// 和集合を**節ごとの寄与に分けて**返す(countIs の失敗メッセージの内訳用)。
    /// 重複は先に現れた節に数えるので、**各節の件数の合計 = 和集合の総数**になる
    /// (合計が表示件数と合わないと、内訳がかえって混乱のもとになる)
    public static func unionByClause(_ chain: [FlowLocator], elements: [ElementInfo])
        -> [(clause: FlowLocator, elements: [ElementInfo])] {
        var result: [(clause: FlowLocator, elements: [ElementInfo])] = []
        var seen: Set<Int> = []
        for locator in chain {
            var mine: [ElementInfo] = []
            for element in resolvedCandidates(locator, elements: elements) ?? [] {
                guard seen.insert(element.ref).inserted else { continue }
                mine.append(element)
            }
            result.append((locator, mine))
        }
        return result
    }

    /// 節が指す候補集合。**相対ステップ付きは解決結果の 0 or 1 件**になる
    /// (`candidates` は属性フィルタしか見ないので、countIs のような「集合を数える」用途が
    /// `通知:rightSwitch` を基準の個数で数えてしまうのを防ぐ)。
    /// 相対ステップのフィルタ自身がさらに相対セレクタでもよい(連鎖は有限なので停止する)
    public static func resolvedCandidates(_ locator: FlowLocator, elements: [ElementInfo])
        -> [ElementInfo]? {
        guard locator.relative?.isEmpty ?? true else {
            return matchDetailed(locator, elements: elements).map { [$0.0] } ?? []
        }
        return candidates(locator, elements: elements)
    }

    /// スコープ連鎖(`#list >> ...`)を外側から順に適用した候補プール。
    /// 途中の容器が解決できなければ nil(= その節は不一致)
    static func scopedPool(_ scope: [FlowLocator]?, elements: [ElementInfo]) -> [ElementInfo]? {
        var pool = elements
        for scopeLocator in scope ?? [] {
            guard let (container, _) = matchDetailed(scopeLocator, elements: pool) else { return nil }
            pool = descendants(of: container, in: elements)
        }
        return pool
    }

    /// ロケータの属性フィルタに一致する全要素(スナップショットのツリー順)。
    /// **フィルタは全て AND**。一致ゼロなら空、絞り込み条件が1つも無ければ nil
    /// (スコープだけは条件として認める。`#list >> [2]` を書けるようにするため)。
    /// 相対ステップ(`relative`)と序数(`index`)はここでは見ない —
    /// 呼び手(matchDetailed)が基準を決めてから辿る。
    public static func candidates(_ locator: FlowLocator, elements: [ElementInfo],
                                  inferring: Bool = containerInferenceEnabled) -> [ElementInfo]? {
        guard var pool = scopedPool(locator.scope, elements: elements) else { return [] }
        if locator.hasNoFilter, locator.scope?.isEmpty ?? true { return nil }
        // 素の文字列は**完全一致**。部分一致は `*x*` 等で明示したときだけ
        func narrow(_ text: String?, _ mode: FlowMatchMode?, _ attribute: @escaping (ElementInfo) -> String?) {
            guard let text else { return }
            let mode = mode ?? .exact
            pool = pool.filter { mode.matches(attribute($0), text) }
        }
        if let type = locator.type {
            // エイリアス(input/widget)はここで実型集合へ展開する
            let types = Set(FlowTypeAlias.expand(type))
            pool = pool.filter { types.contains($0.type) }
        }
        // **`#x` は identifier だけでなく placeholder も引く**(2026-08-15 ユーザー指示)。
        // 入力欄は指す手段が経路で割れる: HTML の id は XCUITest が読む a11y には出ないが
        // placeholder は出る / Android は WebView の版で id と placeholder が入れ替わる
        // ([[webview-support]])。同じ欄が**エンジンやOS版によって指せたり指せなかったり**するのを
        // セレクタ側で吸収する。
        // **identifier が1件でも当たったらそちらだけ**(placeholder は id で引けなかったときの
        // 受け皿)。混ぜると `#x[2]` の序数や count が経路で変わる
        if let id = locator.id {
            let mode = locator.idMatch ?? .exact
            let byIdentifier = pool.filter { mode.matches($0.identifier, id) }
            pool = byIdentifier.isEmpty ? pool.filter { mode.matches($0.placeholder, id) } : byIdentifier
        }
        narrow(locator.label, locator.labelMatch) { $0.label }
        narrow(locator.value, locator.valueMatch) { $0.value }
        narrow(locator.placeholder, locator.placeholderMatch) { $0.placeholder }
        // checked は true のときだけ送られる = false は「オフ、または状態を持たない要素」
        if let checked = locator.checked { pool = pool.filter { ($0.checked ?? false) == checked } }
        if let enabled = locator.enabled { pool = pool.filter { $0.enabled == enabled } }
        // 除外条件(`text!=キャンセル`)は**肯定フィルタで絞ったあと**に引く。
        // 否定だけの節は上の hasNoFilter で既に nil を返しているので、ここには来ない
        for exclusion in locator.not ?? [] {
            let excluded = Set(candidates(exclusion, elements: pool, inferring: inferring)?.map(\.ref) ?? [])
            if excluded.isEmpty { continue }
            pool = pool.filter { !excluded.contains($0.ref) }
        }
        // **座標が壊れている要素は候補にしない**(hasClampedCoordinates 参照)。
        // 最後に引くのは、絞り込みで1〜数件になってからでないと走査が無駄になるため。
        // **他に候補が無いときも引く** —— 残すと「見つかったのにタップが別の場所へ落ちる」
        // 沈黙の誤りになり、`exist` も画面外の要素で真を返す(契約は「現在画面のみ判定」)。
        // 計算量は O(|pool| × |elements|) だが、要素数の多い WebView 画面(200 程度)でも
        // 数万回の矩形比較 = 1ms 未満で、snapshot 1枚の往復(数百 ms)に対して無視できる。
        // 群ごとに1回だけ判定する形へ畳むこともできるが、規則の実装が2つに割れる方が高くつく
        return pool.filter { !Self.hasClampedCoordinates($0, in: elements, inferring: inferring) }
    }

    /// 否定系アサート(`*Not` / `*IsEmpty` / `*IsNotEmpty`)の判定。
    /// **可視性は見ない**(見えていないことは画面照合できない)。text/value の別は呼び手が解決済み
    /// 否定系・空判定の充足。**肯定系と同じ正規化を通す**(2026-08-09) ——
    /// ここだけ素の比較のままだと、`textIs("x")` は通るのに `textIsNot("x")` も通る、という
    /// 矛盾した組が作れてしまう(実データにゼロ幅が1文字あるだけで起きる)。
    /// 空判定も同様: **ゼロ幅だけの文字列は「空」**(見た目が空だから)。
    /// `strict: true` のときは一切正規化しない
    static func negativeAssertSatisfied(_ assert: String, actual: String?,
                                        expected: String?,
                                        normalization: TextNormalization = .text) -> Bool {
        let text = normalization.apply(actual ?? "")
        // 正規表現のパターンは書き換えない(肯定系と同じ規約)
        let isRegex = assert == "textMatchesNot" || assert == "valueMatchesNot"
        let want = isRegex ? (expected ?? "") : normalization.apply(expected ?? "")
        switch assert {
        case "textIsEmpty", "valueIsEmpty": return text.isEmpty
        case "textIsNotEmpty", "valueIsNotEmpty": return !text.isEmpty
        case "textStartsWithNot", "valueStartsWithNot":
            return !text.hasPrefix(want)
        case "textContainsNot", "valueContainsNot":
            return !text.contains(want)
        case "textEndsWithNot", "valueEndsWithNot":
            return !text.hasSuffix(want)
        case "textMatchesNot", "valueMatchesNot":
            return text.range(of: want, options: .regularExpression) == nil
        default:   // textNotEquals / valueNotEquals
            return actual == nil ? expected != nil : text != want
        }
    }

    /// アサート種別ごとの一致判定。戻り値は「画面上で実際に一致した文字列」(occlusion-guard 用)、
    /// 不一致なら nil。textMatches は**部分一致の正規表現**(^...$ を書けば全体一致になる)
    /// テキスト比較の判定。**正規化を通す**(2026-08-09): 以前は素の `==` / `contains` で、
    /// 実データに紛れたゼロ幅1文字で `textIs` が落ちていた —— セレクタ側には正規化があるのに
    /// アサーション側には無く、**同じ画面について経路ごとに答えが違う**状態だった。
    ///
    /// 既定は `.text`(見た目が完全に一致していれば同じ)。`strict: true` を明示したときだけ
    /// `.strict`(一切正規化しない)。**返す文字列は正規化前の actual 由来**にする ——
    /// occlusion-guard は画面と照合するので、実際に描かれている文字列でなければ意味が無い
    public static func matchedText(_ actual: String?, expected: String, assert: String,
                                   normalization: TextNormalization = .text) -> String? {
        guard let actual else { return nil }
        // 日付書式だけは書式文字列であって「テキスト」ではないので正規化しない
        if assert == "textMatchesDateFormat" || assert == "valueMatchesDateFormat" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = expected
            return formatter.date(from: actual) != nil ? actual : nil
        }
        let a = normalization.apply(actual)
        // 正規表現のパターンは書き換えない(FlowMatchMode.matches と同じ規約)
        let e = (assert == "textMatches" || assert == "valueMatches")
            ? expected : normalization.apply(expected)
        switch assert {
        case "textContains", "valueContains":
            return a.contains(e) ? expected : nil
        case "textStartsWith", "valueStartsWith":
            return a.hasPrefix(e) ? expected : nil
        case "textEndsWith", "valueEndsWith":
            return a.hasSuffix(e) ? expected : nil
        case "textMatches", "valueMatches":
            guard let range = a.range(of: e, options: .regularExpression) else { return nil }
            return String(a[range])
        default:
            return a == e ? expected : nil
        }
    }

    /// 不一致で失敗するときに添える「**どちらの規則なら一致したか**」(2026-08-09 のユーザー指示)。
    ///
    /// 読み手の次の一手がこれで決まる:
    ///   normal ○ / strict ×  → 差は不可視文字か空白の種類だけ。`strict: true` を外すか期待値を直す
    ///   両方 ×               → 本当に違う文字列。期待値そのものを見直す
    ///   normal × / strict ○  → 起こらない(normal は strict より緩い)。出たら正規化の実装が壊れている
    public static func normalizationVerdict(actual: String?, expected: String,
                                            assert: String) -> String {
        let normal = matchedText(actual, expected: expected, assert: assert, normalization: .text)
        let strict = matchedText(actual, expected: expected, assert: assert, normalization: .strict)
        let mark = { (matched: String?) in matched != nil ? "matches" : "does not match" }
        var verdict = " (normalized comparison: \(mark(normal))"
            + " / strict comparison: \(mark(strict)))"
        if normal != nil, strict == nil {
            verdict += " — they differ only by characters that do not change how the text looks"
                + " (invisible marks, or a non-breaking space); drop strict: true, or make the"
                + " expected value match exactly"
        }
        return verdict
    }

    /// 解決できなかったロケータに「惜しい候補」を最大3件添える(失敗メッセージ用)。
    /// 優先度: id/ラベルの近さ(強い一致 > 操作可能 > 文書順)→ 同じ型。1件も無ければ nil(黙って何も足さない)
    ///
    /// id/ラベルの近さの選定は MCP(`MCPServer.similarLabelsHint`)と共有する `FTCore.SimilarLabels`
    /// (2026-08-15 に置き換え)。旧実装(部分文字列一致だけ・装飾葉を除かず・文書順の先着3件)は
    /// MCP が 2026-08-10 に同じ形を書き直した理由をそのまま引き継いでいた ——
    /// 地図 POI のような装飾要素が短い CJK 語の緩い一致で枠を埋め、実在する操作可能要素を
    /// 1件も出せない画面がある(実測は MCPServer+Hints.swift の similarLabelsHint 参照)。
    /// **型による候補集めはここに残す**(SimilarLabels は id/ラベルの近さしか見ないため)
    static func candidateHint(for step: FlowStep, in snapshot: SnapshotResponse) -> String? {
        guard let locator = step.locator else { return nil }
        let elements = snapshot.elements
        var picked: [ElementInfo] = []

        func add(_ candidates: [ElementInfo]) {
            for candidate in candidates where !picked.contains(where: { $0.ref == candidate.ref }) {
                picked.append(candidate)
                if picked.count >= 3 { return }
            }
        }
        func nonEmpty(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
        let labelTarget = nonEmpty(locator.label), idTarget = nonEmpty(locator.id)
        if labelTarget != nil || idTarget != nil {
            add(SimilarLabels.candidates(labelTarget: labelTarget, idTarget: idTarget, in: snapshot)
                .map(\.element))
        }
        if let type = locator.type, picked.count < 3 {
            // エイリアス(.input / .widget)も実型集合へ展開して候補を挙げる
            let types = Set(FlowTypeAlias.expand(type))
            add(elements.filter { types.contains($0.type) })
        }
        var hints: [String] = []
        if !picked.isEmpty {
            let summaries = picked.prefix(3).map { element -> String in
                var parts = [element.type]
                if let id = element.identifier, !id.isEmpty { parts.append("#\(id)") }
                // ゼロ幅文字は落とす(見た目が正しいのに一致しない事故を防ぐ)が、これは
                // **「型 #id "ラベル」の複合名指し」**であって単一のセレクタ式ではない。
                // ラベルは24字で切り詰めるので完全一致の保証も無い(SnapshotRenderer.truncate)——
                // `TapTargetGeometry.describe` と同じ「後者」(単なる名指し)扱いで、記法として
                // 読まれる先頭文字のエスケープ(SelectorNaming.needsEscaping)は通していない
                if let label = element.label.map(FlowMatchMode.normalizeInvisibleCharacters),
                   !label.isEmpty {
                    parts.append("\"\(SnapshotRenderer.truncate(label, 24))\"")
                }
                return parts.joined(separator: " ")
            }
            hints.append("near matches: \(summaries.joined(separator: " / "))")
        }
        if let hint = partialMatchHint(for: locator, in: elements) { hints.append(hint) }
        if let hint = clampedStackHint(for: locator, in: elements) { hints.append(hint) }
        // 候補の区切りが " / " なので、ヒント同士は別の記号で割る(読み手が機械でも人でも混ざらない)
        return hints.isEmpty ? nil : hints.joined(separator: "。")
    }

    /// **候補から外した理由**を書く(`hasClampedCoordinates` 参照)。これが無いと、画面外の行を
    /// ラベルで指した利用者には「在るのに見つからない」としか見えない —— 実際にはツリーには
    /// 在り、**座標だけが壊れている**ので候補から外した、というのが起きていること。
    /// **黙って消すのが最悪**なので、消したときは必ずここで説明する
    static func clampedStackHint(for locator: FlowLocator, in elements: [ElementInfo]) -> String? {
        // 「フィルタには一致するが座標が壊れている」要素だけを数える(素の一致は上の近傍候補が出す)
        let broken = elements.filter { element in
            guard hasClampedCoordinates(element, in: elements) else { return false }
            if let id = locator.id, element.identifier != id { return false }
            if let label = locator.label, element.label != label { return false }
            return locator.id != nil || locator.label != nil
        }
        guard let sample = broken.first else { return nil }
        let frame = sample.frame
        // 同じ場所に積み上がっている数(**sample と同じ矩形のものだけ**を数える。
        // 画面に複数のスタックがあっても、利用者が指した要素の話に閉じる)
        let stacked = elements.filter { Self.sameFrame($0.frame, frame) && $0.depth == sample.depth }
        return "it is in the tree but its coordinates are unusable"
            + " — \(stacked.count) elements are"
            + " stacked at the same spot (\(Int(frame.x)),\(Int(frame.y))"
            + " \(Int(frame.width))x\(Int(frame.height)));"
            + " the framework clamps offscreen descendants to the container origin,"
            + " so scroll it into view first (scrollTo / tap(scroll:))"
    }

    /// 完全一致の指定が外れたが**部分一致なら在る**ときに書き方を示す
    /// (素の文字列は完全一致なので、部分一致で拾いたいなら記法で明示する必要がある)。
    ///
    /// **3条件そろったときだけ出す**のが要点 —— 「素の完全一致指定」「完全一致は無い」
    /// 「部分一致なら在る」。無条件に「\* で囲め」と言うと、既に `*…*` を渡した相手に同じものを
    /// 勧め、`#id` 指定にはラベル部分一致(`*foo*`)という**誤った記法**を勧める
    /// (2026-08-07 に MCP 側の無条件版で実測。id の部分一致は `#*foo*`)。
    /// **MCP もこれを呼ぶ**(ftester-mcp/MCPServer の scrollTo/waitFor の失敗文)ので public
    public static func partialMatchHint(for locator: FlowLocator,
                                        in elements: [ElementInfo]) -> String? {
        if let label = locator.label, !label.isEmpty,
           (locator.labelMatch ?? .exact) == .exact,
           !elements.contains(where: { $0.label == label }),
           elements.contains(where: { ($0.label ?? "").contains(label) }) {
            return "present as a partial match: writing \"*\(label)*\" would find it"
        }
        // id も同じ形で拾う。**記法は `#*foo*`**(docs/design.md の idContains)であって
        // `*foo*` ではない —— `*foo*` はラベルの部分一致なので id には一生当たらない
        if let id = locator.id, !id.isEmpty,
           (locator.idMatch ?? .exact) == .exact,
           !elements.contains(where: { $0.identifier == id }),
           elements.contains(where: { ($0.identifier ?? "").contains(id) }) {
            return "present as a partial id match: writing \"#*\(id)*\" would find it"
        }
        return nil
    }

    /// 要素の子孫(スナップショットは pre-order + 元ツリーの depth を保つため、
    /// 直後から depth がその要素以下になるまでが子孫。3 ブリッジとも同じ規約で組み立てる
    /// [BridgeRouter.collect / InAppSnapshot.collect / SnapshotBuilder.collect]。
    /// 中間ノードのフィルタや上限打ち切りは pre-order を崩さないのでこの判定は保たれる)
    public static func descendants(of element: ElementInfo, in elements: [ElementInfo]) -> [ElementInfo] {
        guard let start = elements.firstIndex(where: { $0.ref == element.ref }) else { return [] }
        var result: [ElementInfo] = []
        var index = elements.index(after: start)
        while index < elements.endIndex, elements[index].depth > element.depth {
            result.append(elements[index])
            index = elements.index(after: index)
        }
        return result
    }

    /// 相対セレクタ(`通知:rightSwitch`)の選択規則。**この 1 箇所が唯一の解釈者**で、
    /// 仕様は次の3条件のみ(調整値・閾値を持たない = 同じ画面なら常に同じ順序を返す):
    ///  1. 帯: 候補の中心が、基準の frame をその軸方向に無限に伸ばした帯に入る
    ///     (right/left なら中心 y が anchor の y..y+height、above/below なら中心 x が x..x+width)
    ///  2. 向き: 候補の中心が基準の中心よりその方向にある
    ///  3. 順序: 条件を満たすものを方向軸の中心間距離の昇順に並べる。同距離はツリー順
    /// 戻り値が空 = **解決失敗**。条件を満たす候補が無いとき「最も近いものを返す」ことはしない
    /// (レイアウトが変わったときに黙って別要素を掴ませないため)。序数(`:right(2)`)はこの並びの n 番目。
    /// 基準自身は候補から除く。画面外要素は frame が丸められる環境があるため可視要素にのみ有効。
    static func directionalCandidates(_ candidates: [ElementInfo], anchor: ElementInfo,
                                      direction: FlowDirection) -> [ElementInfo] {
        let base = anchor.frame
        var scored: [(element: ElementInfo, distance: Double, order: Int)] = []
        for (order, candidate) in candidates.enumerated() where candidate.ref != anchor.ref {
            let frame = candidate.frame
            let inBand: Bool
            let ahead: Bool
            let distance: Double
            switch direction {
            case .right, .left:
                inBand = frame.centerY >= base.y && frame.centerY <= base.y + base.height
                ahead = direction == .right
                    ? frame.centerX > base.centerX : frame.centerX < base.centerX
                distance = abs(frame.centerX - base.centerX)
            case .above, .below:
                inBand = frame.centerX >= base.x && frame.centerX <= base.x + base.width
                ahead = direction == .below
                    ? frame.centerY > base.centerY : frame.centerY < base.centerY
                distance = abs(frame.centerY - base.centerY)
            }
            guard inBand, ahead else { continue }
            scored.append((candidate, distance, order))
        }
        return scored
            .sorted { $0.distance == $1.distance ? $0.order < $1.order : $0.distance < $1.distance }
            .map(\.element)
    }
}
