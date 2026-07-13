// Flow.swift
// ステップのインメモリ内部モデル。FM 探索(Explorer)の出力・コード生成(ScenarioCodeGen)の入力・
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
    /// exists / valueEquals / screenMatches
    public var assert: String?
    public var locator: FlowLocator?
    /// ロケータ解決の代替チェーン(id > label > type+index)
    public var fallbacks: [FlowLocator]?
    public var text: String?
    public var direction: String?
    /// screenMatches 用の期待状態(自然言語。マルチモーダル画面検証に使う)
    public var expected: String?
    /// 秒(整数)
    public var timeout: Int?
    /// scrollTo のスクロール回数上限(省略時 8)
    public var maxSwipes: Int?
    /// true のとき、ロケータが解決できなくても失敗にせずスキップする
    /// (パスワード保存シート等、出るかどうか不定なシステムダイアログの処理用)
    public var optional: Bool?
    /// 探索時に FM が述べた意図(リプレイでは使わないがレビューの助けになる)
    public var note: String?

    public init(action: String? = nil, assert: String? = nil, locator: FlowLocator? = nil,
                fallbacks: [FlowLocator]? = nil, text: String? = nil, direction: String? = nil,
                expected: String? = nil, timeout: Int? = nil, maxSwipes: Int? = nil,
                optional: Bool? = nil, note: String? = nil) {
        self.action = action
        self.assert = assert
        self.locator = locator
        self.fallbacks = fallbacks
        self.text = text
        self.direction = direction
        self.expected = expected
        self.timeout = timeout
        self.maxSwipes = maxSwipes
        self.optional = optional
        self.note = note
    }
}

public struct FlowLocator: Codable, Equatable, Sendable {
    public var id: String?
    public var label: String?
    public var type: String?
    public var index: Int?
    /// ScenarioEvent(サブプロセス発の NDJSON)から復元する際の生テキスト。
    /// サブプロセス境界を跨ぐと構造化ロケータ(id/label/type/index)は失われ人間可読テキストしか
    /// 残らないため、その場合はこのフィールドのみ設定し summary でそのまま返す
    /// (RunOrchestrator.ScenarioRunner.stepResult(from:) 参照)。プロセス内解決時は nil のまま
    public var raw: String?

    public init(id: String? = nil, label: String? = nil, type: String? = nil, index: Int? = nil,
                raw: String? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.index = index
        self.raw = raw
    }

    public var summary: String {
        if let raw { return raw }
        if let id { return "id=\(id)" }
        if let label { return "label=\(label)" }
        // 表示は 1 オリジン、1番目は [1] を省略(セレクタ式の表記と揃える。内部 index は 0 オリジン)
        if let type {
            let ordinal = (index ?? 0) + 1
            return ordinal > 1 ? "\(type)[\(ordinal)]" : type
        }
        return "(空)"
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
            return "assert \(assert) \(locatorSummary)"
        }
        return "(空ステップ)"
    }

    var locatorSummary: String {
        var parts: [String] = []
        if let locator { parts.append(locator.summary) }
        if let fallbacks, !fallbacks.isEmpty {
            parts.append("(fallback: \(fallbacks.map(\.summary).joined(separator: " → ")))")
        }
        return parts.isEmpty ? "(ロケータなし)" : parts.joined(separator: " ")
    }
}
