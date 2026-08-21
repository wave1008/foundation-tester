// DSL コマンド → 自然言語の説明文生成。
// ヒール確認 UI の説明提案・ステップ一覧「説明」列の補完・コード生成の行末コメントが使う。
// **文の言語はステップの内容に追従する**(2026-07-30 ユーザー決定): ラベル・期待値・入力値の
// どれかに日本語が含まれれば日本語文(操作は「〜する」、検証は「〜こと」)、含まれなければ
// 英語文。内容を持たないコマンド(terminate/swipe/wait 等)は英語 = 定型文の既定。
// 目的語はセレクタ式のラベル成分(最初の label 節)を優先し、無ければセレクタ文字列をそのまま使う。
// 生成できないコマンド(ifCanSelect / procedure / 未知)は nil を返し、呼び出し側でフォールバックする。

import Foundation
import FTCore

public enum StepDescription {

    /// コマンド description 文字列(例: tap "#a||ラベル")から生成する。
    /// selectorOverride 指定時はセレクタ引数を差し替えて目的語を組み立てる
    /// (ヒール確認シートが新セレクタで説明を提案するため)。生成できなければ nil
    public static func describe(command: String, selectorOverride: String? = nil) -> String? {
        // ` (optional)` は廃止済みの `optional:` 引数が付けていたサフィックス。**過去 run の
        // 説明文を読み直すため**に剥がしは残す(新しい run では二度と現れない)
        var text = command.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(" (optional)") {
            text = String(text.dropLast(" (optional)".count))
        }

        guard let spaceIndex = text.firstIndex(of: " ") else {
            // 引数なしコマンド(内容が無いので常に英語)
            switch text {
            case "terminate": return "terminate the app"
            case "pressEnter": return "press the Enter key"
            case "back": return "go back"
            case "clearInput": return "clear the focused input"
            case "hideKeyboard": return "hide the keyboard"
            case "keyboardIsShown": return "the keyboard is shown"
            case "keyboardIsNotShown": return "the keyboard is not shown"
            default: return nil
            }
        }
        let verb = String(text[..<spaceIndex])
        let rest = String(text[text.index(after: spaceIndex)...])

        func object(_ selector: String) -> String {
            objectPhrase(ofSelector: selectorOverride ?? selector)
        }

        switch verb {
        case "tap":
            // holdSeconds ありは description に `(hold Xs)` が付く(tapImpl 参照)。長押しの文言に化ける
            if let (selector, holdTail) = unquotedTail(rest, separator: "\" (hold "),
               holdTail.hasSuffix("s)") {
                let obj = object(selector)
                let seconds = String(holdTail.dropLast(2))
                return isJapanese(obj)
                    ? "\"\(obj)\"を\(seconds)秒間長押しする"
                    : "long-press \"\(obj)\" for \(seconds)s"
            }
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj) ? "\"\(obj)\"をタップする" : "tap \"\(obj)\""
        case "scrollTo":
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj)
                ? "\"\(obj)\"が表示されるまでスクロールする"
                : "scroll until \"\(obj)\" is visible"
        case "exist":
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj)
                ? "\"\(obj)\"が(覆われず)見えていること"
                : "\"\(obj)\" is visible (not covered)"
        case "select":
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj) ? "\"\(obj)\"を選択する" : "select \"\(obj)\""
        case "notExist":
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj) ? "\"\(obj)\"が表示されていないこと" : "\"\(obj)\" is not shown"
        case "enabledIsTrue":
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj) ? "\"\(obj)\"が操作可能であること" : "\"\(obj)\" is enabled"
        case "enabledIsFalse":
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj) ? "\"\(obj)\"が操作不可であること" : "\"\(obj)\" is disabled"
        case "textContains":
            guard let (selector, expected) = unquotePair(rest, separator: "\" ~ \"") else { return nil }
            let obj = object(selector)
            return isJapanese(obj, expected)
                ? "\"\(obj)\"が\"\(expected)\"を含むこと"
                : "\"\(obj)\" contains \"\(expected)\""
        case "textMatches":
            guard let (selector, pattern) = unquotePair(rest, separator: "\" ~ \"") else { return nil }
            let obj = object(selector)
            return isJapanese(obj, pattern)
                ? "\"\(obj)\"が正規表現 \"\(pattern)\" に一致すること"
                : "\"\(obj)\" matches the regex \"\(pattern)\""
        case "checkIsON":
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj) ? "\"\(obj)\"がオンであること" : "\"\(obj)\" is on"
        case "checkIsOFF":
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj) ? "\"\(obj)\"がオフであること" : "\"\(obj)\" is off"
        case "countIs":
            guard let (selector, count) = unquotedTail(rest, separator: "\" == ") else { return nil }
            let obj = object(selector)
            return isJapanese(obj)
                ? "\"\(obj)\"が\(count)件あること"
                : "there are \(count) \"\(obj)\""
        case "type":
            if let (selector, input) = unquotePair(rest, separator: "\" \"") {
                let obj = object(selector)
                return isJapanese(obj, input)
                    ? "\"\(obj)\"に\"\(input)\"を入力する"
                    : "type \"\(input)\" into \"\(obj)\""
            }
            guard let input = unquote(rest) else { return nil }
            return isJapanese(input)
                ? "フォーカス中の要素に\"\(input)\"を入力する"
                : "type \"\(input)\" into the focused element"
        case "clearInput":
            guard let selector = unquote(rest) else { return nil }
            let obj = object(selector)
            return isJapanese(obj) ? "\"\(obj)\"を空にする" : "clear \"\(obj)\""
        case "swipeElementToElement":
            guard let (from, to) = unquotePair(rest, separator: "\" → \"") else { return nil }
            let fromObj = object(from)
            let toObj = objectPhrase(ofSelector: to)
            return isJapanese(fromObj, toObj)
                ? "\"\(fromObj)\"から\"\(toObj)\"へドラッグする"
                : "drag \"\(fromObj)\" to \"\(toObj)\""
        case "textIs":
            guard let (selector, expected) = unquotePair(rest, separator: "\" == \"") else {
                return nil
            }
            let obj = object(selector)
            return isJapanese(obj, expected)
                ? "\"\(obj)\"のテキストが\"\(expected)\"であること"
                : "\"\(obj)\" text is \"\(expected)\""
        case "valueIs":
            guard let (selector, expected) = unquotePair(rest, separator: "\" == \"") else {
                return nil
            }
            let obj = object(selector)
            return isJapanese(obj, expected)
                ? "\"\(obj)\"の値が\"\(expected)\"であること"
                : "\"\(obj)\" value is \"\(expected)\""
        case "screenLooksLike":
            guard let expected = unquote(rest) else { return nil }
            return isJapanese(expected)
                ? "画面が\"\(expected)\"であること"
                : "the screen matches \"\(expected)\""
        case "launch":
            guard !rest.isEmpty else { return nil }
            return isJapanese(rest) ? "\(rest)アプリを起動する" : "launch the \(rest) app"
        case "restart":
            guard !rest.isEmpty else { return nil }
            return isJapanese(rest) ? "\(rest)アプリを再起動する" : "restart the \(rest) app"
        case "clearAppData":
            guard !rest.isEmpty else { return nil }
            return isJapanese(rest) ? "\(rest)のアプリデータを消去する" : "clear app data for \(rest)"
        case "swipe":
            return swipePhrase(direction: rest)
        case "rotateTo":
            return rotateToPhrase(orientation: rest)
        case "wait":
            guard rest.hasSuffix("s"), let seconds = Double(rest.dropLast()) else { return nil }
            return "wait \(formatSeconds(seconds))s"
        default:
            return nil  // ifCanSelect / procedure(タイトルが既に自然言語) / 未知コマンドは対象外
        }
    }

    /// FlowStep から生成する(コード生成用)。生成できなければ nil
    public static func describe(step: FlowStep) -> String? {
        let obj = objectPhrase(ofStep: step)
        if let action = step.action {
            switch action {
            case "select":
                return isJapanese(obj) ? "\"\(obj)\"を選択する" : "select \"\(obj)\""
            case "tap":
                if let holdSeconds = step.duration {
                    return isJapanese(obj)
                        ? "\"\(obj)\"を\(formatSeconds(holdSeconds))秒間長押しする"
                        : "long-press \"\(obj)\" for \(formatSeconds(holdSeconds))s"
                }
                return isJapanese(obj) ? "\"\(obj)\"をタップする" : "tap \"\(obj)\""
            case "scrollTo":
                return isJapanese(obj)
                    ? "\"\(obj)\"が表示されるまでスクロールする"
                    : "scroll until \"\(obj)\" is visible"
            case "type":
                let input = step.text ?? ""
                let replace = step.replace == true
                if step.locator == nil {
                    if isJapanese(input) {
                        return replace ? "フォーカス中の要素を空にしてから\"\(input)\"を入力する"
                            : "フォーカス中の要素に\"\(input)\"を入力する"
                    }
                    return replace ? "clear the focused element, then type \"\(input)\" into it"
                        : "type \"\(input)\" into the focused element"
                }
                if isJapanese(obj, input) {
                    return replace ? "\"\(obj)\"を空にしてから\"\(input)\"を入力する"
                        : "\"\(obj)\"に\"\(input)\"を入力する"
                }
                return replace ? "clear \"\(obj)\", then type \"\(input)\" into it"
                    : "type \"\(input)\" into \"\(obj)\""
            case "swipe":
                return swipePhrase(direction: step.direction ?? "up")
            case "rotateTo":
                return rotateToPhrase(orientation: step.direction ?? "landscape")
            case "pressEnter":
                return "press the Enter key"
            case "hideKeyboard":
                return "hide the keyboard"
            case "clearInput":
                if step.locator == nil { return "clear the focused input" }
                return isJapanese(obj) ? "\"\(obj)\"を空にする" : "clear \"\(obj)\""
            case "doubleTap":
                if step.locator == nil { return "double-tap the center of the screen" }
                return isJapanese(obj) ? "\"\(obj)\"をダブルタップする" : "double-tap \"\(obj)\""
            case "pinchOut", "pinchIn":
                let zoom = action == "pinchOut" ? "zoom in" : "zoom out"
                let zoomJa = action == "pinchOut" ? "拡大" : "縮小"
                if step.locator == nil { return "\(zoom) with a pinch gesture" }
                return isJapanese(obj) ? "\"\(obj)\"をピンチで\(zoomJa)する" : "\(zoom) on \"\(obj)\""
            case "swipeBy":
                if step.locator == nil { return "drag the screen by a relative offset" }
                return isJapanese(obj) ? "\"\(obj)\"を相対量でドラッグする" : "drag \"\(obj)\" by a relative offset"
            case "swipeElementToElement":
                guard let endLocator = step.endLocator else { return nil }
                let toObj = endLocator.label ?? FTSelector.serialize(primary: endLocator, fallbacks: [])
                return isJapanese(obj, toObj)
                    ? "\"\(obj)\"から\"\(toObj)\"へドラッグする"
                    : "drag \"\(obj)\" to \"\(toObj)\""
            default:
                return nil
            }
        }
        if let assert = step.assert {
            switch assert {
            case "exists":
                if step.occlusionGuard == true {
                    return isJapanese(obj)
                        ? "\"\(obj)\"が(覆われず)見えていること"
                        : "\"\(obj)\" is visible (not covered)"
                }
                return isJapanese(obj) ? "\"\(obj)\"が表示されること" : "\"\(obj)\" is shown"
            case "notExists":
                return isJapanese(obj) ? "\"\(obj)\"が表示されていないこと" : "\"\(obj)\" is not shown"
            case "enabled":
                return isJapanese(obj) ? "\"\(obj)\"が操作可能であること" : "\"\(obj)\" is enabled"
            case "disabled":
                return isJapanese(obj) ? "\"\(obj)\"が操作不可であること" : "\"\(obj)\" is disabled"
            case "textContains":
                let expected = step.expected ?? ""
                return isJapanese(obj, expected)
                    ? "\"\(obj)\"が\"\(expected)\"を含むこと"
                    : "\"\(obj)\" contains \"\(expected)\""
            case "textMatches":
                let expected = step.expected ?? ""
                return isJapanese(obj, expected)
                    ? "\"\(obj)\"が正規表現 \"\(expected)\" に一致すること"
                    : "\"\(obj)\" matches the regex \"\(expected)\""
            case "checked":
                return isJapanese(obj) ? "\"\(obj)\"がオンであること" : "\"\(obj)\" is on"
            case "notChecked":
                return isJapanese(obj) ? "\"\(obj)\"がオフであること" : "\"\(obj)\" is off"
            case "count":
                let count = step.expectedCount ?? 0
                return isJapanese(obj)
                    ? "\"\(obj)\"が\(count)件あること"
                    : "there are \(count) \"\(obj)\""
            case "textEquals":
                let expected = step.expected ?? ""
                return isJapanese(obj, expected)
                    ? "\"\(obj)\"のテキストが\"\(expected)\"であること"
                    : "\"\(obj)\" text is \"\(expected)\""
            case "valueEquals":
                let expected = step.expected ?? ""
                return isJapanese(obj, expected)
                    ? "\"\(obj)\"の値が\"\(expected)\"であること"
                    : "\"\(obj)\" value is \"\(expected)\""
            case "screenMatches":
                let expected = step.expected ?? ""
                return isJapanese(expected)
                    ? "画面が\"\(expected)\"であること"
                    : "the screen matches \"\(expected)\""
            case "keyboardShown":
                return "the keyboard is shown"
            case "keyboardNotShown":
                return "the keyboard is not shown"
            default:
                return nil
            }
        }
        return nil
    }

    /// 説明文の言語判定: どれかに日本語(かな・カナ・CJK 漢字)が含まれれば日本語文。
    /// テスト対象が日本語 UI のときだけ日本語の枠を使い、#id やラテン文字だけのステップに
    /// 日本語の枠を付けない(2026-07-30「内容由来の文は入力の言語に追従」)
    static func isJapanese(_ values: String...) -> Bool {
        values.contains { value in
            value.unicodeScalars.contains { scalar in
                (0x3040...0x30FF).contains(scalar.value)        // ひらがな・カタカナ
                    || (0x4E00...0x9FFF).contains(scalar.value) // CJK 漢字
                    || (0xFF66...0xFF9D).contains(scalar.value) // 半角カナ
            }
        }
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
        // 内容を持たないので常に英語(定型文)
        switch direction {
        case "up", "down", "left", "right": return "swipe \(direction)"
        default: return nil
        }
    }

    private static func rotateToPhrase(orientation: String) -> String? {
        // 内容を持たないので常に英語(定型文)
        FTOrientation(rawValue: orientation) != nil ? "rotate to \(orientation)" : nil
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

    /// `"A"<separator>B` → (A, B)。末尾がクォートでない形(countIs "sel" == 3)用
    private static func unquotedTail(_ text: String, separator: String) -> (String, String)? {
        guard text.hasPrefix("\""), let range = text.range(of: separator) else { return nil }
        let head = String(text[text.index(after: text.startIndex)..<range.lowerBound])
        let tail = String(text[range.upperBound...])
        return tail.isEmpty ? nil : (head, tail)
    }

    /// 1.0 → "1"、0.5 → "0.5"(wait の表示用)。実装は FTSeconds.format に委譲(唯一の生成元)
    private static func formatSeconds(_ seconds: Double) -> String {
        FTSeconds.format(seconds)
    }
}
