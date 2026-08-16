// 任意の値に対する検証(Shirates の thisIs 系。`Any?` の拡張として同じ名前・同じ意味で提供する)。
// デバイスに触れないので**素の Swift の値**(API 応答・memo・計算結果)をシナリオの中で検証できる。
// 失敗はステップとして記録され、シナリオを中断する(DSL コマンドと同じ失敗セマンティクス)。

import Foundation
import FTCore

extension Optional where Wrapped == Any {
    /// 検証を1ステップとして記録する共通経路。**表示は実際の値**(nil は "nil")。
    /// 失敗後のスキップと dry-run の扱いは DSL コマンド(performCustom)と同じにする
    /// — ここだけ素通りすると、失敗後に検証だけが走り、dry-run のステップ列挙に ❌ が出る
    fileprivate func record(_ verb: String, _ detail: String, _ passed: Bool,
                            file: StaticString, line: UInt) {
        let core = FTRuntime.requireCore(command: verb)
        let description = "\(verb) \(detail)"
        // verify() のブロック内アサーション数を数える(perform() 側の同種フックと対になる)
        core.noteAssertion()
        if core.scenarioAborted {
            core.recordStep(description: description, status: .skipped(core.skipReason),
                            file: "\(file)", line: Int(line))
            return
        }
        if core.dryRun {
            core.recordStep(description: description, status: .passed,
                            file: "\(file)", line: Int(line))
            return
        }
        core.recordStep(description: description,
                        status: passed ? .passed : .failed("\(description) did not hold"),
                        file: "\(file)", line: Int(line))
        if !passed { core.handleFailure(stepDescription: description, reason: "\(description) did not hold") }
    }

    fileprivate var stringValue: String? {
        guard let self else { return nil }
        if let text = self as? String { return text }
        return String(describing: self)
    }
}

public extension Optional where Wrapped == Any {

    /// 掴んだ値と期待値の比較。**他のテキスト比較と同じ正規化を通す**(2026-08-09) ——
    /// ここだけ素の `==` だったため、実データに紛れたゼロ幅1文字で落ちる一方、
    /// 同じ文字列のセレクタは当たる、という経路ごとに答えの違う状態だった。
    /// `strict: true` で一切正規化しない(textIs 等と同じ引数)
    func thisIs(_ expected: Any?, strict: Bool = false,
                file: StaticString = #filePath, line: UInt = #line) {
        let actual = stringValue
        let expectedText = Self.text(expected)
        let matched = FlowMatchMode.exact.matches(actual, expectedText,
                                                  normalization: strict ? .strict : .text)
        record("thisIs", "\"\(actual ?? "nil")\" == \"\(expectedText)\""
               + (matched ? "" : StepExecutor.normalizationVerdict(
                   actual: actual, expected: expectedText, assert: "textEquals")),
               matched, file: file, line: line)
    }

    func thisIsNot(_ expected: Any?, strict: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) {
        let actual = stringValue
        let expectedText = Self.text(expected)
        let matched = FlowMatchMode.exact.matches(actual, expectedText,
                                                  normalization: strict ? .strict : .text)
        record("thisIsNot", "\"\(actual ?? "nil")\" != \"\(expectedText)\"",
               !matched, file: file, line: line)
    }

    func thisIsTrue(file: StaticString = #filePath, line: UInt = #line) {
        record("thisIsTrue", "\(stringValue ?? "nil")", (self as? Bool) == true, file: file, line: line)
    }

    func thisIsFalse(file: StaticString = #filePath, line: UInt = #line) {
        record("thisIsFalse", "\(stringValue ?? "nil")", (self as? Bool) == false, file: file, line: line)
    }

    func thisIsEmpty(file: StaticString = #filePath, line: UInt = #line) {
        record("thisIsEmpty", "\"\(stringValue ?? "nil")\"", (stringValue ?? "").isEmpty,
               file: file, line: line)
    }

    func thisIsNotEmpty(file: StaticString = #filePath, line: UInt = #line) {
        record("thisIsNotEmpty", "\"\(stringValue ?? "nil")\"", !(stringValue ?? "").isEmpty,
               file: file, line: line)
    }

    /// 空白文字だけか(Shirates の thisIsBlank。空文字も blank に含む)
    func thisIsBlank(file: StaticString = #filePath, line: UInt = #line) {
        let text = stringValue ?? ""
        record("thisIsBlank", "\"\(text)\"",
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, file: file, line: line)
    }

    func thisIsNotBlank(file: StaticString = #filePath, line: UInt = #line) {
        let text = stringValue ?? ""
        record("thisIsNotBlank", "\"\(text)\"",
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, file: file, line: line)
    }

    func thisContains(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        record("thisContains", "\"\(stringValue ?? "nil")\" ~ \"\(expected)\"",
               (stringValue ?? "").contains(expected), file: file, line: line)
    }

    func thisContainsNot(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        record("thisContainsNot", "\"\(stringValue ?? "nil")\" !~ \"\(expected)\"",
               !(stringValue ?? "").contains(expected), file: file, line: line)
    }

    func thisStartsWith(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        record("thisStartsWith", "\"\(stringValue ?? "nil")\" ~ \"\(expected)\"",
               (stringValue ?? "").hasPrefix(expected), file: file, line: line)
    }

    func thisStartsWithNot(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        record("thisStartsWithNot", "\"\(stringValue ?? "nil")\" !~ \"\(expected)\"",
               !(stringValue ?? "").hasPrefix(expected), file: file, line: line)
    }

    func thisEndsWith(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        record("thisEndsWith", "\"\(stringValue ?? "nil")\" ~ \"\(expected)\"",
               (stringValue ?? "").hasSuffix(expected), file: file, line: line)
    }

    func thisEndsWithNot(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        record("thisEndsWithNot", "\"\(stringValue ?? "nil")\" !~ \"\(expected)\"",
               !(stringValue ?? "").hasSuffix(expected), file: file, line: line)
    }

    func thisMatches(_ pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        record("thisMatches", "\"\(stringValue ?? "nil")\" ~ \"\(pattern)\"",
               (stringValue ?? "").range(of: pattern, options: .regularExpression) != nil,
               file: file, line: line)
    }

    func thisMatchesNot(_ pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        record("thisMatchesNot", "\"\(stringValue ?? "nil")\" !~ \"\(pattern)\"",
               (stringValue ?? "").range(of: pattern, options: .regularExpression) == nil,
               file: file, line: line)
    }

    /// 日付書式(`yyyy/MM/dd` 等)に一致するか。書式は DateFormatter の記法
    func thisMatchesDateFormat(_ format: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        record("thisMatchesDateFormat", "\"\(stringValue ?? "nil")\" ~ \"\(format)\"",
               formatter.date(from: stringValue ?? "") != nil, file: file, line: line)
    }

    /// 数値比較(Shirates の thisIsGreaterThan 等)。数値に解釈できなければ失敗
    func thisIsGreaterThan(_ other: Double, file: StaticString = #filePath, line: UInt = #line) {
        compare("thisIsGreaterThan", other, file: file, line: line) { $0 > $1 }
    }

    func thisIsGreaterThanOrEqual(_ other: Double,
                                  file: StaticString = #filePath, line: UInt = #line) {
        compare("thisIsGreaterThanOrEqual", other, file: file, line: line) { $0 >= $1 }
    }

    func thisIsLessThan(_ other: Double, file: StaticString = #filePath, line: UInt = #line) {
        compare("thisIsLessThan", other, file: file, line: line) { $0 < $1 }
    }

    func thisIsLessThanOrEqual(_ other: Double,
                               file: StaticString = #filePath, line: UInt = #line) {
        compare("thisIsLessThanOrEqual", other, file: file, line: line) { $0 <= $1 }
    }

    private func compare(_ verb: String, _ other: Double, file: StaticString, line: UInt,
                         _ test: (Double, Double) -> Bool) {
        let number = (self as? Double) ?? (self as? Int).map(Double.init)
            ?? Double(stringValue ?? "")
        record(verb, "\(stringValue ?? "nil") vs \(other)",
               number.map { test($0, other) } ?? false, file: file, line: line)
    }

    private static func text(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let text = value as? String { return text }
        return String(describing: value)
    }
}

// MARK: - 素の値へ生やす(Swift 固有の事情)

/// `thisIs` 系を呼べる値。**Shirates は `Any?` の拡張だが、Swift は非 Optional の値に
/// Optional の拡張が生えない**(`"abc".thisIs(...)` が型解決できない)。利用者に
/// `let v: Any? = …` を書かせないため、素の値はこのプロトコル経由で同じ API を持つ。
/// 実装は上の `Optional where Wrapped == Any` にだけ置き、ここは転送のみ
public protocol FTValue {}

extension String: FTValue {}
extension Substring: FTValue {}
extension Int: FTValue {}
extension Double: FTValue {}
extension Bool: FTValue {}
/// `String?` / `Int?` 等。`Any?` は Any が準拠できないので上の拡張が直接受ける
extension Optional: FTValue where Wrapped: FTValue {}

public extension FTValue {
    /// nil の Optional は `Optional<Any>.some(Optional<T>.none)` になり、表示は "nil" になる
    private var anyValue: Any? { self }

    func thisIs(_ expected: Any?, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIs(expected, file: file, line: line)
    }

    func thisIsNot(_ expected: Any?, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsNot(expected, file: file, line: line)
    }

    func thisIsTrue(file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsTrue(file: file, line: line)
    }

    func thisIsFalse(file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsFalse(file: file, line: line)
    }

    func thisIsEmpty(file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsEmpty(file: file, line: line)
    }

    func thisIsNotEmpty(file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsNotEmpty(file: file, line: line)
    }

    func thisIsBlank(file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsBlank(file: file, line: line)
    }

    func thisIsNotBlank(file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsNotBlank(file: file, line: line)
    }

    func thisContains(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisContains(expected, file: file, line: line)
    }

    func thisContainsNot(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisContainsNot(expected, file: file, line: line)
    }

    func thisStartsWith(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisStartsWith(expected, file: file, line: line)
    }

    func thisStartsWithNot(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisStartsWithNot(expected, file: file, line: line)
    }

    func thisEndsWith(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisEndsWith(expected, file: file, line: line)
    }

    func thisEndsWithNot(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisEndsWithNot(expected, file: file, line: line)
    }

    func thisMatches(_ pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisMatches(pattern, file: file, line: line)
    }

    func thisMatchesNot(_ pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisMatchesNot(pattern, file: file, line: line)
    }

    func thisMatchesDateFormat(_ format: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisMatchesDateFormat(format, file: file, line: line)
    }

    func thisIsGreaterThan(_ other: Double, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsGreaterThan(other, file: file, line: line)
    }

    func thisIsGreaterThanOrEqual(_ other: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsGreaterThanOrEqual(other, file: file, line: line)
    }

    func thisIsLessThan(_ other: Double, file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsLessThan(other, file: file, line: line)
    }

    func thisIsLessThanOrEqual(_ other: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        anyValue.thisIsLessThanOrEqual(other, file: file, line: line)
    }
}
