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
    /// swipeElementToElement の終点。ヒール・フォールバック連鎖の対象は始点(locator)のみ
    public var endLocator: FlowLocator?
    public var text: String?
    public var direction: String?
    /// screenMatches 用の期待状態(自然言語。マルチモーダル画面検証に使う)
    public var expected: String?
    /// 秒(小数可)。検証(assert)では要素出現待ちの上限。アクションではロケータ解決の
    /// 再試行待ち上限(nil = 既定の約0.7秒 / 0 = 再試行なし。出るか不定の要素を待つ空振りの短縮用)
    public var timeout: Double?
    /// scrollTo のスクロール回数上限(省略時 8)
    public var maxSwipes: Int?
    /// tap の長押し秒数(nil / 0 = 通常タップ)。既定と同じなら nil のまま置く
    /// (生成コード・JSON を既定ケースで太らせないため)。swipeElementToElement では移動時間(秒)
    public var duration: Double?
    /// count アサーションの期待個数(DSL の countIs)。他のステップでは nil
    public var expectedCount: Int?
    /// テキスト比較を**厳密に**行う(一切正規化しない)。DSL の `strict: true`(2026-08-09)。
    /// 既定(nil / false)は「見た目が完全に一致していれば同じ」= 不可視文字を無視し、
    /// 半角と全角は別物として扱う。**追加 optional のみ**なので旧レコードも decode できる
    public var strictText: Bool?
    /// 探索時に FM が述べた意図(リプレイでは使わないがレビューの助けになる)
    public var note: String?
    /// [occlusion-guard] true のとき、この検証(exists/textEquals)がツリー一致で pass した直後に
    /// FM でスクショ視覚照合し、覆われ/切れ/不在なら偽陽性として失敗へ反転する。DSL の visible() が立てる。
    /// nil = executor 既定(StepExecutor.occlusionGuard)に従う。
    public var occlusionGuard: Bool?
    /// **容器の推測に依存する補正**をこのステップで行うか(見切れ判定・掴み直し・救済ドラッグ・
    /// 見えている部分を撃つ座標補正・壊れた座標の候補除外)。nil = 実行プロファイルの既定に従う。
    /// 想定外のツリーで補正が裏目に出る画面だけ、利用者が1コマンド単位で切れるようにするためのもの
    public var containerInference: Bool?

    /// `tap(holdSeconds:)` の既定。**0 = 通常タップ**(Shirates の `tapHoldSeconds` 準拠)。
    /// 0 より大きいときだけ長押しとしてブリッジの /press へ回す(StepExecutor)
    public static let defaultTapHoldSeconds: Double = 0

    /// スクロール探索(`scrollTo` / `tap(scroll:)` / `exist(scroll:)`)の既定スワイプ上限。
    /// DSL の既定引数はこの1つに揃える
    public static let defaultMaxSwipes = 8
    /// 端まで送る(scrollToBottom 等)の上限。**終了条件は「画面が変わらなくなること」**で、
    /// これは暴走を止める安全網にすぎないので探索(8)より大きく取る
    public static let defaultMaxEdgeSwipes = 50

    /// swipePointToPoint / swipeElementToElement の既定の移動時間(秒)。
    /// shirates-core の Const.SWIPE_DURATION_SECONDS 準拠。DSL の既定引数はこの1つに揃える
    public static let defaultSwipeDurationSeconds: Double = 1.5

    /// flickXxx の既定の移動時間(秒)。shirates-core の Const.FLICK_DURATION_SECONDS 準拠。
    /// swipe と低レベル実装は同じ(等速 pointerMove 1本)で、既定値だけ短い
    public static let defaultFlickDurationSeconds: Double = 0.25
    /// flickXxx の repeat 間隔(秒)。shirates-core の Const.FLICK_INTERVAL_SECONDS 準拠。
    /// repeat > 1 のとき、次のストロークの前に必ずこの秒数だけ待つ(Shirates の
    /// swipePointToPointCore と同じ: 1回目も含め毎周の前に待つ)
    public static let defaultFlickIntervalSeconds: Double = 0.3

    /// pinchOut / pinchIn の既定拡大率。**Shirates に対応するコマンドが無い**ので準拠先は無く、
    /// 「1回で目に見えて変わるが行き過ぎない」値として選んだ(倍率と 1/2)
    public static let defaultPinchOutScale: Double = 2.0
    public static let defaultPinchInScale: Double = 0.5
    /// pinch の既定所要時間(秒)。Android はストローク時間、iOS は velocity(scale/秒)の分母になる
    public static let defaultPinchDurationSeconds: Double = 0.5

    /// waitForDisplay/waitForClose の既定待ち秒数(スクロールしない出現/消滅待ち)。
    /// Shirates の WAIT_SECONDS_ON_ISSCREEN 準拠
    public static let defaultIsScreenWaitSeconds: Double = 15.0

    /// スクロール対象の領域(Shirates の `scrollFrame`)。**nil = 従来の全画面固定**。
    /// 非 nil のときだけホストが座標を計算してブリッジへ渡す(`ScrollGeometry`)。
    /// **解決できなかったときも従来経路へ落とす**(Shirates も見つからなければ次の候補へ落ちる)
    public var scrollFrame: FlowLocator?
    /// スクロール対象の領域を矩形で直接指定する(MCP 専用。DSL は使わない)。非 nil なら
    /// `scrollFrame`(セレクタ)より優先し、**常に解決済み扱い**(`scrollFrameUnresolved` の
    /// fail-fast は掛からない)。**なぜ rect か**: id が重複・欠落した容器は一意なセレクタで
    /// 指せないため、`MCPServer` が撮り直した木からその場で ref → frame を引いて渡す
    public var scrollFrameRect: FTRect?
    /// 指を置く側 / 離す側の余白比(領域の高さ・幅に対する比)。nil = `FTScrollDefaults` の用途別既定。
    /// **`scrollFrame` が nil のときは無視される**(全画面固定のままスパンを広げると始点が
    /// スクロール領域の外に出て 1 ミリも動かない。docs/performance-tuning.md §3.16)
    public var startMarginRatio: Double?
    public var endMarginRatio: Double?
    /// flick の repeat 間隔(秒)。**flick 以外は未使用**。nil = `FlowStep.defaultFlickIntervalSeconds`
    public var intervalSeconds: Double?
    /// pinch の拡大率(> 1 = 拡大 / 0 < scale < 1 = 縮小)。**pinch 以外は未使用**
    public var scale: Double?
    /// swipeBy の移動量(対象領域の幅・高さに対する比。符号は指の向き)。**swipeBy 以外は未使用**
    public var dxRatio: Double?
    public var dyRatio: Double?

    public init(action: String? = nil, assert: String? = nil, locator: FlowLocator? = nil,
                fallbacks: [FlowLocator]? = nil, endLocator: FlowLocator? = nil,
                text: String? = nil, direction: String? = nil,
                expected: String? = nil, timeout: Double? = nil, maxSwipes: Int? = nil,
                duration: Double? = nil,
                expectedCount: Int? = nil,
                note: String? = nil, occlusionGuard: Bool? = nil,
                containerInference: Bool? = nil,
                scrollFrame: FlowLocator? = nil,
                scrollFrameRect: FTRect? = nil,
                startMarginRatio: Double? = nil, endMarginRatio: Double? = nil,
                intervalSeconds: Double? = nil,
                scale: Double? = nil, dxRatio: Double? = nil, dyRatio: Double? = nil) {
        self.scale = scale
        self.dxRatio = dxRatio
        self.dyRatio = dyRatio
        self.scrollFrame = scrollFrame
        self.scrollFrameRect = scrollFrameRect
        self.startMarginRatio = startMarginRatio
        self.endMarginRatio = endMarginRatio
        self.intervalSeconds = intervalSeconds
        self.action = action
        self.assert = assert
        self.locator = locator
        self.fallbacks = fallbacks
        self.endLocator = endLocator
        self.text = text
        self.direction = direction
        self.expected = expected
        self.timeout = timeout
        self.maxSwipes = maxSwipes
        self.duration = duration
        self.expectedCount = expectedCount
        self.note = note
        self.occlusionGuard = occlusionGuard
        self.containerInference = containerInference
    }
}

/// 文字列属性(label / value / placeholder)の一致方法。**既定は exact**(素のラベルは完全一致)で、
/// 部分一致は記法で明示したときだけ(`*x*` / `x*` / `*x` / `textMatches=`)。
/// matches は**部分一致の正規表現**(全体一致は `^...$`)で、
/// textMatches アサーション(StepExecutor.matchedText)と同じ規約。
public enum FlowMatchMode: String, Codable, Equatable, Sendable {
    case exact, startsWith, contains, endsWith, matches

    /// 実属性値がこの一致方法で expected を満たすか。nil の属性は常に不一致。
    ///
    /// 正規化は `TextNormalization`。**既定は `.selector`**(この関数はセレクタのフィルタから
    /// 呼ばれる = 「見つける」側なので寛容に寄せる)。テキストと期待値の比較は `.text` を渡す ——
    /// あちらは「見た目が完全に一致していれば同じ」が基準で、規則が違う。
    /// expected は `.matches`(正規表現)のときだけ素通し(パターンを書き換えないため)
    public func matches(_ actual: String?, _ expected: String,
                        normalization: TextNormalization = .selector) -> Bool {
        guard let actual else { return false }
        let normalizedActual = normalization.apply(actual)
        let normalizedExpected = self == .matches ? expected : normalization.apply(expected)
        switch self {
        case .exact: return normalizedActual == normalizedExpected
        case .startsWith: return normalizedActual.hasPrefix(normalizedExpected)
        case .contains: return normalizedActual.contains(normalizedExpected)
        case .endsWith: return normalizedActual.hasSuffix(normalizedExpected)
        case .matches: return normalizedActual.range(of: normalizedExpected, options: .regularExpression) != nil
        }
    }

    /// U+200B/U+200C/U+200D/U+FEFF/U+2060。Google マップ等の実データが混入させる不可視文字で、
    /// 除去しないと目視では同一に見える文字列が完全一致に失敗する(SnapshotRenderer.renderElement も
    /// `normalizeInvisibleCharacters` を通し、コピーした文字列が必ず一致する状態を保つ)
    public static let zeroWidthScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}",
    ]

    /// **幅を持つ不可視空白**。ゼロ幅と違って**桁を食う**ので、除去すると `"A B"` が `"AB"` に
    /// なって別の一致崩れを作る —— こちらは**通常空白(U+0020)へ正規化**する。
    ///
    /// 集合は実データで確認したものだけ(2026-08-09。Google マップ Android の路線ラベルが
    /// `"\u{00A0} 埼京線"`)。**推測で足さない** —— 足すなら ft_snapshot で採った生ラベルの
    /// スカラ列挙を根拠にすること。
    /// **U+3000(全角スペース)は入れない**: 日本語ラベルでは有意な文字で、正規化すると
    /// 別物を一致させる
    public static let spaceLikeScalars: Set<Unicode.Scalar> = ["\u{00A0}"]

    /// **描画のための正規化**(SnapshotRenderer が印字前に通す)。規則はテキスト比較側と同じ
    /// `.text` —— 印字は「読み手が画面で見ているもの」を写すためのもので、
    /// 見えない文字だけを落とし、見える差(全角と半角)は残すのが正しい。
    /// 実体は `TextNormalization` に1つだけ置く(片方だけ変えられないように)
    public static func normalizeInvisibleCharacters(_ s: String) -> String {
        TextNormalization.text.apply(s)
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
        return parts.isEmpty ? "(empty)" : parts.joined(separator: "&&")
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
    /// OS を跨いで保証される役割型(E2EAppCMP/docs/ui-contract.md の契約)。`.widget` と
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
            case "rotateTo": return "rotateTo \(direction ?? "landscape")"
            case "scrollTo": return "scrollTo \(locatorSummary)"
            // 対象なし(画面全体)を取り得るアクションは locatorSummary の "(no locator)" を出さない
            case "pinchOut", "pinchIn", "doubleTap", "swipeBy":
                return locator == nil ? action : "\(action) \(locatorSummary)"
            default: return "\(action) \(locatorSummary)"
            }
        }
        if let assert {
            if assert == "screenMatches" { return "assert screenMatches \"\(expected ?? "")\"" }
            if assert == "valueEquals" { return "assert valueEquals \(locatorSummary) == \"\(expected ?? "")\"" }
            if assert == "count" { return "assert count \(locatorSummary) == \(expectedCount ?? 0)" }
            return "assert \(assert) \(locatorSummary)"
        }
        return "(empty step)"
    }

    /// 失敗メッセージ・ヒールプロンプト用のロケータ表示。**節は `||` で連ねる**(セレクタ式と同じ形)。
    /// 以前は他の節を「fallback」と呼んでいたが、`||` は**候補集合の和**なので
    /// 「片方だけ使われる」という誤った期待を与える(2026-07-27 に用語ごと直した)
    var locatorSummary: String {
        var parts: [String] = []
        if let locator { parts.append(locator.summary) }
        parts.append(contentsOf: (fallbacks ?? []).map(\.summary))
        return parts.isEmpty ? "(no locator)" : parts.joined(separator: " || ")
    }
}
