// Flow.swift
// ステップのインメモリ内部モデル。コード生成(ScenarioCodeGen)の入力・
// StepExecutor の実行単位・ヒールキャッシュの JSON 型として使う(永続化フォーマットではない)。

import Foundation

public struct Flow: Codable, Sendable {
    public var name: String
    public var app: String
    /// ios / android。省略時は実行時の --platform 指定に従う
    public var platform: String?
    public var goal: String?
    public var generatedBy: String
    /// 自己修復などで書き換えられ、人間のレビューが必要な状態
    public var dirty: Bool?
    public var steps: [FlowStep]

    public init(name: String, app: String, platform: String? = nil, goal: String?,
                generatedBy: String, dirty: Bool? = nil, steps: [FlowStep]) {
        self.name = name
        self.app = app
        self.platform = platform
        self.goal = goal
        self.generatedBy = generatedBy
        self.dirty = dirty
        self.steps = steps
    }
}

/// action(操作)か assert(検証)のどちらか一方を持つステップ。
/// enum ではなくフラットな構造(片方だけが非 nil)にしている。
public struct FlowStep: Codable, Sendable {
    /// tap / type / swipe / press / scrollTo(要素が見つかるまでスクロール)
    public var action: String?
    /// exists / notExists / valueEquals / textEquals / enabled / disabled / count / screenMatches
    public var assert: String?
    public var locator: FlowLocator?
    /// ロケータ解決の代替チェーン(id > label > type+index)
    public var fallbacks: [FlowLocator]?
    public var text: String?
    public var direction: String?
    /// screenMatches 用の期待状態(自然言語。マルチモーダル画面検証に使う)
    public var expected: String?
    /// 秒(整数)。検証(assert)では要素出現待ちの上限。アクションではロケータ解決の
    /// 再試行待ち上限(nil = 既定の約0.7秒 / 0 = 再試行なし。optional ステップの空振り短縮用)
    public var timeout: Int?
    /// scrollTo のスクロール回数上限(省略時 8)
    public var maxSwipes: Int?
    /// press の長押し秒数(nil = defaultPressDuration)。**ブリッジの /press は元から duration を
    /// 受け取っており**、ここが nil だった間だけホスト側で 1.0 に潰れていた(DSL の press(duration:)と
    /// 拡張のパラメーター編集が無効化されていた)。既定値と同じなら nil のまま置く
    /// (生成コード・JSON を既定ケースで太らせないため)
    public var duration: Double?
    /// count アサーションの期待個数(DSL の countIs)。他のステップでは nil
    public var expectedCount: Int?
    /// true のとき、ロケータが解決できなくても失敗にせずスキップする
    /// (パスワード保存シート等、出るかどうか不定なシステムダイアログの処理用)
    public var optional: Bool?
    /// 探索時に FM が述べた意図(リプレイでは使わないがレビューの助けになる)
    public var note: String?
    /// [occlusion-guard] true のとき、この検証(exists/textEquals)がツリー一致で pass した直後に
    /// FM でスクショ視覚照合し、覆われ/切れ/不在なら偽陽性として失敗へ反転する。DSL の visible() が立てる。
    /// nil = executor 既定(StepExecutor.occlusionGuard)に従う。
    public var occlusionGuard: Bool?

    /// press の既定の長押し秒数。DSL の `press(duration:)` 既定値・拡張のパラメーター既定値
    /// (StepCommandParams.durationSpec)・実行時のフォールバックはこの1つに揃える
    public static let defaultPressDuration: Double = 1.0

    /// スクロール探索(`scrollTo` / `tap(scroll:)` / `exist(scroll:)`)の既定スワイプ上限。
    /// DSL の既定引数と StepCommandParams.maxSwipesSpec はこの1つに揃える
    public static let defaultMaxSwipes = 8
    /// 端まで送る(scrollToBottom 等)の上限。**終了条件は「画面が変わらなくなること」**で、
    /// これは暴走を止める安全網にすぎないので探索(8)より大きく取る
    public static let defaultMaxEdgeSwipes = 50

    public init(action: String? = nil, assert: String? = nil, locator: FlowLocator? = nil,
                fallbacks: [FlowLocator]? = nil, text: String? = nil, direction: String? = nil,
                expected: String? = nil, timeout: Int? = nil, maxSwipes: Int? = nil,
                duration: Double? = nil,
                expectedCount: Int? = nil,
                optional: Bool? = nil, note: String? = nil, occlusionGuard: Bool? = nil) {
        self.action = action
        self.assert = assert
        self.locator = locator
        self.fallbacks = fallbacks
        self.text = text
        self.direction = direction
        self.expected = expected
        self.timeout = timeout
        self.maxSwipes = maxSwipes
        self.duration = duration
        self.expectedCount = expectedCount
        self.optional = optional
        self.note = note
        self.occlusionGuard = occlusionGuard
    }
}

/// 文字列属性(label / value / placeholder)の一致方法。**既定は exact**(素のラベルは完全一致)で、
/// 部分一致は記法で明示したときだけ(`*x*` / `x*` / `*x` / `textMatches=`)。
/// matches は**部分一致の正規表現**(全体一致は `^...$`)で、
/// textMatches アサーション(StepExecutor.matchedText)と同じ規約。
public enum FlowMatchMode: String, Codable, Equatable, Sendable {
    case exact, startsWith, contains, endsWith, matches

    /// 実属性値がこの一致方法で expected を満たすか。nil の属性は常に不一致
    public func matches(_ actual: String?, _ expected: String) -> Bool {
        guard let actual else { return false }
        switch self {
        case .exact: return actual == expected
        case .startsWith: return actual.hasPrefix(expected)
        case .contains: return actual.contains(expected)
        case .endsWith: return actual.hasSuffix(expected)
        case .matches: return actual.range(of: expected, options: .regularExpression) != nil
        }
    }

    /// セレクタ式のフィルタ名(属性名 + 一致方法)。exact は接尾辞なし。
    /// 属性名は `text`(=ラベル。textIs/textContains アサーションと同じ語) / `value` / `placeholder`
    public func filterName(_ attribute: String) -> String {
        switch self {
        case .exact: return attribute
        case .startsWith: return attribute + "StartsWith"
        case .contains: return attribute + "Contains"
        case .endsWith: return attribute + "EndsWith"
        case .matches: return attribute + "Matches"
        }
    }
}

/// 相対セレクタの1ステップ(`通知:rightSwitch` の `:rightSwitch` 側)。
/// **基準要素から見て** direction 方向にある候補のうち、filter に合うものを近い順に並べ ordinal 番目を採る。
/// 連鎖できる(`通知:right:belowButton`)ので FlowLocator は配列で持つ。
public struct FlowRelativeStep: Codable, Equatable, Sendable {
    public var direction: FlowDirection
    /// 対象の絞り込み。`||` を書けるので配列(先に**方向解決まで成功した**節を採る)。
    /// nil / 空 = `.widget`(型エイリアス。役割が確定した要素だけ = 容器を掴まない)
    public var filter: [FlowLocator]?
    /// 近い順の序数(1 オリジン。nil = 1番目)。表記も内部値も 1 オリジンで統一する
    /// (`index` は 0 オリジンで別物。混同しないこと)
    public var ordinal: Int?

    public init(direction: FlowDirection, filter: [FlowLocator]? = nil, ordinal: Int? = nil) {
        self.direction = direction
        self.filter = filter
        self.ordinal = ordinal
    }
}

/// セレクタ式1節の解釈結果。**属性フィルタは全て AND**(セレクタ式の `&&`)で、
/// 設定されているフィールドだけが条件になる(nil = 条件にしない)。
public struct FlowLocator: Codable, Equatable, Sendable {
    public var id: String?
    /// id の一致方法(nil = exact)。text 系の labelMatch と同じ規約
    public var idMatch: FlowMatchMode?
    public var label: String?
    /// label の一致方法(nil = exact)。値だけ設定して mode を nil にすると完全一致になる
    public var labelMatch: FlowMatchMode?
    public var value: String?
    public var valueMatch: FlowMatchMode?
    public var placeholder: String?
    public var placeholderMatch: FlowMatchMode?
    /// 型名(先頭小文字)。エイリアス(`input` / `widget`)も**綴りのまま**保持し、
    /// 照合時に FlowTypeAlias.expand で展開する(往復・表示を書いたとおりに保つため)
    public var type: String?
    /// ElementInfo.checked との一致条件。false は「true でない」= オフ or 状態を持たない要素
    public var checked: Bool?
    public var enabled: Bool?
    /// 候補内の順番(**0 オリジン**。記法 `[n]` / `pos=n` は 1 オリジンなのでパース時に -1 する)。
    /// 型だけでなく全フィルタの組み合わせに対して効く
    public var index: Int?
    /// ScenarioEvent(サブプロセス発の NDJSON)から復元する際の生テキスト。
    /// サブプロセス境界を跨ぐと構造化ロケータは失われ人間可読テキストしか
    /// 残らないため、その場合はこのフィールドのみ設定し summary でそのまま返す
    /// (RunOrchestrator.ScenarioRunner.stepResult(from:) 参照)。プロセス内解決時は nil のまま
    public var raw: String?
    /// 祖先スコープ(外→内)。セレクタ式 `#list >> .clickable[2]` の `#list` 側。
    /// この連鎖で解決した要素の**子孫だけ**を候補にする。index([n])もスコープ内の順序で数えるため、
    /// 画面クロム(戻るボタン・タブ)やスクロール位置に序数が影響されなくなる。
    /// **相対セレクタの基準・対象の双方に効く**(節の中は全部スコープの中で解決する)
    public var scope: [FlowLocator]?
    /// 相対ステップ列(`通知:right:belowButton`)。空でなければ、この FlowLocator の属性フィルタは
    /// **対象ではなく基準(アンカー)**を指す。最終結果は最後のステップの解決結果
    public var relative: [FlowRelativeStep]?
    /// 除外条件(セレクタ式の `text!=キャンセル`)。**1要素につき属性1つだけ**設定された
    /// FlowLocator が並ぶ(パースの構造上そうなる)。どれかに一致した要素を候補から取り除く。
    /// **単独では条件にならない**(hasNoFilter に数えない = 否定だけの節は検証で落とす。
    /// 「〇〇以外の全要素」は容器やレイアウトノードまで掴んで事故になるため)
    public var not: [FlowLocator]?

    public init(id: String? = nil, idMatch: FlowMatchMode? = nil,
                label: String? = nil, labelMatch: FlowMatchMode? = nil,
                value: String? = nil, valueMatch: FlowMatchMode? = nil,
                placeholder: String? = nil, placeholderMatch: FlowMatchMode? = nil,
                type: String? = nil, checked: Bool? = nil, enabled: Bool? = nil,
                index: Int? = nil, raw: String? = nil, scope: [FlowLocator]? = nil,
                relative: [FlowRelativeStep]? = nil, not: [FlowLocator]? = nil) {
        self.id = id
        self.idMatch = idMatch
        self.label = label
        self.labelMatch = labelMatch
        self.value = value
        self.valueMatch = valueMatch
        self.placeholder = placeholder
        self.placeholderMatch = placeholderMatch
        self.type = type
        self.checked = checked
        self.enabled = enabled
        self.index = index
        self.raw = raw
        self.scope = scope
        self.relative = relative
        self.not = not
    }

    /// 属性フィルタが1つも無いか(= 候補を絞れない節)
    public var hasNoFilter: Bool {
        id == nil && label == nil && value == nil && placeholder == nil
            && type == nil && checked == nil && enabled == nil
    }

    public var summary: String {
        if let raw { return raw }
        var text = baseSummary
        for step in relative ?? [] {
            text += ":\(step.direction.rawValue)"
            // 引数の書き方はセレクタ式に合わせる(フィルタ&&[序数] / 序数だけなら括弧に直接)
            var argument = (step.filter ?? []).map(\.summary).joined(separator: "||")
            if let ordinal = step.ordinal, ordinal > 1 {
                argument += argument.isEmpty ? "\(ordinal)" : "&&[\(ordinal)]"
            }
            if !argument.isEmpty { text += "(\(argument))" }
        }
        if let scope, !scope.isEmpty {
            text = scope.map(\.summary).joined(separator: " >> ") + " >> " + text
        }
        return text
    }

    private var baseSummary: String {
        var parts: [String] = []
        if let id { parts.append("\((idMatch ?? .exact).filterName("id"))=\(id)") }
        if let label { parts.append("\((labelMatch ?? .exact).filterName("text"))=\(label)") }
        if let value { parts.append("\((valueMatch ?? .exact).filterName("value"))=\(value)") }
        if let placeholder {
            parts.append("\((placeholderMatch ?? .exact).filterName("placeholder"))=\(placeholder)")
        }
        if let type { parts.append(type) }
        if let checked { parts.append("checked=\(checked)") }
        if let enabled { parts.append("enabled=\(enabled)") }
        // 表示は 1 オリジン、1番目は省略(セレクタ式の表記と揃える。内部 index は 0 オリジン)
        if let index, index > 0 { parts.append("[\(index + 1)]") }
        // 除外条件は各エントリの属性1つを `属性!=値` で見せる(セレクタ式の記法と同じ)。
        // 最初の `=` だけを `!=` に替える(値が `=` を含んでも壊さない)。
        // 型だけの entry は baseSummary が名前を付けない(`button`)ので補う
        for entry in not ?? [] {
            let inner = entry.baseSummary
            if let separator = inner.firstIndex(of: "=") {
                parts.append(inner[..<separator] + "!=" + inner[inner.index(after: separator)...])
            } else {
                parts.append("type!=\(inner)")
            }
        }
        return parts.isEmpty ? "(空)" : parts.joined(separator: "&&")
    }

    /// 「id も label も無い」= 単独では別画面の要素に誤マッチしやすいロケータか。
    /// アサーションのフォールバック連鎖から除外する判定に使う(StepExecutor.resolveDetailed)。
    /// scope / 相対セレクタ付きは錨を打っているので type+index でも除外しない。
    public var isWeakForAssert: Bool {
        id == nil && label == nil && value == nil && placeholder == nil
            && (scope?.isEmpty ?? true) && (relative?.isEmpty ?? true)
    }
}

/// 相対セレクタの向き(`通知:rightSwitch`)。**基準要素から見た**対象の位置を限定する。
/// 判定規則は StepExecutor.directionalCandidates に1箇所だけ置く(記法↔意味の対応表は docs/design.md §10)
public enum FlowDirection: String, Codable, Equatable, Sendable {
    case right, left, above, below
}

/// 型エイリアス。**複数の実型をまとめて指す名前だけ**を置く(button/switch のように
/// 実型が1つで足りるものは増やさない = 語彙を増やすと生成側の誤用が増えるため)。
/// 実型の綴りは ElementInfo.normalizedType(先頭小文字)と揃える。
public enum FlowTypeAlias {
    /// OS を跨いで保証される役割型(E2EApp/docs/ui-contract.md の契約)。`.widget` と
    /// 相対セレクタの既定フィルタがこれを使う(役割不明の `clickable` 容器は**入れない**)
    public static let widget = ["button", "staticText", "textField", "secureTextField", "switch"]
    private static let table: [String: [String]] = [
        "input": ["textField", "secureTextField"],
        "widget": widget,
    ]

    /// 型名を実型の集合へ。エイリアスでなければ自分自身1件
    public static func expand(_ type: String) -> [String] {
        table[type] ?? [type]
    }
}

public enum FlowLocatorBuilder {
    /// スナップショット中の要素から、優先ロケータ+フォールバック連鎖を導出する。
    /// 優先度: accessibility id > label > type+index
    /// 同期対象: vscode-ftester/src/liveModel.ts locatorChainForElement。
    /// id があるときは位置依存の type+index フォールバックは足さない(id は安定なので `.TextField` 等は
    /// 冗長・ノイズ。生成コードの `#id||.Type` を `#id` にする)。
    public static func chain(for element: ElementInfo, in elements: [ElementInfo])
        -> (primary: FlowLocator, fallbacks: [FlowLocator]) {
        var locators: [FlowLocator] = []
        var hasId = false
        if let id = element.identifier {
            locators.append(FlowLocator(id: id))
            hasId = true
        }
        if let label = element.label {
            locators.append(FlowLocator(label: label))
        }
        if !hasId {
            let sameType = elements.filter { $0.type == element.type }
            if let index = sameType.firstIndex(where: { $0.ref == element.ref }) {
                locators.append(FlowLocator(type: element.type, index: index))
            }
        }
        if locators.isEmpty {
            // 最後の砦: 座標も何もない場合は type だけでも残す
            locators.append(FlowLocator(type: element.type, index: 0))
        }
        return (locators[0], Array(locators.dropFirst()))
    }
}

public extension FlowStep {
    /// ステップの人間可読な1行表現(ヒールプロンプト・コード生成のフォールバック表示用)
    var summary: String {
        if let action {
            switch action {
            case "type":
                return locator == nil
                    ? "type \"\(text ?? "")\""
                    : "type \(locatorSummary) \"\(text ?? "")\""
            case "swipe": return "swipe \(direction ?? "up")"
            case "scrollTo": return "scrollTo \(locatorSummary)"
            default: return "\(action) \(locatorSummary)"
            }
        }
        if let assert {
            if assert == "screenMatches" { return "assert screenMatches \"\(expected ?? "")\"" }
            if assert == "valueEquals" { return "assert valueEquals \(locatorSummary) == \"\(expected ?? "")\"" }
            if assert == "count" { return "assert count \(locatorSummary) == \(expectedCount ?? 0)" }
            return "assert \(assert) \(locatorSummary)"
        }
        return "(空ステップ)"
    }

    /// 失敗メッセージ・ヒールプロンプト用のロケータ表示。**節は `||` で連ねる**(セレクタ式と同じ形)。
    /// 以前は他の節を「fallback」と呼んでいたが、`||` は**候補集合の和**なので
    /// 「片方だけ使われる」という誤った期待を与える(2026-07-27 に用語ごと直した)
    var locatorSummary: String {
        var parts: [String] = []
        if let locator { parts.append(locator.summary) }
        parts.append(contentsOf: (fallbacks ?? []).map(\.summary))
        return parts.isEmpty ? "(ロケータなし)" : parts.joined(separator: " || ")
    }
}
