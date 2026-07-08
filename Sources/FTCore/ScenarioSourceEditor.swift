// ScenarioSourceEditor.swift
// シナリオソース(Swift DSL)の宣言リネーム。GUI の右クリック「名前を変更」から使う。
// 対象はテストクラス名(class 宣言)・テスト関数名(@Test メソッドの func 宣言)・
// @Test の説明文字列の 3 つ。ソース文字列の変換だけを行い、ファイル I/O は呼び出し側が担う。
// クラスのブロック末尾は判定せず「次の class 宣言まで」を範囲とする(文字列リテラル内の
// 波括弧で誤カウントしないため。メソッドはクラス宣言の間にしか現れない前提で十分)

import Foundation

public enum ScenarioSourceEditError: Error, LocalizedError {
    case invalidName(String)
    case classNotFound(String)
    case methodNotFound(String)
    case duplicate(String)
    case testAttributeNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let reason):
            return "名前が不正です: \(reason)"
        case .classNotFound(let name):
            return "class \(name) の宣言が見つかりません(再読込してください)"
        case .methodNotFound(let name):
            return "func \(name) の宣言が見つかりません(再読込してください)"
        case .duplicate(let name):
            return "同名の宣言が既にあります: \(name)"
        case .testAttributeNotFound(let method):
            return "func \(method) の @Test 属性が見つかりません"
        }
    }
}

public enum ScenarioSourceEditor {

    /// 宣言の前に置ける修飾子・属性の並び(ScenarioFolders.classNames と同じ前提)
    private static let declPrefix =
        #"(?:(?:@[\p{L}\p{N}_]+(?:\([^)]*\))?|public|open|internal|package|final|static)[ \t]+)*"#

    /// クラス名・関数名の検証。戻り値: エラーメッセージ(nil = 有効)。
    /// Swift 識別子の実用サブセット(英数字・日本語・_、先頭は数字以外)に限定する
    public static func validateIdentifier(_ name: String) -> String? {
        if name.isEmpty {
            return "名前を入力してください"
        }
        if name.range(of: #"^[\p{L}_][\p{L}\p{N}_]*$"#, options: .regularExpression) == nil {
            return "英数字・日本語・「_」のみ、先頭は数字以外にしてください"
        }
        if swiftKeywords.contains(name) {
            return "Swift の予約語は使えません: \(name)"
        }
        return nil
    }

    /// class 宣言のクラス名を変更する(最初の 1 宣言のみ。同一ファイル内の重複はエラー)
    public static func renameClass(inSource source: String,
                                   from oldName: String, to newName: String) throws -> String {
        if let reason = validateIdentifier(newName) {
            throw ScenarioSourceEditError.invalidName(reason)
        }
        if classDeclRange(of: newName, in: source) != nil {
            throw ScenarioSourceEditError.duplicate(newName)
        }
        guard let decl = classDeclRange(of: oldName, in: source) else {
            throw ScenarioSourceEditError.classNotFound(oldName)
        }
        return source.replacingCharacters(in: decl.nameRange, with: newName)
    }

    /// クラス内のテスト関数(func 宣言)の名前を変更する
    public static func renameMethod(inSource source: String, className: String,
                                    from oldName: String, to newName: String) throws -> String {
        if let reason = validateIdentifier(newName) {
            throw ScenarioSourceEditError.invalidName(reason)
        }
        let classRange = try memberRange(ofClass: className, in: source)
        if funcDeclRange(of: newName, in: source, within: classRange) != nil {
            throw ScenarioSourceEditError.duplicate(newName)
        }
        guard let decl = funcDeclRange(of: oldName, in: source, within: classRange) else {
            throw ScenarioSourceEditError.methodNotFound(oldName)
        }
        return source.replacingCharacters(in: decl.nameRange, with: newName)
    }

    /// テスト関数の @Test("説明") の説明文字列を書き換える。
    /// 空文字列にしたときは引数なしの @Test にする
    public static func setTestTitle(inSource source: String, className: String,
                                    method: String, title: String) throws -> String {
        if title.contains("\n") || title.contains("\r") {
            throw ScenarioSourceEditError.invalidName("説明は 1 行で入力してください")
        }
        let classRange = try memberRange(ofClass: className, in: source)
        guard let decl = funcDeclRange(of: method, in: source, within: classRange) else {
            throw ScenarioSourceEditError.methodNotFound(method)
        }
        // func 宣言より前にある最も近い @Test 属性行(@Deleted 等を挟んでもよい)。
        // 直前に別の func 宣言が挟まる場合は他メソッドの属性なので対象外
        let attrPattern = #"(?m)^[ \t]*@Test(?:[ \t]*\([^\n]*\))?[ \t]*$"#
        let searchRange = classRange.lowerBound..<decl.declRange.lowerBound
        guard let regex = try? NSRegularExpression(pattern: attrPattern) else {
            throw ScenarioSourceEditError.testAttributeNotFound(method)
        }
        let matches = regex.matches(in: source, range: NSRange(searchRange, in: source))
        guard let last = matches.last, let attrRange = Range(last.range, in: source) else {
            throw ScenarioSourceEditError.testAttributeNotFound(method)
        }
        let between = source[attrRange.upperBound..<decl.declRange.lowerBound]
        if between.range(of: #"(?m)^[ \t]*"# + declPrefix + #"func[ \t]"#,
                         options: .regularExpression) != nil {
            throw ScenarioSourceEditError.testAttributeNotFound(method)
        }
        let indent = source[attrRange].prefix { $0 == " " || $0 == "\t" }
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let newAttr = title.isEmpty ? "\(indent)@Test" : "\(indent)@Test(\"\(escaped)\")"
        return source.replacingCharacters(in: attrRange, with: newAttr)
    }

    // MARK: - 内部

    /// 予約語(リネーム先に指定するとビルドが壊れるため拒否する。実用的な範囲のみ)
    private static let swiftKeywords: Set<String> = [
        "class", "struct", "enum", "protocol", "extension", "func", "var", "let",
        "import", "typealias", "init", "deinit", "self", "Self", "super",
        "if", "else", "for", "while", "repeat", "switch", "case", "default",
        "return", "break", "continue", "guard", "defer", "do", "try", "catch",
        "throw", "throws", "rethrows", "async", "await", "in", "is", "as",
        "true", "false", "nil", "static", "public", "private", "internal",
        "fileprivate", "open", "final", "where", "operator", "subscript",
    ]

    private struct DeclMatch {
        let declRange: Range<String.Index>  // 宣言全体(行頭の修飾子から名前まで)
        let nameRange: Range<String.Index>  // 名前部分
    }

    /// class 宣言の位置(名前完全一致)。コメント行を拾わないよう行頭アンカー
    private static func classDeclRange(of name: String,
                                       in source: String) -> DeclMatch? {
        declRange(keyword: "class", name: name, in: source,
                  within: source.startIndex..<source.endIndex)
    }

    /// func 宣言の位置(名前完全一致、range 内のみ)
    private static func funcDeclRange(of name: String, in source: String,
                                      within range: Range<String.Index>) -> DeclMatch? {
        declRange(keyword: "func", name: name, in: source, within: range)
    }

    private static func declRange(keyword: String, name: String, in source: String,
                                  within range: Range<String.Index>) -> DeclMatch? {
        let pattern = #"(?m)^[ \t]*"# + declPrefix + keyword + #"[ \t]+("#
            + NSRegularExpression.escapedPattern(for: name) + #")(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(range, in: source)),
              let declRange = Range(match.range, in: source),
              let nameRange = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return DeclMatch(declRange: declRange, nameRange: nameRange)
    }

    /// クラスのメンバー探索範囲 = 宣言の直後から次の class 宣言(なければ末尾)まで
    private static func memberRange(ofClass className: String,
                                    in source: String) throws -> Range<String.Index> {
        guard let decl = classDeclRange(of: className, in: source) else {
            throw ScenarioSourceEditError.classNotFound(className)
        }
        let pattern = #"(?m)^[ \t]*"# + declPrefix + #"class[ \t]+[\p{L}\p{N}_]+"#
        let tail = decl.declRange.upperBound..<source.endIndex
        if let regex = try? NSRegularExpression(pattern: pattern),
           let next = regex.firstMatch(in: source, range: NSRange(tail, in: source)),
           let nextRange = Range(next.range, in: source) {
            return decl.declRange.upperBound..<nextRange.lowerBound
        }
        return tail
    }
}
