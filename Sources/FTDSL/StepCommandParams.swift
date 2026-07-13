// ステップ表の「コマンド」列の表示表現には現れないキーワード引数
// (timeout: / duration: / optional: / direction: / maxSwipes:)を構造化編集する API。
// StepCommandText(表示表現↔ソースの変換)が保存するだけの非表示引数を、ソースのコード部分
// から解釈して現在値を取り出し(parse)、編集後の値で呼び出し全体を正規形に生成し直す
// (apply。defaultValue と等しい引数は出力しない)。値は文字列リテラル・enum ケース・
// 整数・小数・真偽値のみ許容し、変数・式・文字列補間を含む行は編集不可(nil)とする。

import Foundation

/// パラメーターの値の型(UI の入力コントロールの選択と値の検証に使う)
public enum StepParamKind: Equatable { case int, double, bool, direction }

/// 編集できるキーワード引数 1 つ分の定義
public struct StepParamSpec: Equatable {
    /// 引数ラベル("timeout")
    public let name: String
    /// UI 表示名("タイムアウト(秒)")
    public let label: String
    public let kind: StepParamKind
    /// 「引数を省略する」ことを意味する UI 値("false"/"1"/"up"/""=timeout 省略)
    public let defaultValue: String
    /// ツールチップ説明文(日本語)
    public let help: String
}

public enum StepCommandParamsError: Error, LocalizedError, Equatable {
    /// 値が型に合わない(例: maxSwipes は整数で入力してください)
    case invalidValue(label: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let label, let reason):
            return "\(label) は\(reason)"
        }
    }
}

public enum StepCommandParams {

    // MARK: - スキーマ

    private static let optionalSpec = StepParamSpec(
        name: "optional", label: "任意(見つからなくても失敗にしない)", kind: .bool,
        defaultValue: "false",
        help: "オンにすると要素が見つからなくても NG にせずスキップします")

    private static let durationSpec = StepParamSpec(
        name: "duration", label: "長押し時間(秒)", kind: .double, defaultValue: "1",
        help: "長押しする秒数(既定 1 秒)")

    private static let directionSpec = StepParamSpec(
        name: "direction", label: "方向", kind: .direction, defaultValue: "up",
        help: "スクロールする方向(既定 up)")

    private static let maxSwipesSpec = StepParamSpec(
        name: "maxSwipes", label: "最大スワイプ回数", kind: .int, defaultValue: "8",
        help: "見つからないときに諦めるまでのスワイプ回数(既定 8 回)")

    private static let timeoutSpec = StepParamSpec(
        name: "timeout", label: "タイムアウト(秒)", kind: .int, defaultValue: "",
        help: "要素の出現を待つ秒数。空欄 = 実行プロファイルの既定値を使う")

    /// 動詞ごとの編集できるキーワード引数(シグネチャ順)。tap の optional は表示表現の
    /// 「 (optional)」サフィックス側で編集するため含めない(二重管理回避)
    public static func specs(forVerb verb: String) -> [StepParamSpec] {
        switch verb {
        case "type": return [optionalSpec]
        case "press": return [durationSpec, optionalSpec]
        case "scrollTo": return [directionSpec, maxSwipesSpec]
        case "exist", "textIs", "valueIs": return [timeoutSpec]
        default: return []
        }
    }

    // MARK: - parse(ソースからの現在値の取得)

    /// ソースのコード部分(ScenarioSourceEditor.commandCode の戻り値相当)から
    /// キーワード引数の現在値を返す(省略された引数は defaultValue で埋める)。
    /// 関数名が verb と一致しない・ブロック行・値に変数や式や文字列補間を含む・
    /// 未知ラベル・ラベル重複の場合は nil(= パラメーター編集不可)
    public static func parse(code: String, verb: String) -> [String: String]? {
        guard let nameRange = code.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*"#, options: .regularExpression),
            String(code[nameRange]) == StepCommandText.funcName(forVerb: verb),
            let fragments = scanArguments(code, after: nameRange.upperBound) else {
            return nil
        }
        let specList = specs(forVerb: verb)
        if specList.isEmpty { return [:] }  // swipe(.up) 等は関数名と構文の確認だけで十分

        var values: [String: String] = [:]
        for fragment in fragments {
            if let (label, valueText) = keywordArgument(fragment) {
                guard let spec = specList.first(where: { $0.name == label }),  // 未知ラベル
                      values[label] == nil,                                    // 重複
                      let uiValue = decode(valueText, kind: spec.kind) else {
                    return nil
                }
                values[label] = uiValue
            } else {
                // positional 引数は文字列リテラルのみ許容(変数・式は編集不可)
                guard isPlainStringLiteral(fragment) else { return nil }
            }
        }
        var result: [String: String] = [:]
        for spec in specList { result[spec.name] = values[spec.name] ?? spec.defaultValue }
        return result
    }

    // MARK: - apply(編集の適用)

    /// params == nil はパラメーター編集なし = StepCommandText.apply(文字列リテラル置換で
    /// 非表示引数を保存)を使う。params != nil は呼び出し全体を正規形で生成し直す
    /// (defaultValue と等しい引数は出力しない)
    public static func apply(display: String, params: [String: String]?,
                             toCode code: String) throws -> String {
        guard let params else {
            return try StepCommandText.apply(display: display, toCode: code)
        }
        guard let parsed = StepCommandText.parse(display) else {
            throw StepCommandTextError.unrecognized
        }
        guard let call = StepCommandText.scanCall(code) else {
            throw StepCommandTextError.sourceNotRewritable(String(code.prefix(20)))
        }
        if call.hasTrailingBrace {
            throw StepCommandTextError.blockCommand
        }
        guard StepCommandText.renewableFuncs.contains(call.verb) else {
            throw StepCommandTextError.sourceNotRewritable(call.verb)
        }
        return try render(parsed, params: params, display: display, code: code)
    }

    // MARK: - 生成(内部)

    /// 解釈済みの表示表現と編集後パラメーターから正規形の呼び出しコードを生成する。
    /// 文字列引数のエスケープは StepCommandText.literal に委ねる
    private static func render(_ parsed: StepCommandText.Parsed, params: [String: String],
                               display: String, code: String) throws -> String {
        switch parsed.verb {
        case "type":
            let optional = try optionalArg(parsed, params)
            if parsed.strings.count == 1 {
                return "type(\(StepCommandText.literal(parsed.strings[0]))\(optional))"
            }
            return "type(\(StepCommandText.literal(parsed.strings[0])), "
                + "\(StepCommandText.literal(parsed.strings[1]))\(optional))"
        case "press":
            var arguments = StepCommandText.literal(parsed.strings[0])
            let duration = try doubleValue(value(params, durationSpec), name: "duration")
            if StepCommandText.formatSeconds(duration) != durationSpec.defaultValue {
                arguments += ", duration: \(StepCommandText.formatSeconds(duration))"
            }
            arguments += try optionalArg(parsed, params)
            return "press(\(arguments))"
        case "scrollTo":
            var arguments = StepCommandText.literal(parsed.strings[0])
            let direction = try directionValue(value(params, directionSpec), name: "direction")
            if direction != directionSpec.defaultValue {
                arguments += ", direction: .\(direction)"
            }
            let maxSwipes = try intValue(value(params, maxSwipesSpec), name: "maxSwipes")
            if String(maxSwipes) != maxSwipesSpec.defaultValue {
                arguments += ", maxSwipes: \(maxSwipes)"
            }
            return "scrollTo(\(arguments))"
        case "exist":
            let timeout = try timeoutArg(params)
            return "exist(\(StepCommandText.literal(parsed.strings[0]))\(timeout))"
        case "textIs", "valueIs":
            let timeout = try timeoutArg(params)
            return "\(parsed.verb)(\(StepCommandText.literal(parsed.strings[0])), "
                + "\(StepCommandText.literal(parsed.strings[1]))\(timeout))"
        default:
            // specs が空の動詞(tap / swipe / wait / launch / relaunch / terminate /
            // screenIs)にパラメーターは無い。StepCommandText.apply(リテラル置換 or 再生成)に委ねる
            return try StepCommandText.apply(display: display, toCode: code)
        }
    }

    /// type / press の optional。表示表現に手でサフィックスを書いた場合も尊重する
    /// (parsed.optionalFlag || params の "true")
    private static func optionalArg(_ parsed: StepCommandText.Parsed,
                                    _ params: [String: String]) throws -> String {
        let fromParams = try boolValue(value(params, optionalSpec), name: "optional")
        return (parsed.optionalFlag || fromParams) ? ", optional: true" : ""
    }

    /// exist / textIs / valueIs の timeout(空文字 = 省略 = プロファイル既定)
    private static func timeoutArg(_ params: [String: String]) throws -> String {
        let text = value(params, timeoutSpec)
        if text.isEmpty { return "" }
        let timeout = try intValue(text, name: "timeout")
        return ", timeout: \(timeout)"
    }

    // MARK: - 値の検証(内部)

    /// params から spec の現在値を取り出す(キー欠落は既定値扱い)
    private static func value(_ params: [String: String], _ spec: StepParamSpec) -> String {
        params[spec.name] ?? spec.defaultValue
    }

    private static func intValue(_ text: String, name: String) throws -> Int {
        guard let value = Int(text) else {
            throw StepCommandParamsError.invalidValue(
                label: name, reason: "整数で入力してください")
        }
        return value
    }

    private static func doubleValue(_ text: String, name: String) throws -> Double {
        guard let value = Double(text), value.isFinite else {
            throw StepCommandParamsError.invalidValue(
                label: name, reason: "数値で入力してください")
        }
        return value
    }

    private static func boolValue(_ text: String, name: String) throws -> Bool {
        switch text {
        case "true": return true
        case "false": return false
        default:
            throw StepCommandParamsError.invalidValue(
                label: name, reason: "true / false のどちらかで指定してください")
        }
    }

    private static func directionValue(_ text: String, name: String) throws -> String {
        guard directions.contains(text) else {
            throw StepCommandParamsError.invalidValue(
                label: name, reason: "up / down / left / right のいずれかで指定してください")
        }
        return text
    }

    private static let directions = ["up", "down", "left", "right"]

    // MARK: - トークナイザ(内部)

    /// 関数名直後の `( ... )` を走査してトップレベル引数の断片(trim 済み)に分割する。
    /// 文字列リテラル状態+エスケープ+括弧深度を追跡する。対応する `)` が無い・
    /// `)` の後に空白以外の文字が残る(`{` を伴うブロック行等)場合は nil
    private static func scanArguments(_ code: String,
                                      after nameEnd: String.Index) -> [String]? {
        var index = nameEnd
        while index < code.endIndex, code[index] == " " || code[index] == "\t" {
            index = code.index(after: index)
        }
        guard index < code.endIndex, code[index] == "(" else { return nil }
        index = code.index(after: index)

        var fragments: [String] = []
        var current = ""
        var depth = 1
        var inString = false
        var isEscaped = false
        while index < code.endIndex {
            let char = code[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
                current.append(char)
            } else if char == "\"" {
                inString = true
                current.append(char)
            } else if char == "(" {
                depth += 1
                current.append(char)
            } else if char == ")" {
                depth -= 1
                if depth == 0 {
                    let rest = code[code.index(after: index)...]
                    guard rest.trimmingCharacters(in: .whitespaces).isEmpty else {
                        return nil  // `)` の後に文字が残る = ブロック行など(編集不可)
                    }
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        fragments.append(trimmed)
                    } else if !fragments.isEmpty {
                        return nil  // 末尾カンマ等の空引数は解釈不能
                    }
                    return fragments
                }
                current.append(char)
            } else if char == ",", depth == 1 {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }  // 空引数(",," 等)
                fragments.append(trimmed)
                current = ""
            } else {
                current.append(char)
            }
            index = code.index(after: index)
        }
        return nil  // 対応する閉じ括弧が無い
    }

    /// 断片が `ラベル: 値` の keyword 引数なら(ラベル, 値テキスト)を返す
    private static func keywordArgument(_ fragment: String) -> (String, String)? {
        guard let labelRange = fragment.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*(?=\s*:)"#, options: .regularExpression),
            let colonIndex = fragment[labelRange.upperBound...].firstIndex(of: ":") else {
            return nil
        }
        let valueText = fragment[fragment.index(after: colonIndex)...]
            .trimmingCharacters(in: .whitespaces)
        return (String(fragment[labelRange]), valueText)
    }

    /// 断片全体が(補間を含まない)1 つの文字列リテラルかどうか
    private static func isPlainStringLiteral(_ text: String) -> Bool {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return false }
        var isEscaped = false
        var index = text.index(after: text.startIndex)
        let last = text.index(before: text.endIndex)
        while index < last {
            let char = text[index]
            if isEscaped {
                if char == "(" { return false }  // 文字列補間 \( は編集不可
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "\"" {
                return false  // リテラルが途中で閉じている = 複数トークン
            }
            index = text.index(after: index)
        }
        return !isEscaped  // 末尾の閉じクォートがエスケープされていれば不成立
    }

    /// keyword 引数の値テキストを UI 値へデコードする。認めるのは kind に合う
    /// リテラルのみで、変数・式・文字列補間などの許容外は nil
    private static func decode(_ text: String, kind: StepParamKind) -> String? {
        switch kind {
        case .bool:
            return (text == "true" || text == "false") ? text : nil
        case .int:
            guard text.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil,
                  let value = Int(text) else { return nil }
            return String(value)
        case .double:
            guard text.range(
                of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let value = Double(text) else { return nil }
            return StepCommandText.formatSeconds(value)  // 整数値なら小数点なし
        case .direction:
            guard text.hasPrefix("."),
                  directions.contains(String(text.dropFirst())) else { return nil }
            return String(text.dropFirst())  // 先頭の . を外した形("up" 等)
        }
    }
}
