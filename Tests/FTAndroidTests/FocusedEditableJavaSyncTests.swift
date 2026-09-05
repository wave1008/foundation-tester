// Android ブリッジの「入力フォーカスを持つ欄」の選び方を1箇所に固定する。
// `findFocus(FOCUS_INPUT)` は Flutter で半分の確率でフォーカス中の欄でなく FlutterView の入れ物
// (FrameLayout・editable=false)を返す(実機 Pixel 4a・2026-09-06 の logcat プローブ。10 周中 5 周)。
// 入れ物に SET_TEXT / ACTION_IME_ENTER を撃てば拒否、「空」と読めば黙って成功になるので、
// フォーカス欄を使う経路(ref なしの clear / type / IME Enter)は `focusedEditable`
// (編集可能でなければ木から isFocused && isEditable を探す)を通す。
// **新しい経路が素の findFocus を書いたら落ちる**(docs/design.md §Android のテキスト注入の規律)。

import XCTest

final class FocusedEditableJavaSyncTests: XCTestCase {

    private var injectorSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("AndroidRunner/src/com/example/ftbridge/InputInjector.java")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// コメントを除いたコード行の中で `findFocus(` は focusedEditable の中の1回だけ
    func testFindFocusIsCalledOnlyInsideFocusedEditable() throws {
        let lines = try injectorSource.components(separatedBy: "\n")
        var callers: [String] = []
        var currentFunction = ""
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }  // Javadoc
            let code = line.components(separatedBy: "//")[0]
            if let range = code.range(of: #"static \w[\w<>\[\]]* (\w+)\("#, options: .regularExpression) {
                let signature = String(code[range])
                currentFunction = signature.split(separator: " ").last.map { String($0.dropLast()) } ?? ""
            }
            if code.contains("findFocus(") {
                callers.append("\(currentFunction)@\(index + 1)")
            }
        }
        XCTAssertEqual(callers.count, 1, "findFocus の呼び出しは focusedEditable の1箇所だけのはず: \(callers)")
        XCTAssertTrue(callers.first?.hasPrefix("focusedEditable@") ?? false, callers.description)
    }

    /// フォーカス欄を使う3経路が focusedEditable を通っている
    func testEveryFocusedFieldPathUsesFocusedEditable() throws {
        let source = try injectorSource
        for function in ["clearFocused", "setTextAppending(", "pressImeEnter"] {
            guard let start = source.range(of: "static void \(function)") else {
                return XCTFail("\(function) が見つからない")
            }
            let body = source[start.upperBound...].prefix(2500)
            XCTAssertTrue(body.contains("focusedEditable(root)"), "\(function) が focusedEditable を通っていない")
        }
    }
}
