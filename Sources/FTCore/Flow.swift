// Flow.swift
// テストフロー DSL。FM が探索時に生成し、M3 の再生器が LLM なしで決定的に実行する。
// YAML で保存し、人間がレビュー・編集できることを重視する。

import Foundation
import Yams

public struct Flow: Codable {
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
/// YAML の読みやすさを優先して enum ではなくフラットな構造にしている。
public struct FlowStep: Codable {
    /// tap / type / swipe / press / scrollTo(要素が見つかるまでスクロール)
    public var action: String?
    /// exists / valueEquals / screenMatches
    public var assert: String?
    public var locator: FlowLocator?
    /// ロケータ解決の代替チェーン(id > label > type+index)
    public var fallbacks: [FlowLocator]?
    public var text: String?
    public var direction: String?
    /// screenMatches 用の期待状態(自然言語、M3 でマルチモーダル検証)
    public var expected: String?
    /// 秒。YAML の読みやすさのため整数(Yams は Double を指数表記にする)
    public var timeout: Int?
    /// scrollTo のスクロール回数上限(省略時 8)
    public var maxSwipes: Int?
    /// 探索時に FM が述べた意図(リプレイでは使わないがレビューの助けになる)
    public var note: String?

    public init(action: String? = nil, assert: String? = nil, locator: FlowLocator? = nil,
                fallbacks: [FlowLocator]? = nil, text: String? = nil, direction: String? = nil,
                expected: String? = nil, timeout: Int? = nil, maxSwipes: Int? = nil,
                note: String? = nil) {
        self.action = action
        self.assert = assert
        self.locator = locator
        self.fallbacks = fallbacks
        self.text = text
        self.direction = direction
        self.expected = expected
        self.timeout = timeout
        self.maxSwipes = maxSwipes
        self.note = note
    }
}

public struct FlowLocator: Codable, Equatable {
    public var id: String?
    public var label: String?
    public var type: String?
    public var index: Int?

    public init(id: String? = nil, label: String? = nil, type: String? = nil, index: Int? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.index = index
    }

    public var summary: String {
        if let id { return "id=\(id)" }
        if let label { return "label=\(label)" }
        if let type { return "\(type)[\(index ?? 0)]" }
        return "(空)"
    }
}

public enum FlowLocatorBuilder {
    /// スナップショット中の要素から、優先ロケータ+フォールバック連鎖を導出する。
    /// 優先度: accessibility id > label > type+index
    public static func chain(for element: ElementInfo, in elements: [ElementInfo])
        -> (primary: FlowLocator, fallbacks: [FlowLocator]) {
        var locators: [FlowLocator] = []
        if let id = element.identifier {
            locators.append(FlowLocator(id: id))
        }
        if let label = element.label {
            locators.append(FlowLocator(label: label))
        }
        let sameType = elements.filter { $0.type == element.type }
        if let index = sameType.firstIndex(where: { $0.ref == element.ref }) {
            locators.append(FlowLocator(type: element.type, index: index))
        }
        if locators.isEmpty {
            // 最後の砦: 座標も何もない場合は type だけでも残す
            locators.append(FlowLocator(type: element.type, index: 0))
        }
        return (locators[0], Array(locators.dropFirst()))
    }
}

public enum FlowIO {
    public static func save(_ flow: Flow, to url: URL) throws {
        let encoder = YAMLEncoder()
        encoder.options.allowUnicode = true
        encoder.options.sortKeys = false
        let yaml = try encoder.encode(flow)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func load(from url: URL) throws -> Flow {
        let yaml = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode(Flow.self, from: yaml)
    }

    /// ゴール文字列からファイル名を作る(日本語可、記号は _ に)
    public static func suggestedFileName(for flow: Flow) -> String {
        let base = flow.name.isEmpty ? "flow" : flow.name
        var sanitized = ""
        for scalar in base.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) ||
               scalar.properties.isIdeographic ||
               (0x3040...0x30FF).contains(Int(scalar.value)) {  // ひらがな・カタカナ
                sanitized.unicodeScalars.append(scalar)
            } else {
                sanitized.append("_")
            }
        }
        while sanitized.contains("__") { sanitized = sanitized.replacingOccurrences(of: "__", with: "_") }
        let trimmed = String(sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(40))
        return (trimmed.isEmpty ? "flow" : trimmed) + ".yaml"
    }
}
