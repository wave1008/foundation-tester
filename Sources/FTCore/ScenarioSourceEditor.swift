// ScenarioSourceEditor.swift
// シナリオソース(Swift DSL)の宣言リネーム。呼び出し側(シナリオ編集 UI)の「名前を変更」から使う。
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
    case lineOutOfRange(Int)
    case selectorNotFound(String)
    case selectorAmbiguous(String)
    case invalidCommand(String)
    case commandNotFound(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let reason):
            return "名前が不正です: \(reason)"
        case .invalidCommand(let reason):
            return "コマンドが不正です: \(reason)"
        case .commandNotFound(let line):
            return "\(line) 行目にコマンドがありません(ソースが変更された可能性があります)"
        case .classNotFound(let name):
            return "class \(name) の宣言が見つかりません(再読込してください)"
        case .methodNotFound(let name):
            return "func \(name) の宣言が見つかりません(再読込してください)"
        case .duplicate(let name):
            return "同名の宣言が既にあります: \(name)"
        case .testAttributeNotFound(let method):
            return "func \(method) の @Test 属性が見つかりません"
        case .lineOutOfRange(let line):
            return "行番号が範囲外です: \(line) 行目(ソースが変更された可能性があります)"
        case .selectorNotFound(let selector):
            return "セレクタが見つかりません(ソースが変更された可能性があります): \"\(selector)\""
        case .selectorAmbiguous(let selector):
            return "セレクタが同じ行に複数回出現するため、置換対象を一意に決定できません: \"\(selector)\""
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

    /// 指定行(1 起点)にあるクォート付きセレクタ文字列を書き換える(自己修復の確定反映用)。
    /// 対象行に `"<oldSelector>"` がちょうど 1 回出現することを要求(0 回 = ソース変更の可能性、
    /// 2 回以上 = 曖昧で自動判定できない)。対象行以外・改行・インデントは完全保存する
    public static func replaceSelector(inSource source: String, line: Int,
                                       oldSelector: String, newSelector: String) throws -> String {
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else {
            throw ScenarioSourceEditError.lineOutOfRange(line)
        }
        let target = lines[line - 1]
        let quotedOld = "\"\(oldSelector)\""
        let occurrences = target.components(separatedBy: quotedOld).count - 1
        if occurrences == 0 {
            throw ScenarioSourceEditError.selectorNotFound(oldSelector)
        }
        if occurrences > 1 {
            throw ScenarioSourceEditError.selectorAmbiguous(oldSelector)
        }
        lines[line - 1] = target.replacingOccurrences(of: quotedOld, with: "\"\(newSelector)\"")
        return lines.joined(separator: "\n")
    }

    /// 指定行(1 起点)の行末コメント(// ...)を書き換える(自己修復の説明見直し用)。
    /// コメントが有る行: comment 非空なら本文だけ差し替え(「//」前の空白と「//」直後の
    /// スペーシングは元の形を保つ)、空(空白のみ含む)ならコメント前の空白ごと削除する。
    /// コメントが無い行: comment 非空なら行末に「  // comment」を追記(スペース 2 個 =
    /// 既存生成コードの慣習)、空なら何もしない(そのまま返す)。
    /// 文字列リテラル内の // はコメントと誤認しない(ScenarioSourceComments と同じ認識)
    public static func setTrailingComment(inSource source: String, line: Int,
                                          comment: String) throws -> String {
        if comment.contains("\n") || comment.contains("\r") {
            throw ScenarioSourceEditError.invalidName("説明は 1 行で入力してください")
        }
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else {
            throw ScenarioSourceEditError.lineOutOfRange(line)
        }
        let target = lines[line - 1]
        let newComment = comment.trimmingCharacters(in: .whitespaces)

        guard let commentStart = ScenarioSourceComments.trailingCommentStart(inLine: target) else {
            // コメントの無い行: 追記(空なら no-op)
            guard !newComment.isEmpty else { return source }
            var end = target.endIndex
            while end > target.startIndex {
                let previous = target.index(before: end)
                guard target[previous] == " " || target[previous] == "\t" else { break }
                end = previous
            }
            lines[line - 1] = String(target[..<end]) + "  // " + newComment
            return lines.joined(separator: "\n")
        }

        if newComment.isEmpty {
            // コメント削除(コメント前の空白も除去して行末に余分な空白を残さない)
            var end = commentStart
            while end > target.startIndex {
                let previous = target.index(before: end)
                guard target[previous] == " " || target[previous] == "\t" else { break }
                end = previous
            }
            lines[line - 1] = String(target[..<end])
        } else {
            // 「//」直後の空白は元の形のまま、本文以降を置換
            var textStart = target.index(commentStart, offsetBy: 2)
            while textStart < target.endIndex,
                  target[textStart] == " " || target[textStart] == "\t" {
                textStart = target.index(after: textStart)
            }
            lines[line - 1] = String(target[..<textStart]) + newComment
        }
        return lines.joined(separator: "\n")
    }

    /// 指定行(1 起点)のコード部分(インデントと行末 // コメントを除いた部分)を取り出す
    /// (ステップ表のコマンド編集のプリフィル用)。コードの無い行(空行・コメントのみ)はエラー
    public static func commandCode(inSource source: String, line: Int) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else {
            throw ScenarioSourceEditError.lineOutOfRange(line)
        }
        let target = lines[line - 1]
        let codeEnd = ScenarioSourceComments.trailingCommentStart(inLine: target)
            ?? target.endIndex
        let code = target[..<codeEnd].trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else {
            throw ScenarioSourceEditError.commandNotFound(line)
        }
        return code
    }

    /// 指定行(1 起点)のコード部分を書き換える(ステップ表のコマンド編集の確定反映用)。
    /// インデント・「//」前の空白・行末コメントは元の形を保つ。
    /// code は 1 行・非空・// コメントを含まないこと(説明列の対応関係を壊さないため)
    public static func setCommandCode(inSource source: String, line: Int,
                                      code: String) throws -> String {
        if code.contains("\n") || code.contains("\r") {
            throw ScenarioSourceEditError.invalidCommand("コマンドは 1 行で入力してください")
        }
        let newCode = code.trimmingCharacters(in: .whitespaces)
        if newCode.isEmpty {
            throw ScenarioSourceEditError.invalidCommand("コマンドを入力してください")
        }
        if ScenarioSourceComments.trailingCommentStart(inLine: newCode) != nil {
            throw ScenarioSourceEditError.invalidCommand(
                "// コメントは含められません(説明は説明列のソースコメントで編集してください)")
        }
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else {
            throw ScenarioSourceEditError.lineOutOfRange(line)
        }
        let target = lines[line - 1]
        let codeEnd = ScenarioSourceComments.trailingCommentStart(inLine: target)
            ?? target.endIndex
        let codePart = target[..<codeEnd]
        let indentEnd = codePart.firstIndex { $0 != " " && $0 != "\t" } ?? codePart.endIndex
        guard indentEnd < codePart.endIndex else {
            throw ScenarioSourceEditError.commandNotFound(line)
        }
        // コード末尾〜コメント間の空白は元の形のまま残す
        var trailingStart = codePart.endIndex
        while trailingStart > indentEnd {
            let previous = target.index(before: trailingStart)
            guard target[previous] == " " || target[previous] == "\t" else { break }
            trailingStart = previous
        }
        lines[line - 1] = String(target[..<indentEnd]) + newCode
            + String(target[trailingStart...])
        return lines.joined(separator: "\n")
    }

    // MARK: - ソース位置(VSCode拡張等の外部ツール向け)

    /// class 宣言の行番号(1 起点)。見つからなければ nil
    public static func classDeclarationLine(inSource source: String, className: String) -> Int? {
        guard let decl = classDeclRange(of: className, in: source) else { return nil }
        return lineNumber(of: decl.declRange.lowerBound, in: source)
    }

    /// クラス内のテスト関数(func 宣言)の行番号(1 起点)。memberRange/funcDeclRange と同じ仕組みで
    /// クラス範囲内のみを探索するため、別クラスにある同名 func は拾わない。見つからなければ nil
    public static func methodDeclarationLine(inSource source: String, className: String,
                                              method: String) -> Int? {
        guard let classRange = try? memberRange(ofClass: className, in: source),
              let decl = funcDeclRange(of: method, in: source, within: classRange) else {
            return nil
        }
        return lineNumber(of: decl.declRange.lowerBound, in: source)
    }

    /// String.Index → 1 起点の行番号(index までの改行数 + 1)
    private static func lineNumber(of index: String.Index, in source: String) -> Int {
        source[source.startIndex..<index].reduce(1) { count, char in
            char == "\n" ? count + 1 : count
        }
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
