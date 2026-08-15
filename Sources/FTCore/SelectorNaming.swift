// SelectorNaming.swift
// 「この要素をセレクタとしてどう綴るか」の唯一の実装。**MCP(ft_tap 等の推奨セレクタ・注記)と
// DSL/StepExecutor(自己修復の書き戻し)の両方が使う** —— 別々に持つと、同じ画面で
// 「書けるセレクタ」の判定が食い違う(幾何を TapTargetGeometry へ寄せたのと同じ理由)。
// 元は ftester-mcp/MCPServer+Hints.swift にあったが、自己修復(StepExecutor+Actions.swift)が
// 修復結果を利用者の .swift ソースへ書き戻す経路でも同じ「書けるか」の判定が要るため
// FTCore へ移した(2026-08-15)。MCPServer 側は typealias + 転送だけを残す
// (RefGuard.swift が TapTargetGeometry/OcclusionGeometry へ転送しているのと同じ形)。

import Foundation

/// セレクタの壊れにくさ。**綴りからは判定しない**(2026-08-10)。
/// 位置で選ぶ式は必ずしも `[n]` を含まない —— `#容器 >> .clickable` は「容器の中の最初の
/// clickable」で、`[1]` を書いたのと同じ意味だが綴りに添字が出ない。
/// 綴りで見ると**この形だけが「安定」と誤って印無しになる**ので、
/// どの候補から採ったか(id/ラベル か スコープ記法 か)を持ち回る
public enum Durability {
    /// `#id` / 一意ラベル。木が変わっても指し続ける
    case stable
    /// `#container >> .type[n]`。同じ型の兄弟が1つ増減すると別要素を指す
    case indexed

    /// 一覧に添える印。安定側は無印(印が付くのは注意が要るものだけ、が読みやすい)
    public var mark: String { self == .indexed ? "~" : "" }

    /// 1つだけ返すとき(ft_tap の戻り値)の但し書き
    public var caution: String {
        self == .indexed
            ? " — index-based, so it breaks if the number of same-type siblings changes;"
                + " prefer having the app expose an id"
            : ""
    }
}

/// **シナリオにそのまま書けるセレクタ**を1つ決める。書けないときは nil ——
/// 「無い」を黙らず言うのが要点で、ref はセッション限りの番号なのでシナリオには書けない。
///
/// 優先順(B-1・E-1・自己修復の書き戻しで共有。**2つ目の実装を作らない**):
///   1. 画面で一意な `#id` —— いちばん短く、他の画面でも通りやすい
///   2. 画面で一意なラベル —— id を持たない要素でも書ける
///   3. スコープ記法 `#容器 >> .型[n]` —— id を持つ一意な祖先があるときだけ
///   4. それ以外は nil
///
/// **一意性は「今撮った画面の中で」**。他の画面まで保証はできないので、そこは
/// ft_dry_run(SelectorInventory の突き合わせ)と実行に委ねる
public struct SelectorNaming {
    private let idCounts: [String: Int]
    private let labelCounts: [String: Int]
    /// 「型 × ラベル」の出現数。**候補を組む前のゲート**で、これが 1 のときだけ
    /// `.型&&ラベル` を試す —— 数え上げは木1周(O(N))で済むのに対し、候補の検証は
    /// `matchDetailed` + `resolvedCandidates` の2周を候補ごとに払う。
    /// 入れ忘れると注記1本の生成が実アプリ画面で 29ms → 116ms になる(2026-08-12 に実測)
    private let typeLabelCounts: [String: Int]

    public init(_ snapshot: SnapshotResponse) {
        var ids: [String: Int] = [:]
        var labels: [String: Int] = [:]
        var typeLabels: [String: Int] = [:]
        for e in snapshot.elements {
            if let id = e.identifier, !id.isEmpty { ids[id, default: 0] += 1 }
            let label = SnapshotRenderer.displayText(e.label ?? "")
            if !label.isEmpty {
                labels[label, default: 0] += 1
                typeLabels[Self.typeLabelKey(e.type, label), default: 0] += 1
            }
        }
        idCounts = ids
        labelCounts = labels
        typeLabelCounts = typeLabels
    }

    /// 型名とラベルの区切りは**要素の文字に現れない値**を使う(型名に混ざると別の組を
    /// 同一視する)
    static func typeLabelKey(_ type: String, _ label: String) -> String {
        "\(type)\u{0}\(label)"
    }

    /// スコープの中でそのラベル(と 型×ラベル)が何件あるか。**スコープを跨いで数えない**
    /// のがここの要点 —— 画面全体では重複するラベルでも、容器の中では一意なことが多い。
    /// 走査は候補を組む直前の1回だけで、`uniqueScopeElement` が nil を返す要素では走らない。
    /// **scope 要素は呼び出し元(candidates)がそのまま渡す** —— id 文字列で受けて
    /// ここで `first(where:)` に掛け直すと、`uniqueScopeElement` が既に歩いた祖先探索を
    /// もう一度 O(N) で歩き直すことになる
    static func labelCountsInScope(_ scope: ElementInfo, of element: ElementInfo,
                                   in snapshot: SnapshotResponse,
                                   label: String) -> (plain: Int, typed: Int) {
        var plain = 0, typed = 0
        for e in StepExecutor.descendants(of: scope, in: snapshot.elements)
        where SnapshotRenderer.displayText(e.label ?? "") == label {
            plain += 1
            if e.type == element.type { typed += 1 }
        }
        return (plain, typed)
    }

    /// ラベルを素で書くと記法として読まれてしまう形か。`=` 逃がしはこのときだけ足す ——
    /// 常に両方を候補に入れると、**当たる方が先に通るので結果は同じなのに検証を2倍払う**
    /// 判定は2種類ある。**片方だけでは足りない**:
    /// ① 意味が変わる形(`#`/`.` 始まり・演算子)—— 往復はするが別のフィルタとして読まれる
    /// ② 綴りが往復しない形(前後の空白など)—— 意味は同じだが印字とコードが食い違う
    ///    (実測: `and-place_expanded` にラベルが空白2文字だけの要素がある)
    public static func needsEscaping(_ label: String) -> Bool {
        guard let first = label.first else { return false }
        if "#.=!*".contains(first) { return true }
        if ["&&", ">>", "||", "[", "]", "(", ")", "|"].contains(where: label.contains) {
            return true
        }
        // **`asWritten` は使わない**: あれは空になったとき元の文字列へ落とすので、
        // 「空へ潰れる = いちばん往復しない形」を素通りさせる(実測: ラベルが
        // `" · "` や空白だけの要素)。ここは素の往復をそのまま見る
        let parsed = FTSelector.parse(label)
        return FTSelector.serialize(primary: parsed.primary, fallbacks: parsed.fallbacks) != label
    }

    /// **勧める前に自分で引いてみる**(2026-08-09。実アプリ 18 枚へ当てて発覚): 候補を
    /// 組み立てただけでは書けているか分からない —— ラベルを `"…"` で囲んで出していた版は
    /// 引用符ごと literal になって**1件も当たらなかった**。記法の綴じ(先頭が `#`/`.`、
    /// `>>` や `||` を含む等)は場合分けで潰しきれないので、DSL 本体で解決して
    /// **当人が返ることを確かめてから**返す
    public func selector(for element: ElementInfo, in snapshot: SnapshotResponse) -> String? {
        graded(for: element, in: snapshot)?.selector
    }

    /// `graded(for:in:)` のメモ化。**キーは ref**——この SelectorNaming は init に渡した
    /// 1つの snapshot に閉じている前提なので ref だけで一意に定まる(呼び出し規約:
    /// graded(for:in:) に渡す snapshot は必ず init と同じ木。既存の呼び出し元は全てこの
    /// 規約を守っている——別の木を渡すと ref が衝突し別要素の答えを返す)。
    /// class にして struct 自体は値型のまま(let で受けられる)保つ——`mutating` にすると
    /// 既存の `let naming = SelectorNaming(...)` 呼び出し元が軒並みコンパイルエラーになる
    private final class GradedCache {
        var storage: [Int: (selector: String, durability: Durability)?] = [:]
        /// テスト用: 実際に計算した回数(キャッシュヒットは数えない)
        var computeCount = 0
    }
    private let gradedCache = GradedCache()

    /// テスト用: このインスタンスで graded が実際に計算された回数
    public var gradedComputeCount: Int { gradedCache.computeCount }

    /// セレクタと**その耐久性**。「書ける」と「壊れにくい」は別物で、同じ一覧に混ぜると
    /// 生成器は先頭を採るだけになる(2026-08-10)。`#id` と一意ラベルは木が変わっても
    /// 指し続けるが、`#container >> .type[n]` の `[n]` は**同じ型の兄弟が1つ増減しただけで
    /// 別要素を指す**ので、シナリオに書くと静かに壊れる。
    /// **同じ要素は木の中で1回しか採番しない**(2026-08-12): 曖昧ラベルと重複 id の両方の
    /// 群に出る要素(実測: `#TitleLabel` ×3 と `"経路"` ×3 が要素を共有)を、呼び出し元が
    /// 同じインスタンスを使い回せば二重に検証しない
    public func graded(for element: ElementInfo,
                       in snapshot: SnapshotResponse) -> (selector: String, durability: Durability)? {
        if let cached = gradedCache.storage[element.ref] { return cached }
        gradedCache.computeCount += 1
        let result = computeGraded(for: element, in: snapshot)
        gradedCache.storage[element.ref] = result
        return result
    }

    private func computeGraded(for element: ElementInfo,
                in snapshot: SnapshotResponse) -> (selector: String, durability: Durability)? {
        // **検査は耐久性で選ぶ**: `.stable` は「位置に依存しない」という意味なので、
        // 候補が2件以上あってはならない(先頭一致で通してしまうと、群の1件目にだけ
        // 嘘の助言が出る)。`.indexed` は添字で1つに絞る式なので `picksExactly` が正しい
        // —— `resolvedCandidates` は添字を適用する前の列で、必ず複数になる
        func holds(_ selector: String, _ durability: Durability) -> Bool {
            durability == .indexed
                ? Self.picksExactly(element, with: selector, in: snapshot)
                : Self.picksOnlyOne(element, with: selector, in: snapshot)
        }
        for candidate in candidates(for: element, in: snapshot)
        where holds(candidate.selector, candidate.durability) {
            // **勧める形と書かれる形を揃える**(2026-08-10): 下書きは locator を
            // `FTSelector.serialize` で書き戻すので、`[1]` のような冗長な節はそこで落ちる。
            // 勧めた文字列をそのまま出すと「注記は `.clickable[1]`、コードは `.clickable`」
            // という食い違いになり、1箇所で決める意味が無くなる
            let written = Self.asWritten(candidate.selector)
            let agreed = holds(written, candidate.durability)
            return (agreed ? written : candidate.selector, candidate.durability)
        }
        return nil
    }

    /// 優先順に並べた候補(採否は graded(for:in:) が実際に引いて決める)。
    /// **耐久性は候補の出所で決める** —— 綴りを見ても分からない(Durability のコメント参照)
    private func candidates(for element: ElementInfo,
                            in snapshot: SnapshotResponse)
        -> [(selector: String, durability: Durability)] {
        var out: [(selector: String, durability: Durability)] = []
        if let id = element.identifier, !id.isEmpty, idCounts[id] == 1 {
            out.append(("#\(id)", .stable))
        }
        // **切り詰め表示になるラベルは候補にしない**: 40字超は一覧に "…" 付きで出るので、
        // 読み手が写した完全一致は必ず外れる(SnapshotRenderer.truncatedLabelNote と同じ理由)。
        // **改行を空白へ畳んでから使う**(2026-08-12): 改行入り a11y ラベル(実測: Safari の
        // 広告リンク)を素で勧めると Swift の1行文字列リテラルに書けない。畳んだ文字列は
        // `.selector` 照合(空白を種類問わず畳んで比較)で元のラベルに一致し続けるので安全
        let label = SnapshotRenderer.displayText(element.label ?? "")
        let writableLabel = !label.isEmpty && label.count <= SnapshotRenderer.labelDisplayLimit
        // **素の形を先に置く**(順序を入れ替えない): `asWritten` は逃がしを外した形を返すので、
        // 逃がし形を先に採ると「勧めた文字列」と「下書きに書かれる文字列」が食い違う
        // (実測: ラベル `" ·"` で `= ·` を先に置いたら、注記は `" ·"`・コードは `"·"` になった)。
        // 逃がしは**素で書けない形のときだけ**後ろに足す —— 常に両方入れると、
        // 当たる方が先に通るので結果は同じなのに候補の検証を2倍払う
        let labelForms = Self.needsEscaping(label) ? [label, "=\(label)"] : [label]
        if writableLabel, labelCounts[label] == 1 {
            out += labelForms.map { ($0, .stable) }
        }
        // **ラベルが重複していても、まず絞ってから索引に落とす**(2026-08-12 の実アプリ監査)。
        // ここが無かった版は「一意な id も一意なラベルも無い」を即 `#容器 >> .型[n]` に
        // 落としていた —— 実測(Google マップの検索候補)では `#typed_suggest_container >>
        // .clickable[3]` しか書けず、**候補の件数が変わると別の駅を選ぶ**。
        // `&&`(AND 合成)と `>>`(スコープ)は DSL の記法にあり、どちらも位置に依存しない。
        // **既存の提案は動かさない** —— 上の `#id` / 一意ラベルより後、索引形より前に置く
        // **数え上げで足切りしてから検証する**: 候補1つの検証は木2周(`matchDetailed` と
        // `resolvedCandidates`)で、当たらない候補まで並べると注記の生成が実アプリ画面で
        // 4倍になる(2026-08-12 に実測して入れ直した)。数え上げは init の1周で済む
        if writableLabel, typeLabelCounts[Self.typeLabelKey(element.type, label)] == 1 {
            out += labelForms.map { (".\(element.type)&&\($0)", .stable) }
        }
        // 祖先の walk は1回だけ払い、得た scope 要素をラベル系候補と indexed 候補の
        // 両方へ使い回す(public な `uniqueScopeID`/`scopedSelector` は他ファイル・テストが
        // 呼ぶのでシグネチャ不変)
        let scopeElement = Self.uniqueScopeElement(for: element, in: snapshot, idCounts: idCounts)
        if writableLabel, let scopeElement, let scope = scopeElement.identifier {
            let inScope = Self.labelCountsInScope(scopeElement, of: element, in: snapshot, label: label)
            if inScope.plain == 1 {
                out += labelForms.map { ("#\(scope) >> \($0)", .stable) }
            }
            if inScope.typed == 1 {
                out += labelForms.map { ("#\(scope) >> .\(element.type)&&\($0)", .stable) }
            }
        }
        // **長すぎるラベルは「書けない」ではなく「部分一致でなら書ける」**(2026-08-15 の外部評価)。
        // ここが無い版は、40字超のラベルしか手掛かりが無い要素を**一足飛びに索引形へ落として**
        // いた(索引形すら作れなければ「安定セレクタが無い」)。実際には木に印字されている
        // 先頭部分で `*断片*` が書け、しかも**位置に依存しない** = 索引形より強い。
        // 断片は注記(`truncatedLabelNote`)と**同じ切り出し規則**を通す ——
        // 勧める断片が2つの経路で食い違うと、読み手はどちらが正しいか判断できない。
        // 長さは**木が印字する範囲(labelDisplayLimit)**に限る: それより先は読み手が
        // 出力から確かめられないので、当たっても根拠を見せられない。
        // 一意でなければ `picksOnlyOne` が落として索引形へ進む = 従来の挙動に戻るだけ
        // **絞り方は完全一致ラベルと同じ梯子を辿る**(素 → 型 → スコープ → スコープ+型)。
        // 素だけだと、行そのものと中の staticText が同じ文言を持つ形(実測:
        // ios-place_guides_scrolled の `#PlaceCollectionCell`)で必ず2件に当たり、
        // **長ラベルの行がひとつも救えない**
        if !writableLabel, !label.isEmpty {
            let fragment = SnapshotRenderer.partialMatchFragment(
                String(label.prefix(SnapshotRenderer.labelDisplayLimit)))
            if !fragment.isEmpty {
                let contains = "*\(fragment)*"
                out.append((contains, .stable))
                out.append((".\(element.type)&&\(contains)", .stable))
                if let scopeElement, let scope = scopeElement.identifier {
                    out.append(("#\(scope) >> \(contains)", .stable))
                    out.append(("#\(scope) >> .\(element.type)&&\(contains)", .stable))
                }
            }
        }
        // indexed は最後の砦なので writableLabel を問わず試す
        if let scopeElement,
           let indexed = Self.scopedSelector(scope: scopeElement, for: element, in: snapshot) {
            out.append((indexed, .indexed))
        }
        return out
    }
}

public extension SelectorNaming {

    /// このセレクタが**その要素ただ1つ**を選ぶか。判定は DSL 本体(`matchDetailed`)に委ねる ——
    /// `resolvedCandidates` は `[n]` を適用する前の候補列なので、ここで使うと
    /// 添字付きのスコープ記法を「曖昧」と誤判定する。
    /// フォールバック(`a||b`)を含む式は「1つを選ぶ」と言えないので採らない
    static func picksExactly(_ element: ElementInfo, with selector: String,
                             in snapshot: SnapshotResponse) -> Bool {
        let parsed = FTSelector.parse(selector)
        guard parsed.fallbacks.isEmpty else { return false }
        return StepExecutor.matchDetailed(parsed.primary,
                                          elements: snapshot.elements)?.0.ref == element.ref
    }

    /// **その要素**を選び、かつ**候補が1件しかない**か。`picksExactly` は `matchDetailed` の
    /// 先頭一致を見るだけなので、**曖昧な式でも先頭の要素に対しては true を返す** ——
    /// 添字なしの式(`.型&&ラベル` など)をそれだけで採ると、群の1件目にだけ
    /// 「一意に指せる」と嘘の助言を出す(2026-08-12 に `MCPWritableSelectorTests` が捕まえた)。
    /// **`[n]` を含む式には使わない**: `resolvedCandidates` は添字を適用する前の候補列なので、
    /// 添字付きのスコープ記法を「曖昧」と誤判定する(`picksExactly` のコメント参照)
    static func picksOnlyOne(_ element: ElementInfo, with selector: String,
                             in snapshot: SnapshotResponse) -> Bool {
        guard picksExactly(element, with: selector, in: snapshot) else { return false }
        let parsed = FTSelector.parse(selector)
        return StepExecutor.resolvedCandidates(parsed.primary, elements: snapshot.elements)?.count == 1
    }

    /// 画面内の id 出現回数。**uniqueScopeID とページャ案内(pagerScrollFrameHint)が共有する
    /// 唯一の数え方** —— 別々に書くと「一意」の定義がずれる
    static func idCounts(in snapshot: SnapshotResponse) -> [String: Int] {
        var counts: [String: Int] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            counts[id, default: 0] += 1
        }
        return counts
    }

    /// `uniqueScopeID` / `scopedSelector` が共有する探索本体。**要素そのものを返す**のは
    /// `scopedSelector` 側の `snapshot.elements.first(where:)` 再検索(2つ目の O(N))を
    /// 無くすため —— 見つけた祖先を id 経由で index-of-id 検索し直す必要が無くなる。
    /// `idCounts` を呼び出し元(`SelectorNaming`)から受け取れるときは渡す ——
    /// 渡さなければ従来どおりその場で数え直す(2引数のみの外部呼び出しと出力互換)
    private static func uniqueScopeElement(for element: ElementInfo, in snapshot: SnapshotResponse,
                                           idCounts precomputed: [String: Int]? = nil) -> ElementInfo? {
        let counts = precomputed ?? idCounts(in: snapshot)
        return TapTargetGeometry.ancestors(of: element, in: snapshot.elements)
            .first { ancestor in
                guard let id = ancestor.identifier, !id.isEmpty, counts[id] == 1,
                      ancestor.frame.width > 0, ancestor.frame.height > 0 else { return false }
                return TapTargetGeometry.contains(ancestor.frame, element.frame)
            }
    }

    /// スコープに使える最も近い祖先の id。**条件は3つ**: ① id を持つ祖先が居る
    /// ② **その id が画面で一意**(重複していると `#recycler_view` のように4つある画面で
    /// 別の容器を掴む) ③ **その祖先の frame が対象を包含する**。`TapTargetGeometry.ancestors` は
    /// preorder+depth だけから祖先を再構成し frame も親ポインタも見ないので、木が間引かれると
    /// 実際の親より手前に並ぶ叔父を祖先と誤認しうる(実測: Google マップの時刻ピッカーで、
    /// 分の入力欄の祖先として無関係な `#divider`(「:」1文字)が選ばれた)。
    /// `#容器 >> …` を組む者はすべてここを通す —— スコープの規則を2箇所に持つと、
    /// `.型[n]` 版とラベル版で別の容器を指しはじめる。
    /// `idCounts:` は `SelectorNaming` が保持済みの数え上げを渡すための省略可能引数
    /// (省略時は従来どおりその場で数え直す。graded 1要素あたり最大2回この経路が呼ばれるため、
    /// 2回目以降の再計算を避けたい呼び出し元だけが渡す)
    static func uniqueScopeID(for element: ElementInfo, in snapshot: SnapshotResponse,
                              idCounts precomputed: [String: Int]? = nil) -> String? {
        uniqueScopeElement(for: element, in: snapshot, idCounts: precomputed)?.identifier
    }

    /// `#container >> .type[n]` を組み立てる。**書けないときは nil**(嘘の助言を出さない)。
    ///
    /// 条件は `uniqueScopeElement` に委ねる(id の一意性・frame の包含)。
    /// 添字はスコープ内・同じ型の中での順番で、記法は **1 オリジン**(FlowLocator.index の規約)。
    /// `idCounts:` は `uniqueScopeID` と同じ省略可能引数(意味・省略時の挙動も同じ)
    static func scopedSelector(for element: ElementInfo, in snapshot: SnapshotResponse,
                               idCounts precomputed: [String: Int]? = nil) -> String? {
        guard let scope = uniqueScopeElement(for: element, in: snapshot, idCounts: precomputed)
        else { return nil }
        return scopedSelector(scope: scope, for: element, in: snapshot)
    }

    /// scope 解決済みの呼び手用(`SelectorNaming.candidates` が walk を1回で済ませる入口)。
    /// 組み立てはここだけに置く —— 2箇所に持つと添字規則がズレて別の要素を指しはじめる
    static func scopedSelector(scope: ElementInfo, for element: ElementInfo,
                               in snapshot: SnapshotResponse) -> String? {
        guard let scopeID = scope.identifier else { return nil }
        let siblings = StepExecutor.descendants(of: scope, in: snapshot.elements)
            .filter { $0.type == element.type }
        guard let position = siblings.firstIndex(where: { $0.ref == element.ref }) else { return nil }
        return "#\(scopeID) >> .\(element.type)[\(position + 1)]"
    }

    /// 下書き・注記に書かれる形。`FTSelector` を通して往復させ、**ScenarioCodeGen が出す綴りに
    /// 揃える**(あちらも `serialize` で書き戻すので、ここを通せば注記とコードが必ず一致する)
    static func asWritten(_ selector: String) -> String {
        let parsed = FTSelector.parse(selector)
        let serialized = FTSelector.serialize(primary: parsed.primary, fallbacks: parsed.fallbacks)
        return serialized.isEmpty ? selector : serialized
    }
}
