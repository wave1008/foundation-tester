// SnapshotRendering.swift
// スナップショットを FM 向けの set-of-mark 圧縮テキストに描画する。
// 目標: 一般的な画面で 300〜800 トークンに収める(1要素1行)。

import Foundation

public enum SnapshotRenderer {

    /// `interactiveOnly: true` で**実際に消える行数**。0 なら、その画面で
    /// `interactiveOnly` を勧めても1バイトも減らない。
    ///
    /// **逃げ道として案内する前にこれを見ること**(2026-08-15 の外部評価): 出力が多いときの
    /// 対処として `interactiveOnly` を勧めていたが、**実測した Yahoo 天気トップでは
    /// 4,028B → 4,028B と1行も減らなかった** —— ページの要素がほぼ全部 `link` で、
    /// 「レイアウト専用」に当たる行が1つも無いため。**効かない逃げ道を出すのは、
    /// 逃げ道が無いことより悪い**(読み手はそれを試して1往復を捨てる)
    public static func hiddenByInteractiveOnlyCount(_ snapshot: SnapshotResponse,
                                                    flagging: [Int: String] = [:]) -> Int {
        snapshot.elements.filter {
            isHiddenByInteractiveOnly($0, in: snapshot.elements, flagging: flagging)
        }.count
    }

    /// `[3] Button "ログイン" id=login_btn (120,610 180x44)` 形式の1行を要素ごとに出力する。
    ///
    /// `flagging` に入れた ref の行末には印を付ける(既定は空 = 従来どおり)。MCP が
    /// スクロール残像を名指しするのに使う —— **先頭の注記だけでは足りない**という
    /// 外部フィードバック(2026-08-06)への対応で、ref をコピーする行そのものに出す。
    /// `unit` は座標の単位(iOS="pt" / Android="px")。**呼び手が知っているときだけ渡す** ——
    /// `SnapshotResponse` は platform を持たないので、ここで推測はしない。
    /// 出すのは、Android の論理解像度(実測 1280x2856)が iOS(402x874)と桁違いで、
    /// **同じ数字の感覚で読むと的を外す**という外部評価(2026-08-15)への答え。
    /// 数字そのものは変えない —— 1セッションに座標系を2つ持つと、木の frame と
    /// 撃つ x/y が食い違ったときにエラーにならず黙って別の場所を撃つ
    public static func render(_ snapshot: SnapshotResponse,
                              flagging: [Int: String] = [:],
                              collapsingBulk: Bool = false,
                              interactiveOnly: Bool = false,
                              unit: String? = nil) -> String {
        var lines: [String] = []
        let s = snapshot.screen
        lines.append("screen: \(Int(s.width))x\(Int(s.height))"
            + (unit.map { " \($0) (all x/y below are \($0))" } ?? ""))
        // 同じ id が2つ以上ある要素は、生成側へ「単独では曖昧」と伝えるため件数を付す
        var idCounts: [String: Int] = [:]
        // **ラベルが木の中で一意な要素は ×N を省く**(2026-08-10): id 共有件数は「この行を
        // ラベルだけで指せるか」には無関係で、検索候補のように全行が同じ id を共有する画面では
        // 一意なラベルを持つ行にまで無意味な ×10 が付いていた
        var labelCounts: [String: Int] = [:]
        for e in snapshot.elements {
            if let id = e.identifier, !id.isEmpty {
                idCounts[id, default: 0] += 1
            }
            let label = e.label.map(FlowMatchMode.normalizeInvisibleCharacters) ?? ""
            if !label.isEmpty { labelCounts[label, default: 0] += 1 }
        }
        // **数えるのは描く前**: 畳んだ群の中で隠した分まで足すと二重に数える
        let hidden = interactiveOnly ? hiddenByInteractiveOnlyCount(snapshot, flagging: flagging) : 0
        if hidden > 0 {
            let scopes = hiddenScopeClause(snapshot, flagging: flagging, idCounts: idCounts)
            lines.append("(interactiveOnly: \(hidden) layout-only or duplicate-content line(s)"
                + " hidden — refs and frames of the rest are unchanged; call again without it"
                + " for the full tree" + scopes + ")")
        }
        let bulk = collapsingBulk ? bulkGroups(snapshot, flagging: flagging) : [:]
        // **畳むのは群の一部でありうる**(D-2)ので、判定は id ではなく ref 単位で持つ。
        // 条件を外した仲間は自分の位置に個別行として残る
        var foldedRefs: Set<Int> = []
        for group in bulk.values { foldedRefs.formUnion(group.map(\.ref)) }
        var emitted: Set<String> = []
        for e in snapshot.elements {
            if let id = e.identifier, let group = bulk[id], foldedRefs.contains(e.ref) {
                guard emitted.insert(id).inserted else { continue }
                // interactiveOnly は「次の一手に使えないものを隠す」趣旨なので、bulk の
                // 索引(ラベル+ref)も同じ扱いにする。ref/frame は動かさない——headline-only
                // は表示を削るだけで、expandBulk: true / interactiveOnly なしで元の索引に戻れる
                if interactiveOnly {
                    lines.append(bulkHeadlineOnly(id: id, group: group,
                                                  totalWithSameID: idCounts[id] ?? group.count,
                                                  flagging: flagging))
                } else {
                    lines.append(contentsOf: bulkLines(id: id, group: group,
                                                       totalWithSameID: idCounts[id] ?? group.count,
                                                       flagging: flagging))
                }
                continue
            }
            if interactiveOnly, isHiddenByInteractiveOnly(e, in: snapshot.elements, flagging: flagging) {
                continue
            }
            let flag = flagging[e.ref].map { " \($0)" } ?? ""
            var idCount = e.identifier.flatMap { idCounts[$0] }.flatMap { $0 >= 2 ? $0 : nil }
            let label = e.label.map(FlowMatchMode.normalizeInvisibleCharacters) ?? ""
            if !label.isEmpty, labelCounts[label] == 1 { idCount = nil }
            lines.append(renderElement(e, idCount: idCount) + flag)
        }
        if snapshot.truncatedCount > 0 {
            lines.append("(+\(snapshot.truncatedCount) elements truncated)")
        }
        return lines.joined(separator: "\n")
    }

    /// 隠した行のうち**スコープの足場に使える容器の id**(2026-08-16 の外部評価⑧)。
    ///
    /// 評価者の申し立ては「layout-only として消された要素に重要な情報が混ざっているかもしれず、
    /// 件数だけでは判断できない」。**件数を id に置き換えるのではなく、使える id だけ足す**:
    /// - **画面で一意**(`#id` で1件に決まらないものは `>>` の足場にならない)
    /// - **子孫を持つ**(容器だけ。葉の id はスコープにならない)
    /// - **他の注記が既に名指ししていない**ものだけ、という絞りはここでは掛けない ——
    ///   注記は木だけからは決まらない条件で出たり出なかったりするので、ここが依存すると
    ///   同じ木で出力が揺れる
    ///
    /// **これは注記の追加ではなく往復の削減**: この情報を得る他の手段は
    /// 「interactiveOnly 無しでもう一度撮る」= まるごと1往復 + 全行。固定コーパス 47 枚の実測では
    /// 隠れる 882 行のうち 564 が id を持ち、**足場に使えるものが 211 件 / 33 画面**(1画面あたり
    /// 平均 6.4)。上限 6 件で打ち切るのはその実測から。
    ///
    /// **払う側も測ってある**(同コーパス): この1行は 37 画面で合計 5,572B(平均 150B)で、
    /// `interactiveOnly` が削る 38,008B の **14.7%** を食う。1画面の木は平均 3,640B なので、
    /// 足場を知るために撮り直す1往復(1ツール呼び出し + 全行)より安い、という判断。
    /// **読み手が実際にこの足場を使うか**はまだ手数で測っていない —— 測るなら
    /// `NoteCatalog.brief` と同じ形の殺しスイッチを足してから(Bench/measurements.md)
    ///
    /// 子孫の判定は**preorder の深さ**で行う(次の行が深ければ子がいる)。`ancestors` を
    /// 全要素に掛けると O(n²) になり、ここは毎回の描画で通る経路
    static func hiddenScopeClause(_ snapshot: SnapshotResponse, flagging: [Int: String],
                                  idCounts: [String: Int]) -> String {
        let elements = snapshot.elements
        var ids: [String] = []
        for (index, e) in elements.enumerated() {
            guard isHiddenByInteractiveOnly(e, in: elements, flagging: flagging),
                  let id = e.identifier, !id.isEmpty, idCounts[id] == 1,
                  index + 1 < elements.count, elements[index + 1].depth > e.depth,
                  !ids.contains(id)
            else { continue }
            ids.append(id)
        }
        guard !ids.isEmpty else { return "" }
        let shown = ids.prefix(hiddenScopeIDsShown).map { "#\($0)" }.joined(separator: " ")
        let cut = ids.count > hiddenScopeIDsShown
            ? " (+\(ids.count - hiddenScopeIDsShown) more)" : ""
        return ". Hidden containers you can scope a selector to: \(shown)\(cut)"
    }

    /// `hiddenScopeClause` が並べる上限(実測の1画面あたり平均 6.4 から)
    static let hiddenScopeIDsShown = 6

    /// `interactiveOnly` で残す要素か。**「読み手が次の一手に使えるもの」だけ**を残す:
    /// 操作できる型 / スクロール容器(`scrollFrame:` に渡せる) / 文字を持つもの(ラベル・値・
    /// プレースホルダ)/ 警告の付いた行(印は行ごとに読ませるためにあるので絶対に隠さない)。
    ///
    /// **id だけを持つ要素は残さない** —— これが落としたい当人で、実測(Google マップ Android)
    /// では `#navigation_bar_item_icon_container` `#fab_icon` `#TextStackView` のような
    /// 子と同じ矩形のレイアウト容器が1画面 88 行のうち大半を占めていた。
    /// id 付き容器を `scrollFrame:` やスコープ記法(`#container >> .clickable[n]`)で
    /// 指したいときのために、**容器名は unlabeledClickablesNote と scroll 印が別途出す**。
    ///
    /// **隠すのは描画だけ**(ホスト側が覚える木は素のまま)。ref も frame も動かないので、
    /// 隠れた行を ft_tap で撃つことは変わらずできる
    static func isSubstantive(_ e: ElementInfo, flagging: [Int: String]) -> Bool {
        if flagging[e.ref] != nil { return true }
        if e.scrollable == true { return true }
        if BridgeSnapshotThinning.operableTypes.contains(e.type) { return true }
        if textInputTypes.contains(e.type) { return true }
        let text = (e.label ?? "") + (e.value ?? "") + (e.placeholder ?? "")
        return !FlowMatchMode.normalizeInvisibleCharacters(text).isEmpty
    }

    /// 操作可能な型か(operableTypes ∪ textInputTypes)。isSubstantive と
    /// isRedundantWithOperableAncestor が同じ「操作可能」の定義を共有するための1箇所
    private static func isOperableType(_ type: String) -> Bool {
        BridgeSnapshotThinning.operableTypes.contains(type) || textInputTypes.contains(type)
    }

    /// interactiveOnly だけで効くもう1つの間引き: web ページの `link > staticText` のように、
    /// 操作可能な祖先の行にまったく同じ文字が同じ矩形でもう1行出ている行を隠す
    /// (実測: Yahoo 天気の Safari 表示で link/staticText の対がひたすら並び、interactiveOnly の
    /// 削減がほぼ効かなかった)。**警告付きの行は絶対に隠さない**(isSubstantive と同じ最優先規則)。
    /// 隠すのは描画だけ —— ref も frame も動かさないので ft_tap は変わらず撃てる
    static func isRedundantWithOperableAncestor(_ e: ElementInfo, in elements: [ElementInfo],
                                                flagging: [Int: String]) -> Bool {
        if flagging[e.ref] != nil { return false }
        if e.scrollable == true { return false }
        if isOperableType(e.type) { return false }
        let ownLabel = e.label.map(FlowMatchMode.normalizeInvisibleCharacters) ?? ""
        let ownValue = e.value.map(FlowMatchMode.normalizeInvisibleCharacters) ?? ""
        let ownText = ownLabel.isEmpty ? ownValue : ownLabel
        guard !ownText.isEmpty else { return false }
        return TapTargetGeometry.ancestors(of: e, in: elements).contains { ancestor in
            isOperableType(ancestor.type)
                && (ancestor.label.map(FlowMatchMode.normalizeInvisibleCharacters) ?? "")
                    .contains(ownText)
                && TapTargetGeometry.contains(ancestor.frame, e.frame)
        }
    }

    /// interactiveOnly の事前カウント(L35 付近)と行スキップ(render 内)が**同じ述語**を通すための束ね。
    /// 別々に判定を書くと、宣言する隠した件数と実際に消えた行数が食い違いかねない
    static func isHiddenByInteractiveOnly(_ e: ElementInfo, in elements: [ElementInfo],
                                          flagging: [Int: String]) -> Bool {
        !isSubstantive(e, flagging: flagging)
            || isRedundantWithOperableAncestor(e, in: elements, flagging: flagging)
    }

    /// 1行に畳む最小の群サイズ。**20** はブリッジ側の bulk tier(同一 id ×20 以上を
    /// 要素上限の後回しにする)と同じ値にしてある —— 片方だけ動かすと「間引きでは大量扱い
    /// なのに描画では個別」がねじれる。実アプリのコーパス18枚では地図の POI
    /// (`#VKPointFeature` ×67)だけが該当し、検索候補の `#TitleLabel` ×10 のような
    /// **中身の一覧**には1つも掛からない
    public static let bulkGroupMinimum = 20

    /// 畳んでよい群の**畳める部分**を返す。**`other` の葉だけ**に限るのが要点:
    /// - `other` = ブリッジが「型が付かなかったもの」に使う型で、シナリオの対象になるのは
    ///   地図のピンのような座標付きの飾りだけ。`staticText` や `button` の一覧は中身なので畳まない
    /// - 葉に限るのは、子を持つ要素を畳むと**子の行だけが親を失って残る**ため
    /// - **印(⚠️scroll-leftover 等)が付いた要素も畳む**(2026-08-10): タップ時に RefGuard が
    ///   改めて警告するので、snapshot 時点の個別列挙は冗長。件数は見出し側の flagSummary が言う
    ///
    /// **群まるごとの all-or-nothing にしない**(D-2。2026-08-09 に実機で確定): 条件を外した
    /// 1件の巻き添えで群全体が個別列挙になっていた。実測(Apple マップの経路一覧)では
    /// `#VKPointFeature` 158 件のうち **isLeaf が false なのは1件だけ**で、その1件は
    /// 「preorder 上の次がたまたま深い別要素(`#UserLocationButton`)」というだけの理由だった。
    /// それで 158 行が個別に出るのは、畳み込みの目的(読める量に収める)を丸ごと損なう。
    /// **条件を満たす部分だけ畳み、外れた仲間は自分の位置に個別行として残す**。
    ///
    /// 畳んでも **ref では撃てる**(ラベルと ref の索引を必ず出す)。実測で
    /// `ft_tap` の対象になり得ることを確認しているので、消してはいけない
    /// 「型が付かず・操作できず・中身も持たない葉」= 地図のピンのような飾り。
    /// bulk fold の畳み対象と、曖昧ラベル注記の除外対象(MCPServer.ambiguousLabelsNote)が
    /// **同じ判定を使う** —— 別々に書くと「畳むのに曖昧としては列挙する」の食い違いになる
    public static func isDecorativeLeaf(_ e: ElementInfo, in elements: [ElementInfo]) -> Bool {
        e.type == "other" && e.enabled && e.scrollable != true && e.checked != true
            && (e.value ?? "").isEmpty && (e.placeholder ?? "").isEmpty
            && (e.range ?? "").isEmpty
            && TapTargetGeometry.isLeaf(e, in: elements)
    }

    static func bulkGroups(_ snapshot: SnapshotResponse,
                           flagging: [Int: String]) -> [String: [ElementInfo]] {
        var byID: [String: [ElementInfo]] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            byID[id, default: []].append(e)
        }
        var folded: [String: [ElementInfo]] = [:]
        for (id, group) in byID where group.count >= bulkGroupMinimum {
            // **警告付きも畳む**(2026-08-10): タップ時に RefGuard が改めて警告するので
            // (testTapWarnsInsteadOfRefusingForAScrollLeftover)、snapshot 時点の個別列挙は
            // 冗長 —— 地図 POI 231件中40件が印付きというだけで出力の半分を個別行が占めていた。
            // 畳んだ群に何件混じっているかは見出し側(bulkHeadline の flagSummary)が言う
            let qualifying = group.filter { isDecorativeLeaf($0, in: snapshot.elements) }
            // **畳める分が下限に届かないなら畳まない**(数件を畳んでも読む量は減らず、
            // 「一部だけ畳まれた」形が読み手を混乱させるだけ)
            guard qualifying.count >= bulkGroupMinimum else { continue }
            folded[id] = qualifying
        }
        return folded
    }

    /// **ghostNote と render は同じ判定を使う**(2026-08-10): 別実装だと「畳まれた ref」の範囲が
    /// ずれ、片方は個別列挙・もう片方は畳んだままという食い違いが起きる
    public static func foldedGroups(_ snapshot: SnapshotResponse, flagging: [Int: String],
                                    collapsingBulk: Bool) -> [String: Set<Int>] {
        guard collapsingBulk else { return [:] }
        return bulkGroups(snapshot, flagging: flagging).mapValues { Set($0.map(\.ref)) }
    }

    /// 畳んだ見出しの共通部分(span・×件数・旗の内訳・「別に出ている分」の注記)。索引ありの
    /// `bulkLines` と索引なしの `bulkHeadlineOnly` の両方から使う —— 別々に持つと
    /// 同じ群で span や件数の言い方が食い違いかねない
    private static func bulkHeadline(group: [ElementInfo], totalWithSameID: Int?,
                                     flagging: [Int: String])
        -> (span: String, separately: String, flags: String) {
        let refs = group.map(\.ref).sorted()
        // **range を書けるのは連番のときだけ**。飛び飛びの群で `[2-43]` と書くと、
        // 間に挟まった別要素まで畳んだように読める(索引には全 ref が出るので情報は落ちない)
        let contiguous = refs.count >= 2 && refs.last! - refs.first! == refs.count - 1
        let span = contiguous ? "[\(refs.first!)-\(refs.last!)]" : "[\(refs.first ?? 0)…]"
        let apart = (totalWithSameID ?? group.count) - group.count
        // **「警告付き」は理由から外れる**(2026-08-10): 旗付きも畳むようになったので、
        // ここに残るのは葉でない・スクロール可能等、qualifying から漏れた分だけ
        let separately = apart > 0
            ? " \(apart) more with this id are listed separately below (not plain leaves),"
                + " so this fold is not the whole group."
            : ""
        return (span, separately, flagSummary(group, flagging: flagging))
    }

    /// 畳んだ群のうち旗が付いている件数の内訳。例: `" — 38 ⚠️scroll-leftover, 1 ⚠️offscreen among them"`
    private static func flagSummary(_ group: [ElementInfo], flagging: [Int: String]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for e in group {
            guard let flag = flagging[e.ref] else { continue }
            if counts[flag] == nil { order.append(flag) }
            counts[flag, default: 0] += 1
        }
        guard !order.isEmpty else { return "" }
        return " — " + order.map { "\(counts[$0]!) \($0)" }.joined(separator: ", ") + " among them"
    }

    /// 索引に個別行で出す先頭件数(tree 順)。**なぜ12か**: 型と命名規則が読み取れる
    /// 代表として最小限の数。235件級の実測(Apple マップの `#VKPointFeature`)では
    /// 索引の全件印字だけで出力の7割前後を占めていた
    static let bulkIndexSampleCount = 12

    /// 畳んだ群の描画。見出し1行 +「ラベル[ref]」の索引(先頭 `bulkIndexSampleCount` 件・折り返し)。
    /// **frame は落とす** —— 座標で撃ちたいなら expandBulk で全行に戻せる
    /// `totalWithSameID` = 同じ id を持つ要素の総数。畳んだ数と食い違うときは
    /// **別に出ていることを言う**(D-2 で群の一部だけを畳むようになったため。
    /// 言わないと、読み手は同じ id が2箇所に出ている理由が分からない)
    static func bulkLines(id: String, group: [ElementInfo],
                          totalWithSameID: Int? = nil, flagging: [Int: String] = [:]) -> [String] {
        let (span, separately, flags) = bulkHeadline(group: group, totalWithSameID: totalWithSameID,
                                                      flagging: flagging)
        var lines = ["\(span) other id=\(id) ×\(group.count) collapsed"
            + " (non-interactive leaves with the same id; frames omitted\(flags)).\(separately)"
            + " Tap one by its ref — pass expandBulk: true (ft_snapshot and ft_scroll_to both"
            + " take it) to list them in full:"]
        var current = "   "
        let sample = group.prefix(bulkIndexSampleCount)
        for e in sample {
            let label = e.label.map(Self.displayText) ?? ""
            let text = label.isEmpty
                ? "(no label)[\(e.ref)]"
                : "\(displayTruncate(label, labelDisplayLimit))[\(e.ref)]"
            if current.count + text.count + 1 > bulkIndexLineWidth {
                lines.append(current)
                current = "   "
            }
            current += " " + text
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(current) }
        let remaining = group.count - sample.count
        if remaining > 0 {
            lines.append("   (+\(remaining) more — expandBulk: true lists them all)")
        }
        return lines
    }

    /// interactiveOnly 用: 索引を出さず見出し1行だけ。**間引きや ref の振り直しはしない**
    /// (isSubstantive/hidden カウントは変えない。隠すのは描画のこの1行の中身だけ)
    static func bulkHeadlineOnly(id: String, group: [ElementInfo],
                                 totalWithSameID: Int? = nil, flagging: [Int: String] = [:]) -> String {
        let (span, separately, flags) = bulkHeadline(group: group, totalWithSameID: totalWithSameID,
                                                      flagging: flagging)
        // 旗の内訳は「leaves」の直後(interactiveOnly の節に挟むと em-dash 節が連なって読めない)
        return "\(span) other id=\(id) ×\(group.count) collapsed"
            + " (non-interactive leaves\(flags); index hidden by interactiveOnly — call without"
            + " interactiveOnly for the label/ref index, or with expandBulk: true for full"
            + " lines)\(separately)"
    }

    /// 索引の折り返し幅。読み手はターミナル幅ではなくトークンで読むので、
    /// 「1行が長すぎて grep しにくい」を避けるだけの値
    static let bulkIndexLineWidth = 110

    /// 行区切り文字(`\n` `\r` `\r\n` U+2028 U+2029 タブ・垂直タブ・改頁)を空白1つへ畳む。
    /// **実データの罠**(2026-08-12・Yahoo!天気 Safari 表示): 複数テキストノードを改行で
    /// 連結した a11y ラベルが実在し、素通しすると「1要素1行」の出力契約が壊れる。
    /// 通常の空白・全角空白(U+3000)は見た目が違うので畳まない(`TextNormalization.text` と同じ意図)。
    /// 連続する行区切りは1つに畳む。**`.selector` 照合は空白を種類問わず畳んで比較する**ので、
    /// 畳んだ文字列は元の(改行入りの)ラベルに一致し続ける。**実体はここ1箇所**——他は呼ぶだけ
    private static let lineBreakingScalars: Set<Unicode.Scalar> = [
        "\n", "\r", "\u{2028}", "\u{2029}", "\t", "\u{0B}", "\u{0C}",
    ]
    public static func foldLineBreaks(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var previousWasBreak = false
        for scalar in s.unicodeScalars {
            if lineBreakingScalars.contains(scalar) {
                if !previousWasBreak { out.unicodeScalars.append(" ") }
                previousWasBreak = true
            } else {
                out.unicodeScalars.append(scalar)
                previousWasBreak = false
            }
        }
        return out
    }

    /// 印字用の正規化: 行区切りを畳んでから不可視文字を正規化する。**この順で固定**——
    /// 逆にしても `.text` 側は改行を素通しするので結果は変わらないが、「形(改行)を先に
    /// 畳んでから中身(NBSP 等)を正規化する」と読める順に揃えておく
    public static func displayText(_ s: String) -> String {
        FlowMatchMode.normalizeInvisibleCharacters(foldLineBreaks(s))
    }

    static func renderElement(_ e: ElementInfo, idCount: Int? = nil) -> String {
        var parts: [String] = ["[\(e.ref)]", e.type]
        // 不可視文字・改行は truncate の前に正規化する(ゼロ幅は除去・NBSP 等は通常空白へ・
        // 改行類は空白へ畳む)。**照合側と同じ1関数を通す**ので、ここから写した文字列は
        // FlowMatchMode.matches(.selector 正規化)と必ず一致する
        let label = e.label.map(Self.displayText)
        if let label, !label.isEmpty {
            parts.append("\"\(displayTruncate(label, labelDisplayLimit))\"")
        }
        if let id = e.identifier, !id.isEmpty {
            let suffix = idCount.map { " ×\($0)" } ?? ""
            parts.append("id=\(id)\(suffix)")
        }
        let value = e.value.map(Self.displayText)
        if let value, !value.isEmpty {
            parts.append("value=\"\(displayTruncate(value, valueDisplayLimit))\"")
        }
        let placeholder = e.placeholder.map(Self.displayText)
        if let placeholder, !placeholder.isEmpty, placeholder != label {
            parts.append("ph=\"\(truncate(placeholder, valueDisplayLimit))\"")
        }
        // 取り得る範囲(スライダー・プログレス)。**値だけでは意味が決まらない** ——
        // `value="3"` が 0..10 の3なのか 0..100 の3なのかで読み方が変わる
        if let range = e.range, !range.isEmpty {
            parts.append("range=\(range)")
        }
        // 空の入力欄はモデルに明示する(「入力済みと思い込んで送信」対策)。
        // label があるのに empty と出す自己矛盾を避けるため、label も無いときだけ出す
        if Self.textInputTypes.contains(e.type), e.value == nil, label == nil || label!.isEmpty {
            parts.append("empty")
        }
        if !e.enabled {
            parts.append("disabled")
        }
        // 選択・チェック状態(iOS の isSelected / Android の isChecked||isSelected)。
        // **true のときだけ**出す = 「印が無い」は「オフ」と「状態を持たない」の両方を含む
        // (checkIsOFF が状態を持たない要素でも通る既定と同じ意味論。StepExecutor+Assert 参照)。
        // これが無いと、タブの選択状態は checkIsON では表明できるのに ft_snapshot からは見えない
        if e.checked == true {
            parts.append("checked")
        }
        // `scrollFrame:` に指定できる容器の印。**true のときだけ**出す(申告できないエンジンが
        // あるので「印が無い = スクロールしない」ではない。ElementInfo.scrollable 参照)
        if e.scrollable == true {
            parts.append("scroll")
        }
        let f = e.frame
        parts.append("(\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height)))")
        return parts.joined(separator: " ")
    }

    public static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    /// URL らしい文字列か(`scheme://…` またはスキーム省略形 `host.tld/…`)。true のときだけ
    /// 中略切り詰めへ回す —— URL は末尾ほど固有なので、先頭だけを残す通常の切り詰めだと
    /// 「どのページに居るか」が分からなくなる(実測: `tenki.jp/lite/forecast/3/16/44…` に
    /// リダイレクトされたことに2往復気付けなかった)。正規表現は使わず素の文字列操作で書く
    static func isURLLike(_ s: String) -> Bool {
        if s.contains("://") { return true }
        func isHostChar(_ c: Character) -> Bool {
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-")
        }
        guard let first = s.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        var idx = s.startIndex
        while idx < s.endIndex, isHostChar(s[idx]) {
            idx = s.index(after: idx)
        }
        let host = s[s.startIndex..<idx]
        guard let lastDot = host.lastIndex(of: "."), lastDot > host.startIndex else { return false }
        let tld = host[host.index(after: lastDot)...]
        guard tld.count >= 2, tld.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        guard idx < s.endIndex else { return true }
        return s[idx] == "/" || s[idx] == "?"
    }

    /// 中略切り詰め: 先頭+"…"+末尾で合計を上限ちょうどにする。先頭を末尾より1文字だけ多く配分
    /// (上限30なら先頭15・末尾14)。配分できないほど上限が小さいときは通常の先頭切りに委ねる
    static func truncateMiddle(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let budget = max - 1
        guard budget >= 2 else { return truncate(s, max) }
        let headLen = (budget + 1) / 2
        let tailLen = budget - headLen
        return String(s.prefix(headLen)) + "…" + String(s.suffix(tailLen))
    }

    /// label/value の描画から呼ぶ切り詰めの入口。URL らしい文字列だけ中略、それ以外は
    /// 従来どおり先頭切り(placeholder は対象外 — URL であることはまず無く判定コストだけ増える)
    static func displayTruncate(_ s: String, _ max: Int) -> String {
        isURLLike(s) ? truncateMiddle(s, max) : truncate(s, max)
    }

    /// 描画で切り詰める上限。**セレクタに使えるかを決める値**なので注記側と共有する
    /// (片方だけ変えると「切り詰めた」と言いながら実は完全な文字列、が起きる)
    public static let labelDisplayLimit = 40
    public static let valueDisplayLimit = 30

    /// 切り詰め注記の例(`"*text*"`)を組む。**渡された先頭12文字をそのまま使わず、
    /// 区切り文字(", " / "、")があればその手前で止める** —— 素直に先頭12文字を出すと
    /// `*新宿, JR JA*` のように「, 」を含み、複数要素の列挙に読める。実際に読み違えて
    /// endsWith セレクタを渡し7スクロール空振りした事故がある(2026-08-10)。
    /// **切った結果が空になるとき(区切りが先頭にある等)だけ元の文字列をそのまま使う**
    /// (何も出さないよりは元の12文字の方がまだ手掛かりになる)。
    /// **渡された断片に "…" が混じっていても例には含めない**(呼び出し元が中略済みの
    /// 表示文字列を誤って渡しても、絶対に一致しない例を出さないための保険)
    static func quotedPartialMatchExample(_ rawFragment: String) -> String {
        "\"*\(partialMatchFragment(rawFragment))*\""
    }

    /// 上の切り出し規則そのもの。**`SelectorNaming` の長ラベル候補と共有する**(2026-08-15)——
    /// 別々に書くと、注記が勧める断片と、勧められるセレクタの断片が食い違う
    public static func partialMatchFragment(_ rawFragment: String) -> String {
        let fragment = rawFragment.range(of: "…")
            .map { String(rawFragment[..<$0.lowerBound]) } ?? rawFragment
        let cutIndex = [", ", "、"]
            .compactMap { fragment.range(of: $0)?.lowerBound }
            .filter { $0 > fragment.startIndex }
            .min()
        return cutIndex.map { String(fragment[..<$0]) } ?? fragment
    }

    /// 切り詰めたラベルがあるときだけ出す注記。**印字された文字列は完全一致では当たらない** ——
    /// 読み手は木に出ている文字列をそのままセレクタへ写すので、これが無いと
    /// 「木に居るのに waitFor が当たらない」= 照合のバグに見える(2026-08-07 に実アプリで実測。
    /// Google マップの1画面に40字超が3件あり、そのまま渡した waitFor が外れた)。
    /// **URL らしいラベルは中略表示**(先頭も末尾も生きている)なので、その旨と末尾側の
    /// 例も出す —— 先頭一致しか案内しないと、URL では最も固有な末尾側を見落とす
    public static func truncatedLabelNote(_ snapshot: SnapshotResponse) -> String? {
        let longest = snapshot.elements
            .compactMap { $0.label.map(Self.displayText) }
            .filter { $0.count > labelDisplayLimit }
            .max(by: { $0.count < $1.count })
        guard let longest else { return nil }
        if isURLLike(longest) {
            let example = quotedPartialMatchExample(String(longest.suffix(min(12, labelDisplayLimit))))
            return "note: URL/path-like labels longer than \(labelDisplayLimit) characters are"
                + " shown abridged as \"start…end\" — that \"…\" is display only, so copying the"
                + " printed text into a selector will never match. Use a partial match from"
                + " either end instead (e.g. \(example) — the *text* form matches anywhere in"
                + " the label).\n"
        }
        let example = quotedPartialMatchExample(String(longest.prefix(min(12, labelDisplayLimit))))
        return "note: labels longer than \(labelDisplayLimit) characters are shown cut off with"
            + " \"…\" — that \"…\" is display only, so copying the printed text into a selector"
            + " will never match. Use a partial match built from the start of the label instead"
            + " (e.g. \(example) — the *text* form matches anywhere in the label).\n"
    }

    /// 末尾 "…" = 通常の先頭切り。貼られた文字列がどれかのラベルの先頭一致なら、
    /// それは表示専用の切り詰めそのものと確定できる
    private static func prefixTruncationHint(_ bare: String, in snapshot: SnapshotResponse) -> String? {
        let prefix = String(bare.dropLast())
        guard !prefix.isEmpty else { return nil }
        let full = snapshot.elements
            .compactMap { $0.label.map(Self.displayText) }
            .first { $0.hasPrefix(prefix) && $0.count > prefix.count }
        guard full != nil else { return nil }
        let example = quotedPartialMatchExample(String(prefix.prefix(min(12, prefix.count))))
        return " The text you passed ends with \"…\", which is how a label longer than"
            + " \(labelDisplayLimit) characters is *displayed* — it is not part of the label,"
            + " so an exact match cannot succeed. Use a prefix instead (e.g. \(example))."
    }

    /// 中間の "…" = URL/パスの中略表示そのものを貼られたか。label/value の両方を対象にする
    /// (実測でいちばん貼られやすいのはアドレスバーの value)。displayTruncate した結果と
    /// 実際に一致するときだけ確定として扱う(似た文字列を誤検知しない)
    private static func middleTruncationHint(_ bare: String, in snapshot: SnapshotResponse) -> String? {
        guard let ellipsis = bare.range(of: "…"), ellipsis.lowerBound > bare.startIndex,
              ellipsis.upperBound < bare.endIndex else { return nil }
        let head = String(bare[..<ellipsis.lowerBound])
        let matches = snapshot.elements.contains { e in
            let label = e.label.map(Self.displayText)
            let value = e.value.map(Self.displayText)
            return (label.map { isURLLike($0) && displayTruncate($0, labelDisplayLimit) == bare } ?? false)
                || (value.map { isURLLike($0) && displayTruncate($0, valueDisplayLimit) == bare } ?? false)
        }
        guard matches else { return nil }
        let example = quotedPartialMatchExample(head)
        return " The text you passed contains \"…\" in the middle, which is how a URL/path-like"
            + " value longer than the display limit is *abridged* — it is not part of the value,"
            + " so an exact match cannot succeed. Use a partial match from either end instead"
            + " (e.g. \(example))."
    }

    /// 渡されたセレクタが**この画面のどれかのラベル/値の切り詰め表示**そのものか。
    /// `waitFor`/`scrollTo` が外れた理由がこれなら、綴りでも待ち時間でもないと名指しできる。
    /// 末尾 "…"(通常切り詰め)と中間 "…"(URL の中略)の両方を検出する
    public static func truncatedSelectorHint(_ selectorText: String,
                                             in snapshot: SnapshotResponse) -> String? {
        let bare = selectorText.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        if bare.hasSuffix("…") {
            return prefixTruncationHint(bare, in: snapshot)
        }
        return middleTruncationHint(bare, in: snapshot)
    }

    public static let textInputTypes: Set<String> = [
        "textField", "secureTextField", "textView", "searchField",
    ]
}
