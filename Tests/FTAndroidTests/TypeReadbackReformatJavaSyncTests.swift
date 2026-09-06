// Android ブリッジの /type 適用確認(InputInjector.applied)の形を固定する。
// 読み返しの目的は「ACTION_SET_TEXT が受理されたが反映されていない」の検出なので、
// **SET_TEXT 前の読み(before)から値が変わっていれば反映の証拠**として通す ——
// 電話番号の整形・AllCaps・maxLength・桁区切りのように書いた文字列をそのまま返さない欄は、
// 完全一致だけだと入っているのに 4 秒待って 500 になっていた(その間の reconnectInput が
// IME 越しに BACK まで撃つ)。マスク欄(パスワード)は読めないので長さ一致のまま・空の読み返しは
// 整形ではなくアプリが欄を消した形なので通さない(docs/design.md §Android のテキスト注入の規律)。

import XCTest

final class TypeReadbackReformatJavaSyncTests: XCTestCase {

    private var injectorSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("AndroidRunner/src/com/example/ftbridge/InputInjector.java")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// コメントを除いたコード行(Javadoc の `*` 行と `//` 以降を落とす)
    private func codeLines(_ source: String) -> [String] {
        source.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return nil }
            return line.components(separatedBy: "//")[0]
        }
    }

    private func body(of function: String, in source: String) throws -> String {
        guard let start = source.range(of: "static \(function)") else {
            throw XCTSkip("\(function) が見つからない")
        }
        return String(source[start.upperBound...].prefix(600))
    }

    /// applied は (current, combined, masked, before) の4引数で、規則3つを持つ
    func testAppliedAcceptsChangedValueButKeepsMaskedAndEmptyRules() throws {
        let source = try injectorSource
        let applied = try body(of: "boolean applied(String current, String combined, boolean masked, String before)",
                               in: source)
        XCTAssertTrue(applied.contains("if (combined.equals(current)) return true;"), "完全一致は従来どおり通す")
        XCTAssertTrue(applied.contains("if (masked) return current.length() == combined.length();"),
                      "マスク欄は長さ一致だけ(変化で通すと伏せ字の読みに騙される)")
        XCTAssertTrue(applied.contains("return !current.isEmpty() && !current.equals(before);"),
                      "非マスク欄は before から変わっていれば通す・空の読み返しは通さない")
    }

    /// 両方の type 経路が before を渡し、combined を作る場所で before を控えている
    func testBothTypePathsPassTheBeforeReadToApplied() throws {
        let code = codeLines(try injectorSource).joined(separator: "\n")
        let appliedCalls = code.components(separatedBy: "applied(current, combined, masked, before)").count - 1
        XCTAssertEqual(appliedCalls, 2, "setTextAppendingAt / setTextAppending の2経路が before 付きで呼ぶ")
        XCTAssertEqual(code.components(separatedBy: "applied(current, combined, masked)").count - 1, 0,
                       "before 無しの旧形が残っている")
        XCTAssertEqual(code.components(separatedBy: "before = current;").count - 1, 2,
                       "before は combined を作る読み(1回だけ)から控える —— 追加の読みを足さない")
        XCTAssertEqual(code.components(separatedBy: "combined = current + text;").count - 1, 2)
    }

    /// 「変わったが完全一致ではない」で通した回は logcat に残す(/type の応答 JSON は増やさない)
    func testReformattedAcceptanceIsLoggedNotReturned() throws {
        let source = try injectorSource
        let log = try body(of: "void logReformatted(String current, String combined, boolean masked)", in: source)
        XCTAssertTrue(log.contains("if (masked || combined.equals(current)) return;"))
        XCTAssertTrue(log.contains("the field reformatted the text: read back"))
        XCTAssertEqual(codeLines(source).joined(separator: "\n")
                           .components(separatedBy: "logReformatted(current, combined, masked);").count - 1, 2,
                       "両 type 経路が通した直後に呼ぶ")
    }
}
