// ScenarioSourceEditor.swift
// シナリオソース(Swift DSL)の機械的な書き換えと位置特定。ソース文字列の変換だけを行い、
// ファイル I/O は呼び出し側が担う。用途は3つで、いずれも呼び出し口が実在するものだけを置く:
//   ヒール確定反映(replaceSelector / setTrailingComment ← HealFixApplier)
//   宣言の位置(classDeclarationLine / methodDeclarationLine / isTestClass ← api list-scenarios)
//   物理削除(removeMethod ← api delete-scenario)
// クラスのブロック末尾は判定せず「次の class 宣言まで」を範囲とする(文字列リテラル内の
// 波括弧で誤カウントしないため。メソッドはクラス宣言の間にしか現れない前提で十分)

import Foundation

public enum ScenarioSourceEditError: Error, LocalizedError {
    case invalidName(String)
    case classNotFound(String)
    case methodNotFound(String)
    case lineOutOfRange(Int)
    case selectorNotFound(String)
    case selectorAmbiguous(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let reason):
            return "invalid name: \(reason)"
        case .classNotFound(let name):
            return "class declaration not found: \(name) (reload and retry)"
        case .methodNotFound(let name):
            return "func declaration not found: \(name) (reload and retry)"
        case .lineOutOfRange(let line):
            return "line number out of range: line \(line) (the source may have changed)"
        case .selectorNotFound(let selector):
            return "selector not found (the source may have changed): \"\(selector)\""
        case .selectorAmbiguous(let selector):
            return "the selector appears more than once on the line, so the replacement target is ambiguous: \"\(selector)\""
        }
    }
}

public enum ScenarioSourceEditor {

    /// 宣言の前に置ける修飾子・属性の並び(ScenarioFolders.classNames と同じ前提)
    private static let declPrefix =
        #"(?:(?:@[\p{L}\p{N}_]+(?:\([^)]*\))?|public|open|internal|package|final|static)[ \t]+)*"#

    /// 指定行(1 起点)にあるクォート付きセレクタ文字列を書き換える(自己修復の確定反映用)。
    /// 対象行に `"<oldSelector>"` がちょうど 1 回出現することを要求(0 回 = ソース変更の可能性、
    /// 2 回以上 = 曖昧で自動判定できない)。対象行以外・改行・インデントは完全保存する。
    ///
    /// **両側を Swift リテラルとして綴る**。ここは**利用者の .swift を直接書き換える
    /// 唯一の経路**(`ftester api apply-heal`)なので、素の `"\(selector)"` で綴ると
    /// **`"` を含むラベルでコンパイルできないコードを書き込む**。実際に再現した形:
    ///
    ///     tap("*【速報】"特価"セール開催中*")   ← 不正な Swift
    ///
    /// 探索側も同じ綴りにする —— 綴りが片側だけだと、正しくエスケープして書かれている行を
    /// 「見つからない」と誤判定して修復が黙って落ちる(こちらは以前から在った穴)。
    /// **エスケープの定義は `ScenarioCodeGen.literal` の1箇所**(下書き生成と共有。2つ目を書かない)
    public static func replaceSelector(inSource source: String, line: Int,
                                       oldSelector: String, newSelector: String) throws -> String {
        var lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else {
            throw ScenarioSourceEditError.lineOutOfRange(line)
        }
        let target = lines[line - 1]
        let quotedOld = ScenarioCodeGen.literal(oldSelector)
        let occurrences = target.components(separatedBy: quotedOld).count - 1
        if occurrences == 0 {
            throw ScenarioSourceEditError.selectorNotFound(oldSelector)
        }
        if occurrences > 1 {
            throw ScenarioSourceEditError.selectorAmbiguous(oldSelector)
        }
        lines[line - 1] = target.replacingOccurrences(
            of: quotedOld, with: ScenarioCodeGen.literal(newSelector))
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
            throw ScenarioSourceEditError.invalidName("the description must be a single line")
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

    // MARK: - ソース位置(VSCode拡張等の外部ツール向け)

    /// class 宣言の行番号(1 起点)。見つからなければ nil
    public static func classDeclarationLine(inSource source: String, className: String) -> Int? {
        guard let decl = classDeclRange(of: className, in: source) else { return nil }
        return lineNumber(of: decl.declRange.lowerBound, in: source)
    }

    /// className の class 宣言が @TestClass を持つか(@Test を1件も持たない空クラスも
    /// テストクラスとしてツリー表示するための判定。宣言直上の属性行群に @TestClass があれば true)。
    public static func isTestClass(inSource source: String, className: String) -> Bool {
        guard let declLine = classDeclarationLine(inSource: source, className: className) else {
            return false
        }
        let lines = source.components(separatedBy: "\n")
        var idx = declLine - 2  // class 宣言行(1起点)の直上(0起点)
        while idx >= 0 {
            let trimmed = lines[idx].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if trimmed.isEmpty { idx -= 1; continue }
            if trimmed.hasPrefix("@TestClass") { return true }
            if trimmed.hasPrefix("@") { idx -= 1; continue }  // @Deleted 等を挟んでもよい
            return false  // 属性でない行に到達
        }
        return false
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

    // MARK: - 削除(TEST EXPLORER の右クリック「削除」= 物理削除)

    /// テスト関数を、直前の属性行(@Test / @Deleted 等)から func 本体の閉じ波括弧までまとめて除去する。
    /// 本体末尾は「func 宣言と同じインデントの `}` 行」で判定する(DSL は固定インデント整形前提。
    /// 文字列リテラル内の波括弧を数えないための割り切り。ファイル冒頭の方針と同じ)。
    /// 属性・func・末尾波括弧のいずれかを特定できないときは throw する(壊すより安全側で中断)。
    public static func removeMethod(inSource source: String, className: String,
                                    method: String) throws -> String {
        let classRange = try memberRange(ofClass: className, in: source)
        guard let decl = funcDeclRange(of: method, in: source, within: classRange) else {
            throw ScenarioSourceEditError.methodNotFound(method)
        }
        let funcLine = lineNumber(of: decl.declRange.lowerBound, in: source)  // 1 起点
        var lines = source.components(separatedBy: "\n")
        let funcIdx = funcLine - 1
        guard funcIdx >= 0, funcIdx < lines.count else {
            throw ScenarioSourceEditError.methodNotFound(method)
        }
        let indent = String(lines[funcIdx].prefix { $0 == " " || $0 == "\t" })
        let closer = indent + "}"

        // 本体末尾: func 行より後で、末尾空白を除いてちょうど `<indent>}` になる最初の行。
        // 本体・ネストしたブロックの閉じ波括弧はより深いインデントなので、これが func 自身の閉じになる
        var closeIdx: Int?
        var i = funcIdx + 1
        while i < lines.count {
            let stripped = lines[i].replacingOccurrences(of: #"[ \t]+$"#, with: "",
                                                         options: .regularExpression)
            if stripped == closer { closeIdx = i; break }
            i += 1
        }
        guard let endIdx = closeIdx else {
            throw ScenarioSourceEditError.methodNotFound(method)
        }

        // 属性ブロック先頭: func 行の直上から、@ で始まる行(@Test / @Deleted 等)を遡って含める
        var startIdx = funcIdx
        var j = funcIdx - 1
        while j >= 0 {
            let trimmed = lines[j].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if trimmed.hasPrefix("@") { startIdx = j; j -= 1 } else { break }
        }

        // メソッド間の区切り空行が二重に残らないよう、直後の空行を1行だけ巻き込む
        var removeEnd = endIdx
        if removeEnd + 1 < lines.count,
           lines[removeEnd + 1].trimmingCharacters(in: CharacterSet(charactersIn: " \t")).isEmpty {
            removeEnd += 1
        }
        lines.removeSubrange(startIdx...removeEnd)
        return lines.joined(separator: "\n")
    }

    /// String.Index → 1 起点の行番号(index までの改行数 + 1)
    private static func lineNumber(of index: String.Index, in source: String) -> Int {
        source[source.startIndex..<index].reduce(1) { count, char in
            char == "\n" ? count + 1 : count
        }
    }

    // MARK: - 内部

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
