// セレクタ式のパース。文字列 1 本を `||` で分割し、各節を FlowLocator に写像する。
//   #login_btn                     → id(**完全一致**)
//   #login_* / #*_btn / #*login*   → id 部分一致(`#` 短縮形だけ `*` を展開する。
//                                     `id=` 完全形はワイルドカード展開しない。text= と同じ非対称)
//   ログイン                        → text(**完全一致**。部分一致は下の `*` 記法で明示する)
//   *ログイン* / ログイン* / *ログイン → 部分一致(contains / startsWith / endsWith)
//   textMatches=^ログイン.*$         → 正規表現(部分一致。全体一致は ^...$)
//   .button / .button[2]           → 型(+順番。**型名は先頭小文字**)
//   .switch#PHOTOS_UPLOAD          → 型 + id(`.switch&&#PHOTOS_UPLOAD` の短縮形)
//   #WebView 入力                   → id は **identifier で引けなければ placeholder** を引く
//                                     (入力欄は経路で id/placeholder が入れ替わる。docs/commands.md)
//   .switch&&Resource Upload       → 型 + text(`&&` は条件の連結。`.型=…` という書き方は無い)
//   .button&&value=太郎&&enabled=true → `&&` で条件を AND 合成(フィルタは全部これで書ける)
//   (保存|OK) / text=(保存|OK)        → フィルタ内 OR。`保存||OK` と等価(パース時に節へ展開する)。
//                                     相対の引数では括弧を自分で書く(`:right((保存|OK))`)
//   .button&&text!=キャンセル          → 否定フィルタ(完全形のみ。否定だけの節は書けない)
//   #list >> .clickable[2]         → スコープ(祖先 >> 子孫。[n] はスコープ内で数える)
//   通知:rightSwitch               → 相対(**基準が先・対象が後**)。`:right(.switch)` と同じ
//   通知:right(2)                  → 基準の右にある2番目に近いウィジェット
//   通知:right:belowButton         → 相対ステップの連鎖
//   <変更&&.button>:right(数量)     → 基準の `<...>` 囲み(任意。基準の範囲を明示したいとき)
// [n] / pos=n は 1 オリジン(内部の FlowLocator.index は 0 オリジン)。
// `||` は**候補集合の和**(Shirates 準拠。`#id||ラベル` は「id にマッチする要素とラベルにマッチする
// 要素を合わせた集合」)。要素を1つ選ぶコマンドは和集合の先頭 = **節の順→節内のツリー順**で採るので、
// ヒール連鎖(`#id||ラベル`)の優先順位は保たれる。countIs は和集合の総数を数える
// (同じ要素が複数の節にマッチしても1度だけ)。詳しくは StepExecutor.unionCandidates。
// 優先順位は `&&` > `>>` > `||`。分割はいずれも括弧の外だけ(`:right(...)` の中は割らない)。
// パースは失敗しない(解釈できない節は text として扱う)。**構文の誤り(未知のマーカー・綴り誤り・
// 先頭大文字の型名・不正な序数・既知名と紛らわしいフィルタ名の綴り誤り)は validationError が
// 別経路で落とす**(パースだけだと `.button:rigth(x)` が黙ってラベル扱いになり、notExist 等が
// 空振りで緑になるため。run 開始時と dry-run が呼ぶ)。
// ラベルに `>>` `&&` `:right` `*` 等を含めたいときは先頭 `=` でエスケープ。

// FTCore に居る理由: 写像先の FlowLocator は FTCore の型で、DSL ランタイム(FTRuntime)には
// 依存しない(FTRuntime.perform への言及はコメントのみ)。

import Foundation

public struct FTSelector {
    /// 元のセレクタ式(ログ・レポート・修正提案用)
    public let text: String
    public let primary: FlowLocator
    public let fallbacks: [FlowLocator]
    /// 型付きセレクタ(Sel)が組み立てたもの。**実行時の構文検証を通さない**印
    /// (綴り誤りはコンパイラが捕まえているので防波堤が要らない。加えて、ラベルに `>>` 等の
    /// 予約文字が入ると serialize→再パースで別物になり得るのを避ける。FTRuntime.perform 参照)
    public let structured: Bool
    /// 型付きセレクタの組み立て時に見つかった誤り(`Sel.invalidReason`)。
    /// structured は構文検証を通さないので、**代わりにこれが唯一の防波堤**になる
    public let structuredError: String?

    // public: Sel.ftSelector(FTDSL)がここから直に組み立てる(型付きセレクタは validationError を
    // 通らないので、この経路以外に structured=true を作る場所が無い)
    public init(text: String, primary: FlowLocator, fallbacks: [FlowLocator], structured: Bool = false,
                structuredError: String? = nil) {
        self.text = text
        self.primary = primary
        self.fallbacks = fallbacks
        self.structured = structured
        self.structuredError = structuredError
    }

    /// 実行前に落とすべき理由。型付きは組み立て時の誤り、文字列は構文検証(唯一の合流点)。
    /// public: FTRuntime.perform(FTDSL)が実行前ゲートとして読む
    public var preflightError: String? {
        structured ? structuredError : FTSelector.validationError(text)
    }

    public static func parse(_ text: String) -> FTSelector {
        let clauses = splitTopLevel(text, separator: "||")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 1節が `(a|b)` を含むと複数のロケータへ展開される(`||` と同じ和集合になる)
        let locators = clauses.flatMap(parseClauses)
        guard let first = locators.first else {
            return FTSelector(text: text, primary: FlowLocator(label: text), fallbacks: [])
        }
        return FTSelector(text: text, primary: first, fallbacks: Array(locators.dropFirst()))
    }

    /// 生ラベル(# や . で始まるテキスト)をそのまま text として使う場合
    public static func label(_ text: String) -> FTSelector {
        FTSelector(text: text, primary: FlowLocator(label: text), fallbacks: [])
    }

    // MARK: - 語彙(パース・検証・シリアライズが共有する唯一の表)

    static let directions: [(name: String, direction: FlowDirection)] = [
        ("right", .right), ("left", .left), ("above", .above), ("below", .below),
    ]

    /// 相対セレクタの型別ショートハンド(`:rightSwitch` = `:right(.switch)`)。
    /// 接尾辞なしの `:right` は `.widget`(役割が確定した要素だけ)が既定
    static let relativeTypes: [(suffix: String, type: String)] = [
        ("Button", "button"), ("Input", "input"), ("Label", "staticText"),
        ("Image", "image"), ("Switch", "switch"), ("Widget", "widget"),
    ]

    enum TextAttribute { case text, value, placeholder }

    /// 文字列属性フィルタ名 → (属性, 一致方法)。名前は FlowMatchMode.filterName が唯一の生成元
    /// (`text` / `textStartsWith` / `textContains` / `textEndsWith` / `textMatches` × text/value/placeholder)
    static let textFilters: [String: (attribute: TextAttribute, mode: FlowMatchMode)] = {
        var table: [String: (attribute: TextAttribute, mode: FlowMatchMode)] = [:]
        let attributes: [(TextAttribute, String)] =
            [(.text, "text"), (.value, "value"), (.placeholder, "placeholder")]
        for (attribute, name) in attributes {
            for mode in [FlowMatchMode.exact, .startsWith, .contains, .endsWith, .matches] {
                table[mode.filterName(name)] = (attribute, mode)
            }
        }
        return table
    }()

    /// id フィルタ名 → 一致方法。名前は FlowMatchMode.filterName が唯一の生成元
    /// (`id` / `idStartsWith` / `idContains` / `idEndsWith` / `idMatches`。Shirates 準拠)
    static let idFilters: [String: FlowMatchMode] = {
        var table: [String: FlowMatchMode] = [:]
        for mode in [FlowMatchMode.exact, .startsWith, .contains, .endsWith, .matches] {
            table[mode.filterName("id")] = mode
        }
        return table
    }()

    /// id・文字列属性以外のフィルタ名(短縮形を持つものも完全形で書ける)
    static let otherFilters: Set<String> = ["type", "pos", "checked", "enabled"]

    // MARK: - パース

    /// 1節を 1 つ以上のロケータへ。**複数になるのは `(a|b)` を含むときだけ**で、
    /// 展開結果は `||` の節と同じ扱い(候補集合の和)になる
    static func parseClauses(_ clause: String) -> [FlowLocator] {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        // `=` エスケープは最優先(生ラベルに `>>` や `:right` を含められる唯一の手段)
        if trimmed.hasPrefix("=") { return [FlowLocator(label: String(trimmed.dropFirst()))] }
        let segments = splitTopLevel(trimmed, separator: ">>")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard segments.count > 1, let last = segments.last else { return parseSegments(trimmed) }
        // スコープの各段も `(a|b)` で展開され得るので、全段 × 対象の直積を作る
        let scopeVariants = segments.dropLast().map(parseSegments)
        let targets = parseSegments(last)
        var result: [FlowLocator] = []
        for scope in cartesian(scopeVariants) {
            for target in targets {
                var copy = target
                copy.scope = scope
                result.append(copy)
                if result.count >= maxExpansion { return result }
            }
        }
        return result
    }

    /// 単一のロケータが要る場所(検証・比較)向け。展開結果の先頭を返す
    static func parseClause(_ clause: String) -> FlowLocator {
        parseClauses(clause).first ?? FlowLocator(label: clause)
    }

    /// `>>` で割った 1 区間。相対ステップ(`:rightSwitch` 等)を末尾から剥がし、
    /// 残りを `&&` 区切りのフィルタ列としてパースする(`(a|b)` があれば複数返る)
    static func parseSegments(_ segment: String) -> [FlowLocator] {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("=") { return [FlowLocator(label: String(trimmed.dropFirst()))] }
        let split = splitRelativeChain(trimmed)
        return parseFilterVariants(split.base).map { locator in
            var copy = locator
            if !split.steps.isEmpty { copy.relative = split.steps }
            return copy
        }
    }

    /// 相対ステップ列を切り出す。1つでも解釈できない形があれば**全体を素の文字列として返す**
    /// (パースは失敗しない契約。誤りは validationError が捕まえる)。
    /// arguments は括弧の中の生テキスト(検証が元の綴りを見るために要る。無い step は nil)。
    /// 基準は `<...>` で囲める(Shirates の正典形 `<text1>:rightButton`。パース結果は囲まない形と同一)。
    /// スコープは括弧の外に書く(`#row >> <数量>:rightButton`。`>>` は括弧より先に割られるため)
    static func splitRelativeChain(_ segment: String)
        -> (base: String, steps: [FlowRelativeStep], arguments: [String?]) {
        var start: String.Index
        var base: String
        if segment.hasPrefix("<") {
            // `<` 始まりは括弧形式として読めたときだけ相対セレクタ(それ以外は生ラベル扱い →
            // segmentError が「< 始まりなのに読めない」として落とす。黙って解釈しない)
            guard let close = matchingAngle(segment, open: segment.startIndex) else {
                return (segment, [], [])
            }
            base = String(segment[segment.index(after: segment.startIndex)..<close])
                .trimmingCharacters(in: .whitespaces)
            start = segment.index(after: close)
            guard !base.isEmpty, start < segment.endIndex, segment[start] == ":" else {
                return (segment, [], [])
            }
        } else {
            guard let found = firstRelativeMarker(in: segment) else { return (segment, [], []) }
            start = found
            base = String(segment[segment.startIndex..<start])
                .trimmingCharacters(in: .whitespaces)
            // 基準が空の `:rightSwitch` は式として無意味 → 解釈せず生ラベル扱い
            guard !base.isEmpty else { return (segment, [], []) }
        }
        var steps: [FlowRelativeStep] = []
        var arguments: [String?] = []
        var index = start
        while index < segment.endIndex {
            guard segment[index] == ":", let parsed = parseRelativeStep(segment, from: index) else {
                return (segment, [], [])
            }
            steps.append(parsed.step)
            arguments.append(parsed.argument)
            index = parsed.next
        }
        guard !steps.isEmpty else { return (segment, [], []) }
        return (base, steps, arguments)
    }

    /// `<` に対応する `>`(入れ子は深さで数える)。無ければ nil
    static func matchingAngle(_ text: String, open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "<" { depth += 1 }
            if text[index] == ">" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 最も左の相対マーカー(`:` + 既知のコマンド名)。括弧の中は見ない
    static func firstRelativeMarker(in segment: String) -> String.Index? {
        var index = segment.startIndex
        var depth = 0
        while index < segment.endIndex {
            let char = segment[index]
            if char == "(" { depth += 1 }
            if char == ")" { depth = max(0, depth - 1) }
            if depth == 0, char == ":", relativeCommand(segment, after: index) != nil { return index }
            index = segment.index(after: index)
        }
        return nil
    }

    /// `:` の直後に続く英字列が既知のコマンドなら (方向, 型, 英字列の終端) を返す
    static func relativeCommand(_ segment: String, after colon: String.Index)
        -> (direction: FlowDirection, type: String?, end: String.Index)? {
        var cursor = segment.index(after: colon)
        while cursor < segment.endIndex, segment[cursor].isLetter {
            cursor = segment.index(after: cursor)
        }
        let name = String(segment[segment.index(after: colon)..<cursor])
        guard !name.isEmpty else { return nil }
        for (prefix, direction) in directions where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            if suffix.isEmpty { return (direction, nil, cursor) }
            if let match = relativeTypes.first(where: { $0.suffix == suffix }) {
                return (direction, match.type, cursor)
            }
            return nil
        }
        return nil
    }

    /// `:rightSwitch` / `:right(2)` / `:right(.switch||#a)` を 1 つ読む
    static func parseRelativeStep(_ segment: String, from colon: String.Index)
        -> (step: FlowRelativeStep, argument: String?, next: String.Index)? {
        guard let command = relativeCommand(segment, after: colon) else { return nil }
        var filter = command.type.map { [FlowLocator(type: $0)] }
        var ordinal: Int?
        var argument: String?
        var next = command.end
        if next < segment.endIndex, segment[next] == "(" {
            guard let close = matchingParen(segment, open: next) else { return nil }
            let arg = String(segment[segment.index(after: next)..<close])
                .trimmingCharacters(in: .whitespaces)
            guard !arg.isEmpty else { return nil }
            argument = arg
            if let number = Int(arg) {
                guard number >= 1 else { return nil }
                ordinal = number
            } else {
                // 引数は節1本と同じ文法(`>>` スコープも書ける)。parseSegment だと
                // `#x >> .button` が丸ごと id になって黙って解決不能になる
                let parsed = splitTopLevel(arg, separator: "||")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .flatMap(parseClauses)
                guard !parsed.isEmpty else { return nil }
                // 型別ショートハンドと引数を併記した `:rightSwitch(保存)` は型で絞ったうえで引数を AND
                filter = command.type == nil
                    ? parsed
                    : parsed.map { merged($0, type: command.type) }
                // `:right(.button&&[2])` は「右の 2 番目の button」= `:rightButton(2)` と同義に正規化する
                // (往復のため構造を1つに寄せる。resolveRelative も filter.index を同じ意味で読む)
                let indexes = parsed.map(\.index)
                if let first = indexes.first, first != nil, indexes.allSatisfy({ $0 == first }) {
                    ordinal = (first ?? 0) + 1
                    filter = filter.map { $0.map { locator in
                        var copy = locator
                        copy.index = nil
                        return copy
                    } }
                }
            }
            next = segment.index(after: close)
        }
        return (FlowRelativeStep(direction: command.direction, filter: filter, ordinal: ordinal),
                argument, next)
    }

    static func merged(_ locator: FlowLocator, type: String?) -> FlowLocator {
        var copy = locator
        if copy.type == nil { copy.type = type }
        return copy
    }

    /// 1つの節から作られるロケータ数の上限(`(a|b)&&(c|d)` の直積が爆発しないように)。
    /// 超える式は validationError が実行前に落とす
    static let maxExpansion = 32

    /// `&&` 区切りのフィルタ列を 1 つの FlowLocator へ畳む(全て AND)。
    /// `(a|b)` は展開しない = **検証と比較のための単一形**(実行に使うのは parseFilterVariants)
    static func parseFilters(_ text: String) -> FlowLocator {
        var locator = FlowLocator()
        for token in splitTopLevel(text, separator: "&&")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty }) {
            merge(parseFilter(token), into: &locator)
        }
        return locator
    }

    /// `&&` 列を、フィルタ内 OR(`(a|b)`)を展開したロケータ列にする。
    /// 展開は**トークン単位の文字列置換**で行い、各組み合わせを通常どおり AND で畳む
    /// (`(保存|OK)&&.button` = `保存&&.button || OK&&.button`。Shirates のドキュメントが
    /// 「等価」と書いている形そのもの)。`||` が和集合になったのでこの等価が成立する
    static func parseFilterVariants(_ text: String) -> [FlowLocator] {
        let tokens = splitTopLevel(text, separator: "&&")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [FlowLocator()] }
        return cartesian(tokens.map(expandGroups)).map { combination in
            var locator = FlowLocator()
            for token in combination { merge(parseFilter(token), into: &locator) }
            return locator
        }
    }

    /// トークン内の `(a|b)` を展開する。グループでない括弧(`保存(推奨)` のような
    /// ラベルの一部)は `|` を含まないので触らない。`=` エスケープ済みトークンも触らない
    static func expandGroups(_ token: String) -> [String] {
        guard !token.hasPrefix("="), let group = firstGroup(in: token) else { return [token] }
        let prefix = String(token[token.startIndex..<group.open])
        let suffix = String(token[token.index(after: group.close)...])
        let inner = String(token[token.index(after: group.open)..<group.close])
        var result: [String] = []
        for alternative in splitTopLevel(inner, separator: "|") {
            // 残りのグループも展開する(`(a|b)(c|d)` のような多段も直積になる)
            result.append(contentsOf: expandGroups(prefix + alternative + suffix))
            if result.count >= maxExpansion { break }
        }
        return result
    }

    /// トークン内で最初に現れる「`|` を含む括弧」= OR グループ
    static func firstGroup(in token: String) -> (open: String.Index, close: String.Index)? {
        var index = token.startIndex
        while index < token.endIndex {
            guard token[index] == "(", let close = matchingParen(token, open: index) else {
                index = token.index(after: index)
                continue
            }
            let inner = token[token.index(after: index)..<close]
            if splitTopLevel(String(inner), separator: "|").count > 1 {
                return (index, close)
            }
            index = token.index(after: close)
        }
        return nil
    }

    /// 各要素の候補列から直積を作る(先頭の要素が最も外側 = 左のグループから順に変わる)
    static func cartesian<T>(_ groups: [[T]]) -> [[T]] {
        var result: [[T]] = [[]]
        for group in groups {
            var next: [[T]] = []
            for prefix in result {
                for item in group {
                    next.append(prefix + [item])
                    if next.count >= maxExpansion { break }
                }
                if next.count >= maxExpansion { break }
            }
            result = next.isEmpty ? result : next
        }
        return result
    }

    static func merge(_ source: FlowLocator, into target: inout FlowLocator) {
        if let not = source.not, !not.isEmpty { target.not = (target.not ?? []) + not }
        if let id = source.id {
            target.id = id
            target.idMatch = source.idMatch
        }
        if let label = source.label {
            target.label = label
            target.labelMatch = source.labelMatch
        }
        if let value = source.value {
            target.value = value
            target.valueMatch = source.valueMatch
        }
        if let placeholder = source.placeholder {
            target.placeholder = placeholder
            target.placeholderMatch = source.placeholderMatch
        }
        if let type = source.type { target.type = type }
        if let checked = source.checked { target.checked = checked }
        if let enabled = source.enabled { target.enabled = enabled }
        if let index = source.index { target.index = index }
    }

    static func parseFilter(_ token: String) -> FlowLocator {
        // `!` の短縮形(Shirates 準拠): `!保存` = text!=保存 / `!#id` / `!.button`。
        // 中身は完全形と同じ経路で解釈し、結果を not に入れる(序数 `![2]` は
        // tokenError が実行前に拒否する = 候補集合を絞れないため)
        if token.hasPrefix("!"), token.count > 1 {
            let inner = String(token.dropFirst())
            // `!=` を含む完全形(`text!=x`)はここではなく parseNegatedFilter が扱う
            if !inner.hasPrefix("=") {
                let positive = parseFilter(inner)
                if !positive.hasNoFilter { return FlowLocator(not: [positive]) }
            }
        }
        if token.hasPrefix("=") {
            // 生ラベルのエスケープ(# や . で始まるラベルを text として扱う)
            return FlowLocator(label: String(token.dropFirst()))
        }
        if token.hasPrefix("#") { return idLocator(String(token.dropFirst())) }
        if token.hasPrefix("."), token.count > 1 { return parseTypeFilter(String(token.dropFirst())) }
        if token.hasPrefix("["), token.hasSuffix("]"),
           let ordinal = Int(token.dropFirst().dropLast()), ordinal >= 1 {
            return FlowLocator(index: ordinal - 1)
        }
        if let negated = parseNegatedFilter(token) { return negated }
        if let named = parseNamedFilter(token) { return named }
        return textLocator(token)
    }

    /// `名前!=値`(否定フィルタ)の完全形。短縮形 `!値` は parseFilter が先に受ける。
    /// 中身は肯定と同じロケータで、それを `not` に1件入れた形にする
    static func parseNegatedFilter(_ token: String) -> FlowLocator? {
        guard let eqIndex = token.firstIndex(of: "="), eqIndex > token.startIndex else { return nil }
        let bangIndex = token.index(before: eqIndex)
        guard token[bangIndex] == "!" else { return nil }
        let name = String(token[token.startIndex..<bangIndex])
        let value = String(token[token.index(after: eqIndex)...])
        // pos は「n 番目でない」に意味が無いので否定できない(検証がエラーにする)
        guard name != "pos", let inner = namedFilterLocator(name: name, value: value) else {
            return nil
        }
        return FlowLocator(not: [inner])
    }

    /// `.型` / `.型#id` / `.型[n]`(いずれも `&&` 合成の短縮形)。
    /// **型名に `=` は使えない**(`=` は text= 等のフィルタ名と先頭エスケープに使う)。
    /// `.型=ラベル` と書くと `=` 以降が型名の一部として黙って読まれる(never-match)ので、
    /// **tokenError(typeEqualsError)が実行前に必ず落とす**(notExist が緑になる穴)
    static func parseTypeFilter(_ body: String) -> FlowLocator {
        if let hashIndex = body.firstIndex(of: "#") {
            let type = String(body[body.startIndex..<hashIndex])
            // `#` 以降は単独の `#` 短縮形と同じ `*` 展開(挙動を割ると `.button#foo*` が
            // 黙って literal 完全一致 = never-match になる)
            var locator = idLocator(String(body[body.index(after: hashIndex)...]))
            locator.type = type.isEmpty ? nil : type
            return locator
        }
        if body.hasSuffix("]"), let bracketIndex = body.firstIndex(of: "[") {
            let type = String(body[body.startIndex..<bracketIndex])
            let indexText = String(body[body.index(after: bracketIndex)..<body.index(before: body.endIndex)])
            if let ordinal = Int(indexText) {
                // 表記 1 オリジン → 内部 0 オリジン
                return FlowLocator(type: type, index: max(0, ordinal - 1))
            }
        }
        return FlowLocator(type: body)
    }

    /// `名前=値`。**名前が既知のフィルタ名のときだけ**成立する(未知なら nil = 生ラベル扱い。
    /// 綴り誤りは validationError が落とす)
    static func parseNamedFilter(_ token: String) -> FlowLocator? {
        guard let eqIndex = token.firstIndex(of: "=") else { return nil }
        let name = String(token[token.startIndex..<eqIndex])
        let value = String(token[token.index(after: eqIndex)...])
        return namedFilterLocator(name: name, value: value)
    }

    /// `名前=値` を 1 属性だけ設定したロケータへ。肯定(parseNamedFilter)と
    /// 否定(parseNegatedFilter の中身)が共有する唯一の変換
    static func namedFilterLocator(name: String, value: String) -> FlowLocator? {
        guard isFilterName(name) else { return nil }
        if let text = textFilters[name] {
            // exact は mode を持たせない(既定と同じ構造に正規化して往復・比較を1つに保つ)
            let mode = text.mode == .exact ? nil : text.mode
            switch text.attribute {
            case .text: return FlowLocator(label: value, labelMatch: mode)
            case .value: return FlowLocator(value: value, valueMatch: mode)
            case .placeholder: return FlowLocator(placeholder: value, placeholderMatch: mode)
            }
        }
        if let idMode = idFilters[name] {
            // id= 完全形は `#` 短縮形と違いワイルドカード展開しない(text= と同じ非対称)
            return FlowLocator(id: value, idMatch: idMode == .exact ? nil : idMode)
        }
        switch name {
        case "type": return FlowLocator(type: value)
        case "pos": return Int(value).map { FlowLocator(index: max(0, $0 - 1)) }
        case "checked": return boolValue(value).map { FlowLocator(checked: $0) }
        case "enabled": return boolValue(value).map { FlowLocator(enabled: $0) }
        default: return nil
        }
    }

    static func boolValue(_ text: String) -> Bool? {
        text == "true" ? true : (text == "false" ? false : nil)
    }

    static func isFilterName(_ name: String) -> Bool {
        textFilters[name] != nil || idFilters[name] != nil || otherFilters.contains(name)
    }

    /// エラーメッセージ用の既知フィルタ名一覧(五十音・アルファベット順ではなく列挙順)
    static var knownFilterNamesDescription: String {
        (textFilters.keys.sorted() + idFilters.keys.sorted() + otherFilters.sorted())
            .joined(separator: " / ")
    }

    /// フィルタ名の「基底名」(属性名 + otherFilters)。text/value/placeholder/id は
    /// filterName の生成元、type/pos/checked/enabled はそのまま完全形
    static let baseFilterNames = ["text", "value", "placeholder", "id"] + otherFilters

    /// フィルタ名の「書き損じ」と断定できるか。**素の文字列に `名前=値` はよく現れる**ので
    /// (SUT の状態表示 `notify=off` など)、既知名と紛らわしいものだけを落とす。
    /// 判定は4規則: ①前方一致関係(3文字以上) ②大小文字だけ違う ③6文字以上で1文字違い
    /// ④基底名(text/value/placeholder/id/type/pos/checked/enabled)を接頭辞に持ち、
    /// 直後が ASCII 大文字(`idPrefix` `textFoo` 等。`identifier` のような小文字継続は対象外)
    static func isNearMissFilterName(_ name: String) -> Bool {
        let known = Array(textFilters.keys) + Array(idFilters.keys) + Array(otherFilters)
        let lowered = name.lowercased()
        for candidate in known {
            if candidate.lowercased() == lowered { return true }
            let shared = min(candidate.count, name.count)
            if shared >= 3, name.hasPrefix(candidate) || candidate.hasPrefix(name) { return true }
            if name.count >= 6, abs(candidate.count - name.count) <= 1,
               editDistanceIsAtMostOne(name, candidate) { return true }
        }
        for base in baseFilterNames where name.count > base.count && name.hasPrefix(base) {
            let next = name[name.index(name.startIndex, offsetBy: base.count)]
            if next.isASCII, next.isUppercase { return true }
        }
        return false
    }

    /// 編集距離が 1 以下か(置換・挿入・削除を1回まで)。書き損じ判定にしか使わない
    static func editDistanceIsAtMostOne(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count == y.count { i += 1; j += 1 } else if x.count > y.count { i += 1 } else { j += 1 }
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }

    /// 文字列値の `*` 記法。**素の文字列は完全一致**(部分一致は必ず記法で明示する)
    static func textLocator(_ raw: String) -> FlowLocator {
        let parsed = partialMatch(raw)
        return FlowLocator(label: parsed.text, labelMatch: parsed.mode == .exact ? nil : parsed.mode)
    }

    /// `#` 短縮形の値。text の素トークンと同じ `*` 記法(partialMatch)を適用する
    /// (`id=` 完全形はワイルドカード展開しない。text= と同じ非対称)
    static func idLocator(_ raw: String) -> FlowLocator {
        let parsed = partialMatch(raw)
        return FlowLocator(id: parsed.text, idMatch: parsed.mode == .exact ? nil : parsed.mode)
    }

    /// public: システムアラートの照合(SystemAlertDismissal)が同じ `*` 解釈を使う
    /// (別実装を持つと「セレクタと同じ記法」という契約が2箇所でズレる)
    public static func partialMatch(_ raw: String) -> (text: String, mode: FlowMatchMode) {
        let lead = raw.hasPrefix("*")
        let trail = raw.hasSuffix("*")
        if lead, trail, raw.count >= 3 { return (String(raw.dropFirst().dropLast()), .contains) }
        if trail, raw.count >= 2 { return (String(raw.dropLast()), .startsWith) }
        if lead, raw.count >= 2 { return (String(raw.dropFirst()), .endsWith) }
        return (raw, .exact)
    }

    // MARK: - 分割

    /// 区切り文字で分割する。ただし括弧の外だけ(`:right(a||b)` を割らない)
    static func splitTopLevel(_ text: String, separator: String) -> [String] {
        guard let first = separator.first else { return [text] }
        var parts: [String] = []
        var current = ""
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "(" {
                depth += 1
            } else if char == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, char == first, text[index...].hasPrefix(separator) {
                parts.append(current)
                current = ""
                index = text.index(index, offsetBy: separator.count)
                continue
            }
            current.append(char)
            index = text.index(after: index)
        }
        parts.append(current)
        return parts
    }

    static func matchingParen(_ text: String, open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - シリアライズ

    /// FlowLocator をセレクタ式の 1 節に戻す(修正提案・コード生成用)。
    /// scope / 相対ステップも含めて往復する(parse(serialize(x)) == x)
    public static func serialize(_ locator: FlowLocator) -> String {
        var text = serializeFilters(locator)
        guard !text.isEmpty else { return "" }
        for step in locator.relative ?? [] { text += serializeStep(step) }
        let scopeTexts = (locator.scope ?? []).map(serialize).filter { !$0.isEmpty }
        if !scopeTexts.isEmpty {
            text = scopeTexts.joined(separator: " >> ") + " >> " + text
        }
        return text
    }

    static func serializeStep(_ step: FlowRelativeStep) -> String {
        let filters = step.filter ?? []
        // 型だけの単独フィルタは型別ショートハンドへ畳む(`:right(.switch)` → `:rightSwitch`)
        var suffix = ""
        var argument: String?
        if filters.count == 1, let type = filters[0].type, onlyType(filters[0]),
           let match = relativeTypes.first(where: { $0.type == type }) {
            suffix = match.suffix
        } else if !filters.isEmpty {
            argument = filters.map(serialize).filter { !$0.isEmpty }.joined(separator: "||")
        }
        var text = ":\(step.direction.rawValue)\(suffix)"
        if let ordinal = step.ordinal, ordinal > 1 {
            // 序数とフィルタ式は同居できないので、各フィルタ側の `&&[n]` として書く
            // (パース側が「全フィルタが同じ [n]」を序数へ吸い戻す)
            if let argument, !argument.isEmpty {
                let withOrdinal = filters.map { serialize($0) + "&&[\(ordinal)]" }
                    .joined(separator: "||")
                text += "(\(withOrdinal))"
                return text
            }
            text += "(\(ordinal))"
            return text
        }
        if let argument, !argument.isEmpty { text += "(\(argument))" }
        return text
    }

    static func onlyType(_ locator: FlowLocator) -> Bool {
        locator.id == nil && locator.label == nil && locator.value == nil
            && locator.placeholder == nil && locator.checked == nil && locator.enabled == nil
            && locator.index == nil && (locator.relative?.isEmpty ?? true)
            && (locator.scope?.isEmpty ?? true) && (locator.not?.isEmpty ?? true)
    }

    /// 除外条件を `属性!=値` のトークン列へ(パースの逆写像)。
    /// entry は属性1つだけが設定されている前提(parseNegatedFilter がそう作る)
    private static func serializeNot(_ entries: [FlowLocator]) -> [String] {
        entries.compactMap { entry in
            if let id = entry.id {
                return "\((entry.idMatch ?? .exact).filterName("id"))!=\(id)"
            }
            if let label = entry.label {
                return "\((entry.labelMatch ?? .exact).filterName("text"))!=\(label)"
            }
            if let value = entry.value {
                return "\((entry.valueMatch ?? .exact).filterName("value"))!=\(value)"
            }
            if let placeholder = entry.placeholder {
                return "\((entry.placeholderMatch ?? .exact).filterName("placeholder"))!=\(placeholder)"
            }
            if let type = entry.type { return "type!=\(type)" }
            if let checked = entry.checked { return "checked!=\(checked)" }
            if let enabled = entry.enabled { return "enabled!=\(enabled)" }
            return nil
        }
    }

    /// 属性フィルタ列。よく使う組み合わせは短縮形(`#id` / `.型#id` / `.型[n]`)へ畳み、
    /// それ以外は `&&` で連ねる
    private static func serializeFilters(_ locator: FlowLocator) -> String {
        var tokens: [String] = []
        let negations = serializeNot(locator.not ?? [])
        let single = tokenCount(locator) == 1 && negations.isEmpty
        if let type = locator.type {
            // 型 + もう1条件だけなら短縮形にする(除外条件があるときは後ろに続くので畳まない)。
            // idToken が `#` 形を返すときだけ畳める(`id=` 形は `.型` と合成できないため)
            if locator.id != nil, tokenCount(locator) == 2, negations.isEmpty {
                let token = idToken(locator)
                if token.hasPrefix("#") { return ".\(type)\(token)" }
            }
            if let index = locator.index, index > 0, tokenCount(locator) == 2, negations.isEmpty {
                return ".\(type)[\(index + 1)]"
            }
            tokens.append(".\(type)")
        }
        if locator.id != nil { tokens.append(idToken(locator)) }
        if locator.label != nil { tokens.append(textToken(locator, standalone: single)) }
        if let value = locator.value {
            tokens.append("\((locator.valueMatch ?? .exact).filterName("value"))=\(value)")
        }
        if let placeholder = locator.placeholder {
            tokens.append("\((locator.placeholderMatch ?? .exact).filterName("placeholder"))=\(placeholder)")
        }
        if let checked = locator.checked { tokens.append("checked=\(checked)") }
        if let enabled = locator.enabled { tokens.append("enabled=\(enabled)") }
        // 1番目は普段は省略するが、序数しか条件が無い節(`#list >> [1]`)では書かないと式が空になる
        if let index = locator.index, index > 0 || (tokens.isEmpty && negations.isEmpty) {
            tokens.append("[\(index + 1)]")
        }
        tokens.append(contentsOf: negations)
        return tokens.joined(separator: "&&")
    }

    /// 短縮形にできるかの判定に使う「条件の数」(index は 0 のとき条件ではない)
    private static func tokenCount(_ locator: FlowLocator) -> Int {
        var count = 0
        if locator.id != nil { count += 1 }
        if locator.label != nil { count += 1 }
        if locator.value != nil { count += 1 }
        if locator.placeholder != nil { count += 1 }
        if locator.type != nil { count += 1 }
        if locator.checked != nil { count += 1 }
        if locator.enabled != nil { count += 1 }
        if let index = locator.index, index > 0 { count += 1 }
        return count
    }

    /// id フィルタ 1 個分。`*` 記法で書ける(値自体が `*` を含まない)ならそちらを優先し、
    /// そうでなければ完全形 `idStartsWith=...` に落とす(textToken と同じ流儀)。
    /// 完全一致でも値自体が先頭/末尾 `*` を持つなら `#` 短縮形は使わない
    /// (再パースでワイルドカードに化けるため。textToken の needsEscape と同じ理由)
    private static func idToken(_ locator: FlowLocator) -> String {
        guard let id = locator.id else { return "" }
        let mode = locator.idMatch ?? .exact
        if mode == .exact {
            return (id.hasPrefix("*") || id.hasSuffix("*")) ? "id=\(id)" : "#\(id)"
        }
        if !id.contains("*") {
            switch mode {
            case .contains: return "#*\(id)*"
            case .startsWith: return "#\(id)*"
            case .endsWith: return "#*\(id)"
            default: break
            }
        }
        return "\(mode.filterName("id"))=\(id)"
    }

    /// text フィルタ 1 個分。standalone(節に他の条件が無い)なら `=` エスケープが使えるが、
    /// 合成中は使えないので完全形 `text=...` に落とす。
    /// **既知の非対応**: `&&` `||` `>>` や `:英字(` を含むラベルを他条件と合成することはできない
    /// (`text=` に落としても検証が節全体を見て拒否する。実 UI では起きない。standalone の `=` は可)
    private static func textToken(_ locator: FlowLocator, standalone: Bool) -> String {
        guard let label = locator.label else { return "" }
        let mode = locator.labelMatch ?? .exact
        if mode == .exact {
            guard needsEscape(label) else { return label }
            return standalone ? "=\(label)" : "text=\(label)"
        }
        // `*` 記法で書ける(値自体が `*` を含まない)ならそちらを優先する
        if !label.contains("*"), !needsEscape(label) {
            switch mode {
            case .contains: return "*\(label)*"
            case .startsWith: return "\(label)*"
            case .endsWith: return "*\(label)"
            default: break
            }
        }
        return "\(mode.filterName("text"))=\(label)"
    }

    /// 素の文字列として書くと別の構文に読まれてしまう、**または validationError が拒否する**ラベルか。
    /// 検証が落とすパターン(未知マーカー・方向名の書き損じ)も含める — 含めないと serialize
    /// (ヒール提案・コード生成)がそのまま構文エラーになる式を吐く
    static func needsEscape(_ label: String) -> Bool {
        if label.isEmpty { return true }
        if label.hasPrefix("#") || label.hasPrefix(".") || label.hasPrefix("=")
            || label.hasPrefix("[") || label.hasPrefix("*") || label.hasSuffix("*")
            || label.hasPrefix("<") { return true }
        if label.contains(">>") || label.contains("||") || label.contains("&&") { return true }
        if firstRelativeMarker(in: label) != nil { return true }
        if unknownMarker(in: label) != nil { return true }
        if malformedRelativeName(in: label) != nil { return true }
        // `(a|b)` はフィルタ内 OR に読まれるのでラベルとしては書けない
        if firstGroup(in: label) != nil { return true }
        // `名前=値` / `名前!=値` はフィルタ名と紛らわしいときだけエスケープが要る
        // (`notify=off` はそのままでよい)
        if let eqIndex = label.firstIndex(of: "=") {
            var nameEnd = eqIndex
            if nameEnd > label.startIndex, label[label.index(before: nameEnd)] == "!" {
                nameEnd = label.index(before: nameEnd)
            }
            let name = String(label[label.startIndex..<nameEnd])
            if isAsciiIdentifier(name), isFilterName(name) || isNearMissFilterName(name) {
                return true
            }
        }
        return false
    }

    /// 単一引数 `type("...")` にセレクタが渡されている疑い(**引数落とし**の検出)。
    /// あの形は「フォーカス中の要素へこの文字列を入力する」なので、セレクタを渡すと
    /// **`#email` という文字列を打ち込んで先へ進み**、失敗するのは後段の検証になる(原因から遠い)。
    /// **誤検知しない形にだけ絞る**: `#` + 識別子だけの1語 / `||` / `>>` を含む。
    /// これらを文字どおり入力したいときは2引数形 `type(欄のセレクタ, "#foo")` で書ける
    /// (単一引数形だけが曖昧なので、逃げ道は既存 API で足りる)
    public static func selectorLikeInputError(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let hint = "`type(\"\(trimmed)\")` types that text into the focused element"
            + " — the single-argument form takes text, not a selector."
            + " Use `type(<selector>, \"<text>\")` to target a field,"
            + " or `tap(<selector>)` first and then pass only the text."
        if trimmed.contains("||") || trimmed.contains(">>") { return hint }
        guard trimmed.hasPrefix("#"), trimmed.count >= 2,
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        let body = trimmed.dropFirst()
        let isIDBody = body.allSatisfy { char in
            (char.isASCII && (char.isLetter || char.isNumber)) || "_-*".contains(char)
        }
        return isIDBody ? hint : nil
    }

    static func isAsciiIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter, first.isASCII else { return false }
        return text.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII }
    }

    /// ロケータ連鎖をセレクタ式に戻す
    public static func serialize(primary: FlowLocator, fallbacks: [FlowLocator]) -> String {
        ([primary] + fallbacks).map(serialize).filter { !$0.isEmpty }.joined(separator: "||")
    }

    // MARK: - 構文検証

    /// セレクタ式の構文エラー(無ければ nil)。**パースと違い失敗する**のがこの関数の存在理由:
    /// パースは解釈できない節を text に落とすため、`:rigth(x)` のような綴り誤りが「そんなラベルは
    /// 無い」= notExist/countIs(x,0) では**必ず成功**になってしまう。実行前にここで落とす。
    /// 呼ぶのは run 開始時の一括検査と `api run --dry-run`(デバイス不要)。
    public static func validationError(_ text: String) -> String? {
        if let error = unbalancedParenError(text) { return error }
        for clause in splitTopLevel(text, separator: "||") {
            if clause.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let error = clauseError(clause) { return error }
        }
        return nil
    }

    /// `||` で割った 1 節(`>>` のスコープ連鎖を含む)。相対セレクタの引数も同じ文法なので
    /// **検証もここを共有する**(引数の中の綴り誤り・スコープを見逃さないため)
    private static func clauseError(_ clause: String) -> String? {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "there is an empty clause (check around `>>` and `||`)" }
        // `=` エスケープは全体が生ラベル = 構文解釈しない
        if trimmed.hasPrefix("=") { return nil }
        let segments = splitTopLevel(trimmed, separator: ">>")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for (offset, segment) in segments.enumerated() {
            let isTarget = offset == segments.count - 1
            if let error = segmentError(segment, isScoped: segments.count > 1, isTarget: isTarget) {
                return error
            }
        }
        return nil
    }

    private static func unbalancedParenError(_ text: String) -> String? {
        var depth = 0
        for char in text {
            if char == "(" { depth += 1 }
            if char == ")" {
                depth -= 1
                if depth < 0 { return "unbalanced closing parenthesis: \"\(text)\"" }
            }
        }
        return depth > 0 ? "unclosed parenthesis: \"\(text)\"" : nil
    }

    private static func segmentError(_ segment: String, isScoped: Bool, isTarget: Bool) -> String? {
        if segment.isEmpty { return "there is an empty clause (check around `>>` and `||`)" }
        if segment.hasPrefix("=") { return nil }
        // `:名前(` の形をした未知のマーカー(綴り誤り・他ツール記法の混入)
        if let unknown = unknownMarker(in: segment) { return unknownMarkerError(unknown, segment) }
        // 括弧を伴わない綴り誤り(`:rihgt` `:rightFoo`)。方向名で始まるのに正しいコマンドでないものだけを
        // 落とす(無関係なラベル中の `:` を巻き込まないための条件)
        if let bad = malformedRelativeName(in: segment) {
            return unknownMarkerError(":\(bad)", segment)
        }
        let split = splitRelativeChain(segment)
        // `<` 始まりは括弧形式(`<基準>:方向型`)の予約。読めなければ黙って生ラベルにせず落とす
        // (`<通知>:rigthSwitch` のような書き損じ・閉じ忘れが notExist で緑になるのを防ぐ。
        // `<` で始まる生ラベルは `=` エスケープで書く)
        if split.steps.isEmpty, segment.hasPrefix("<") {
            return "a clause starting with `<` can only take the form `<anchor>:directionType`: \"\(segment)\"."
                + " Check the closing `>` and the `:direction` right after it (scopes go outside the brackets; escape a label with a leading =)"
        }
        // 相対セレクタに見えるのに読めない = 基準が空・引数が空・後ろに余分な文字。
        // 放置すると丸ごとラベル扱いになり notExist が必ず成功する
        if split.steps.isEmpty, firstRelativeMarker(in: segment) != nil {
            return "cannot parse as a relative selector: \"\(segment)\"."
                + " Write it as `anchor:directionType` (check that the anchor and argument are non-empty and nothing trails)"
        }
        if !split.steps.isEmpty {
            if let error = filterListError(split.base, isScoped: isScoped, isTarget: false) {
                return error
            }
            // 引数は**生テキストのまま**検証する(パース結果を直列化し直すと、ラベルに落ちた
            // 綴り誤り `textContans=x` がエスケープされて見えなくなる)
            for argument in split.arguments {
                guard let argument, Int(argument) == nil else { continue }
                for alternative in splitTopLevel(argument, separator: "||") {
                    if let error = clauseError(alternative) { return error }
                }
            }
            return nil
        }
        return filterListError(segment, isScoped: isScoped, isTarget: isTarget)
    }

    /// 相対ステップを含まない `&&` 列の検証
    private static func filterListError(_ text: String, isScoped: Bool, isTarget: Bool) -> String? {
        let tokens = splitTopLevel(text, separator: "&&")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.contains(where: { $0.isEmpty }) {
            return "missing a condition before or after `&&`: \"\(text)\""
        }
        var seen: Set<String> = []
        for token in tokens {
            if let error = tokenError(token) { return error }
            if let attribute = attributeName(token) {
                if !seen.insert(attribute).inserted {
                    return "the same condition is written twice (\(attribute)): \"\(text)\""
                }
            }
        }
        // 絞り込み条件が1つも無い節(`[2]` だけ等)はスコープの中でしか意味を持たない
        let locator = parseFilters(text)
        if locator.hasNoFilter, !(locator.not?.isEmpty ?? true) {
            // 「〇〇以外の全要素」は容器・レイアウトノードまで掴む。肯定条件との併用を促す
            return "a clause with only negative conditions (`!=`) is not allowed: \"\(text)\""
                + " (combine it with a narrowing condition, e.g. `.button&&text!=Cancel`)"
        }
        if locator.hasNoFilter, !(isScoped && isTarget) {
            return locator.index == nil
                ? "there is a clause with no conditions: \"\(text)\""
                : "an ordinal-only clause is only allowed as `ancestor >> [n]`: \"\(text)\""
        }
        // 展開後のロケータ数(`(a|b)&&(c|d)` の直積)は実行前に上限で止める
        if parseFilterVariants(text).count >= maxExpansion {
            return "too many `(a|b)` combinations (limit \(maxExpansion)): \"\(text)\""
        }
        return nil
    }

    /// 節の中で重複を検出するための条件名(index は重複しても無害なので対象外)。
    /// 否定は肯定と別の条件(`text=A&&text!=B` は矛盾ではない)なので `!` を付けて区別する。
    /// **否定同士の重複は見ない**(`text!=A&&text!=B` は正当な絞り込み)
    private static func attributeName(_ token: String) -> String? {
        // 否定は同じ属性を何度でも書ける(`!#a&&!#b`)。短縮形・完全形とも重複判定から外す
        if token.hasPrefix("!") { return nil }
        if token.hasPrefix("#") { return "id" }
        if token.hasPrefix(".") { return token.contains("#") ? "id" : "type" }
        if token.hasPrefix("[") { return nil }
        guard let eqIndex = token.firstIndex(of: "=") else { return "text" }
        if eqIndex > token.startIndex, token[token.index(before: eqIndex)] == "!" { return nil }
        let name = String(token[token.startIndex..<eqIndex])
        guard isFilterName(name) else { return "text" }
        if let text = textFilters[name] {
            switch text.attribute {
            case .text: return "text"
            case .value: return "value"
            case .placeholder: return "placeholder"
            }
        }
        if idFilters[name] != nil { return "id" }
        return name == "pos" ? nil : name
    }

    private static func tokenError(_ token: String) -> String? {
        if token.hasPrefix("=") { return nil }
        // `!` 短縮形は中身を同じ規則で検査する(`!textContans=x` の綴り誤りを見逃さない)
        if token.hasPrefix("!"), token.count > 1, !token.hasPrefix("!=") {
            let inner = String(token.dropFirst())
            // 序数の否定は候補集合を絞れず**黙って無視される**ので、書けたことにしない
            // (完全形の `pos!=n` を弾いているのと同じ理由)
            if inner.hasPrefix("["), inner.hasSuffix("]") {
                return "an ordinal cannot be negated: \"\(token)\""
            }
            return tokenError(inner)
        }
        if token.allSatisfy({ $0 == "*" }) {
            return "the partial match is empty: \"\(token)\" (write it like `*word*`)"
        }
        if let error = groupError(token) { return error }
        if token.hasPrefix("["), token.hasSuffix("]") {
            return ordinalError(token, inner: String(token.dropFirst().dropLast()))
        }
        if let error = negatedFilterError(token) { return error }
        if let error = typeEqualsError(token) { return error }
        if let error = namedFilterError(token) { return error }
        return ordinalError(token) ?? typeCaseError(token)
    }

    /// フィルタ内 OR(`(a|b)`)の中身が空でないか。空の選択肢を通すと「ラベルが空の要素」に
    /// 一致するロケータが黙って生まれる(`(保存|)` や `(a||b)` の書き損じ)
    private static func groupError(_ token: String) -> String? {
        guard !token.hasPrefix("="), let group = firstGroup(in: token) else { return nil }
        let inner = String(token[token.index(after: group.open)..<group.close])
        let alternatives = splitTopLevel(inner, separator: "|")
        if alternatives.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "an `(a|b)` alternative is empty: \"\(token)\" (the separator is a single `|`)"
        }
        // 残りのグループも見る(先頭グループを潰した形で再帰)
        let rest = String(token[token.startIndex..<group.open])
            + (alternatives.first ?? "") + String(token[token.index(after: group.close)...])
        return groupError(rest)
    }

    /// `名前!=値` の検証。名前が既知でない・値が空・pos の否定はここで落とす
    /// (通さないと丸ごとラベル扱いになり notExist / countIs(x,0) が黙って成功する)
    private static func negatedFilterError(_ token: String) -> String? {
        guard !token.hasPrefix("."), !token.hasPrefix("#"),
              let eqIndex = token.firstIndex(of: "="), eqIndex > token.startIndex,
              token[token.index(before: eqIndex)] == "!" else { return nil }
        let name = String(token[token.startIndex..<token.index(before: eqIndex)])
        let value = String(token[token.index(after: eqIndex)...])
        guard isAsciiIdentifier(name) else { return nil }
        guard isFilterName(name) else {
            // 既知名と紛らわしくない `名前!=値` は素の文字列(SUT の表示 `count!=0` 等)として通す。
            // 判定規則は肯定形(namedFilterError)と同じ
            guard isNearMissFilterName(name) else { return nil }
            return "the filter \"\(name)\" cannot be negated: \"\(token)\". Allowed: \(knownFilterNamesDescription)"
        }
        if name == "pos" { return "pos cannot be negated: \"\(token)\"" }
        if value.isEmpty { return "the value of filter \"\(name)!=\" is empty" }
        if name == "checked" || name == "enabled", boolValue(value) == nil {
            return "\(name) must be true or false: \"\(token)\""
        }
        return nil
    }

    /// `.型=ラベル` の検出。パースは `=` 以降を型名の一部として黙って読む(never-match)ため、
    /// ここで落とさないと notExist / countIs(x,0) が必ず成功する。
    /// 案の型は先頭小文字に正規化する(`.Button=x` に typeCaseError と二段の案内をさせない)
    private static func typeEqualsError(_ token: String) -> String? {
        guard token.hasPrefix("."),
              let eqIndex = token.firstIndex(of: "="),
              token.firstIndex(of: "#").map({ eqIndex < $0 }) ?? true else { return nil }
        let type = String(token[token.index(after: token.startIndex)..<eqIndex])
        let label = String(token[token.index(after: eqIndex)...])
        var corrected = type.isEmpty ? "" : ".\(ElementInfo.normalizedType(type))"
        if !label.isEmpty { corrected += corrected.isEmpty ? label : "&&\(label)" }
        return "\"=\" is not allowed in a type name (join conditions with `&&`): \"\(token)\" → \"\(corrected)\""
    }

    /// `名前=値` の名前が ASCII 識別子なのに既知のフィルタ名でない = 綴り誤り。
    /// 放置すると丸ごとラベル扱いになり notExist が必ず成功する(黙って緑になる経路)
    private static func namedFilterError(_ token: String) -> String? {
        guard !token.hasPrefix("."), !token.hasPrefix("#"),
              let eqIndex = token.firstIndex(of: "=") else { return nil }
        let name = String(token[token.startIndex..<eqIndex])
        guard isAsciiIdentifier(name) else { return nil }
        if isFilterName(name) {
            let value = String(token[token.index(after: eqIndex)...])
            if value.isEmpty { return "the value of filter \"\(name)=\" is empty" }
            if name == "checked" || name == "enabled", boolValue(value) == nil {
                return "\(name) must be true or false: \"\(token)\""
            }
            if name == "pos" { return ordinalError(token, inner: value) }
            return nil
        }
        // 既知名と紛らわしくない `名前=値` は素の文字列(SUT の状態表示 `notify=off` 等)として通す
        guard isNearMissFilterName(name) else { return nil }
        return "unknown filter name \"\(name)\": \"\(token)\". Allowed: \(knownFilterNamesDescription)"
            + " (to write it as a label, escape it with a leading =)"
    }

    private static func unknownMarkerError(_ marker: String, _ segment: String) -> String {
        let known = directions.map { ":\($0.name)" }.joined(separator: " / ")
        let suffixes = relativeTypes.map { $0.suffix }.joined(separator: " / ")
        return "unknown selector syntax \"\(marker)\": \"\(segment)\"."
            + " Allowed: \(known) (type variants end with \(suffixes))"
            + ". To include it in a label, escape it with a leading ="
    }

    /// 型名は先頭小文字(`.button`)。スナップショットが返す型名と同じ綴りに揃えてある
    /// (ElementInfo.normalizedType)。`.Button` は決して一致しないので明示エラーにする
    private static func typeCaseError(_ token: String) -> String? {
        guard token.hasPrefix("."), token.count > 1 else { return nil }
        let body = token.dropFirst()
        guard let first = body.first, first.isUppercase else { return nil }
        let corrected = first.lowercased() + body.dropFirst()
        return "type names start with a lowercase letter: \"\(token)\" → \".\(corrected)\""
    }

    /// `.型[n]` の n が 1 以上の整数か。`[abc]` や `[0]` は型名の一部として黙って解釈され、
    /// 決して一致しないロケータになるためここで落とす
    private static func ordinalError(_ token: String) -> String? {
        guard token.hasPrefix("."), token.hasSuffix("]"),
              let bracket = token.firstIndex(of: "[") else { return nil }
        return ordinalError(token,
                            inner: String(token[token.index(after: bracket)..<token.index(before: token.endIndex)]))
    }

    private static func ordinalError(_ token: String, inner: String) -> String? {
        guard let ordinal = Int(inner) else {
            return "ordinals must be integers (1-origin): \"\(token)\""
        }
        return ordinal >= 1 ? nil : "ordinals must be 1 or greater (1-origin): \"\(token)\""
    }

    /// `:` の後ろが方向名で始まるのに既知のコマンドでないもの(`:rightFoo` `:righ`)。
    /// 括弧が無いと unknownMarker では拾えず、丸ごとラベル扱いになって notExist が必ず成功する
    static func malformedRelativeName(in segment: String) -> String? {
        var index = segment.startIndex
        var depth = 0
        while index < segment.endIndex {
            let char = segment[index]
            if char == "(" { depth += 1 }
            if char == ")" { depth = max(0, depth - 1) }
            if depth == 0, char == ":", relativeCommand(segment, after: index) == nil {
                var cursor = segment.index(after: index)
                while cursor < segment.endIndex, segment[cursor].isLetter {
                    cursor = segment.index(after: cursor)
                }
                let name = String(segment[segment.index(after: index)..<cursor])
                if !name.isEmpty, isNearMissCommand(name) { return name }
            }
            index = segment.index(after: index)
        }
        return nil
    }

    /// 既知のコマンドの「書き損じ」と断定できる名前か。
    /// **既知の残穴**: `:rigth` のような入れ替え誤りは括弧付き(`:rigth(x)`)なら unknownMarker が
    /// 捕まえるが、括弧なしでは捕まらない(誤検出を避けるため字面が近いだけでは落とさない)。
    /// 判定はこの2規則だけ: ①方向名との前方一致関係にある ②既知コマンドと大小文字だけ違う
    static func isNearMissCommand(_ name: String) -> Bool {
        if directions.contains(where: { name.hasPrefix($0.name) || $0.name.hasPrefix(name) }) {
            return true
        }
        let lowered = name.lowercased()
        for (direction, _) in directions.map({ ($0.name, $0.direction) }) {
            if lowered == direction { return true }
            for suffix in relativeTypes.map(\.suffix) where lowered == (direction + suffix).lowercased() {
                return true
            }
        }
        return false
    }

    /// `:` + 英字 + `(` の並びのうち、既知の相対コマンドでないもの
    static func unknownMarker(in segment: String) -> String? {
        var index = segment.startIndex
        while let colon = segment[index...].firstIndex(of: ":") {
            var cursor = segment.index(after: colon)
            while cursor < segment.endIndex, segment[cursor].isLetter {
                cursor = segment.index(after: cursor)
            }
            if cursor < segment.endIndex, segment[cursor] == "(", cursor > segment.index(after: colon) {
                if relativeCommand(segment, after: colon) == nil {
                    return String(segment[colon...cursor])
                }
            }
            guard colon < segment.endIndex else { break }
            index = segment.index(after: colon)
        }
        return nil
    }
}
