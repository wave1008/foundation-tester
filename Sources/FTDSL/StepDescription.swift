// DSL コマンド → 自然言語(日本語)の説明文生成。
// ヒール確認 UI の説明提案・ステップ一覧「説明」列の補完・コード生成の行末コメントが使う。
// 操作は「〜する」、検証は「〜こと」。目的語はセレクタ式のラベル成分
// (最初の label 節)を優先し、無ければセレクタ文字列をそのまま使う。
// 生成できないコマンド(ifCanSelect / procedure / 未知)は nil を返し、呼び出し側でフォールバックする。

import Foundation
import FTCore

public enum StepDescription {

    /// コマンド description 文字列(例: tap "#a||ラベル")から生成する。
    /// selectorOverride 指定時はセレクタ引数を差し替えて目的語を組み立てる
    /// (ヒール確認シートが新セレクタで説明を提案するため)。生成できなければ nil
    public static func describe(command: String, selectorOverride: String? = nil) -> String? {
        // ` (optional)` サフィックス(tap の任意実行)は説明に影響しない
        var text = command.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(" (optional)") {
            text = String(text.dropLast(" (optional)".count))
        }

        guard let spaceIndex = text.firstIndex(of: " ") else {
            // 引数なしコマンド
            return text == "terminate" ? "アプリを終了する" : nil
        }
        let verb = String(text[..<spaceIndex])
        let rest = String(text[text.index(after: spaceIndex)...])

        switch verb {
        case "tap":
            guard let selector = unquote(rest) else { return nil }
            return "\"\(objectPhrase(ofSelector: selectorOverride ?? selector))\"をタップする"
        case "press":
            guard let selector = unquote(rest) else { return nil }
            return "\"\(objectPhrase(ofSelector: selectorOverride ?? selector))\"を長押しする"
        case "scrollTo":
            guard let selector = unquote(rest) else { return nil }
            return "\"\(objectPhrase(ofSelector: selectorOverride ?? selector))\""
                + "が表示されるまでスクロールする"
        case "exist":
            guard let selector = unquote(rest) else { return nil }
            return "\"\(objectPhrase(ofSelector: selectorOverride ?? selector))\"が表示されること"
        case "type":
            if let (selector, input) = unquotePair(rest, separator: "\" \"") {
                return "\"\(objectPhrase(ofSelector: selectorOverride ?? selector))\""
                    + "に\"\(input)\"を入力する"
            }
            guard let input = unquote(rest) else { return nil }
            return "フォーカス中の要素に\"\(input)\"を入力する"
        case "textIs":
            guard let (selector, expected) = unquotePair(rest, separator: "\" == \"") else {
                return nil
            }
            return "\"\(objectPhrase(ofSelector: selectorOverride ?? selector))\""
                + "のテキストが\"\(expected)\"であること"
        case "valueIs":
            guard let (selector, expected) = unquotePair(rest, separator: "\" == \"") else {
                return nil
            }
            return "\"\(objectPhrase(ofSelector: selectorOverride ?? selector))\""
                + "の値が\"\(expected)\"であること"
        case "screenIs":
            guard let expected = unquote(rest) else { return nil }
            return "画面が\"\(expected)\"であること"
        case "launch":
            return rest.isEmpty ? nil : "\(rest)アプリを起動する"
        case "relaunch":
            return rest.isEmpty ? nil : "\(rest)アプリを再起動する"
        case "swipe":
            return swipePhrase(direction: rest)
        case "wait":
            guard rest.hasSuffix("s"), let seconds = Double(rest.dropLast()) else { return nil }
            return "\(formatSeconds(seconds))秒待機する"
        default:
            return nil  // ifCanSelect / procedure(タイトルが既に自然言語) / 未知コマンドは対象外
        }
    }

    /// FlowStep から生成する(コード生成用)。生成できなければ nil
    public static func describe(step: FlowStep) -> String? {
        if let action = step.action {
            switch action {
            case "tap":
                return "\"\(objectPhrase(ofStep: step))\"をタップする"
            case "press":
                return "\"\(objectPhrase(ofStep: step))\"を長押しする"
            case "scrollTo":
                return "\"\(objectPhrase(ofStep: step))\"が表示されるまでスクロールする"
            case "type":
                if step.locator == nil {
                    return "フォーカス中の要素に\"\(step.text ?? "")\"を入力する"
                }
                return "\"\(objectPhrase(ofStep: step))\"に\"\(step.text ?? "")\"を入力する"
            case "swipe":
                return swipePhrase(direction: step.direction ?? "up")
            default:
                return nil
            }
        }
        if let assert = step.assert {
            switch assert {
            case "exists":
                return "\"\(objectPhrase(ofStep: step))\"が表示されること"
            case "textEquals":
                return "\"\(objectPhrase(ofStep: step))\"のテキストが\"\(step.expected ?? "")\"であること"
            case "valueEquals":
                return "\"\(objectPhrase(ofStep: step))\"の値が\"\(step.expected ?? "")\"であること"
            case "screenMatches":
                return "画面が\"\(step.expected ?? "")\"であること"
            default:
                return nil
            }
        }
        return nil
    }

    /// セレクタ式の目的語(テスト対象): 最初のラベル節のラベル、無ければセレクタ文字列そのまま
    static func objectPhrase(ofSelector selector: String) -> String {
        let parsed = FTSelector.parse(selector)
        return ([parsed.primary] + parsed.fallbacks).compactMap(\.label).first ?? selector
    }

    private static func objectPhrase(ofStep step: FlowStep) -> String {
        let locators = [step.locator].compactMap { $0 } + (step.fallbacks ?? [])
        if let label = locators.compactMap(\.label).first { return label }
        guard let primary = step.locator else { return "" }
        return FTSelector.serialize(primary: primary, fallbacks: step.fallbacks ?? [])
    }

    private static func swipePhrase(direction: String) -> String? {
        switch direction {
        case "up": return "上にスワイプする"
        case "down": return "下にスワイプする"
        case "left": return "左にスワイプする"
        case "right": return "右にスワイプする"
        default: return nil
        }
    }

    /// `"S"` → S(クォート囲みでなければ nil)
    private static func unquote(_ text: String) -> String? {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        return String(text.dropFirst().dropLast())
    }

    /// `"A"<separator の内側>"B"` → (A, B)。書式が合わなければ nil
    /// (separator は `"` を含む生の区切り。例: `"\" \""` / `"\" == \""`)
    private static func unquotePair(_ text: String, separator: String) -> (String, String)? {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        let inner = text.dropFirst().dropLast()
        guard let range = inner.range(of: separator) else { return nil }
        return (String(inner[..<range.lowerBound]), String(inner[range.upperBound...]))
    }

    /// 1.0 → "1"、0.5 → "0.5"(wait の表示用)
    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds == seconds.rounded(), abs(seconds) < 1e15 {
            return String(Int(seconds))
        }
        return String(seconds)
    }
}
