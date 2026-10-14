// compose.yaml を型と順序を自前で決めた木にしたもの(Yams の Node は ComposeReader の外へ出さない)。

public enum ComposeValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case list([ComposeValue])
    /// 記述順を保つ。キーは String だけ(ComposeReader が文字列以外を断る)。
    case map([ComposeMapEntry])
}

public struct ComposeMapEntry: Sendable, Equatable {
    public let key: String
    public let value: ComposeValue

    public init(key: String, value: ComposeValue) {
        self.key = key
        self.value = value
    }
}

/// 拒否の位置。`services.db.ports[0]` の形。根は空文字列。
public struct ComposePath: Sendable, Equatable, CustomStringConvertible {
    public let text: String

    public init(_ text: String = "") {
        self.text = text
    }

    public var description: String { text.isEmpty ? "<root>" : text }

    public func append(key: String) -> ComposePath {
        ComposePath(text.isEmpty ? key : text + "." + key)
    }

    public func append(index: Int) -> ComposePath {
        ComposePath(text + "[\(index)]")
    }
}

extension ComposeValue {
    var mapEntries: [ComposeMapEntry]? {
        if case .map(let entries) = self { return entries }
        return nil
    }

    var listItems: [ComposeValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// 文字列・数・真偽を compose と同じく文字列として読む(null と木は nil)。
    var scalarText: String? {
        switch self {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null, .list, .map: return nil
        }
    }

    var kindName: String {
        switch self {
        case .string: return "string"
        case .int: return "integer"
        case .double: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        case .list: return "list"
        case .map: return "mapping"
        }
    }
}
