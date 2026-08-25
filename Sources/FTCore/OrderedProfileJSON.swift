// プロファイル JSON の書き出し。**キー順を意味のある順に固定する**(ユーザー指示)。
// JSONSerialization の .sortedKeys はアルファベット順なので、Android のデバイスが
// `{"avd": …, "machine": …, "name": …}` のように「どの機械の何か」より先に実体が来る。
// 読み手(人と Claude Code)にとっては machine → name が先に来るほうが早く読める。
//
// 実装の規律: **値の直列化は JSONSerialization に任せる**(エスケープを自前で書かない)。
// ここが決めるのはキーの順序と字下げだけ。未知キーは温存し、優先リストに無いものは
// アルファベット順で後ろに並べる(差分が安定する = .sortedKeys と同じ性質を保つ)。

import Foundation

public enum OrderedProfileJSON {
    /// 先頭に出すキー。**この順序自体が契約**(profiles/*.json を読む人の期待)。
    /// 先頭2つの理由: machine = どの機械の話か(ローカルエイリアス)、
    /// name = 実行プロファイルからの参照キー。ここに無いキーはアルファベット順で後ろに付く
    public static let preferredKeyOrder = [
        "machine", "name", "host", "app", "appName",
        // セクションはアルファベット順(android → ios)ではなく、読み手の期待どおり ios → android
        "common", "ios", "android", "devices", "kind", "platform",
    ]

    /// 人が読む前提のファイル向けの整形(末尾改行あり)。JSONSerialization の
    /// .prettyPrinted と同じ2スペース字下げ
    public static func data(_ object: Any) throws -> Data {
        var text = try render(object, indent: 0)
        text.append("\n")
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "OrderedProfileJSON", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot encode profile as UTF-8"])
        }
        return data
    }

    private static func render(_ value: Any, indent: Int) throws -> String {
        let pad = String(repeating: " ", count: indent)
        let padInner = String(repeating: " ", count: indent + 2)

        if let dictionary = value as? [String: Any] {
            guard !dictionary.isEmpty else { return "{}" }
            let keys = order(Array(dictionary.keys))
            let lines = try keys.map { key -> String in
                let rendered = try render(dictionary[key] as Any, indent: indent + 2)
                return "\(padInner)\(try scalar(key)): \(rendered)"
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(pad)}"
        }
        if let array = value as? [Any] {
            guard !array.isEmpty else { return "[]" }
            let lines = try array.map { "\(padInner)\(try render($0, indent: indent + 2))" }
            return "[\n" + lines.joined(separator: ",\n") + "\n\(pad)]"
        }
        return try scalar(value)
    }

    /// 単一の値(文字列・数値・真偽値・null)。**エスケープは JSONSerialization に任せる**
    private static func scalar(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func order(_ keys: [String]) -> [String] {
        let preferred = preferredKeyOrder.filter { keys.contains($0) }
        let rest = keys.filter { !preferredKeyOrder.contains($0) }.sorted()
        return preferred + rest
    }
}
