// **assert を持たず print で結果を出すテストは、環境変数で門番する**。
//
// この型は2つ壊れる: ①`swift test --parallel` はテストプロセスを分けるので、通常スイートに
// 混ざった print は他のテストの出力と混ざり帰属が消える ②assert が無い = **破っても落ちない**ので、
// テストとしては毎回コストだけ払う置物になる(観測は「走らせたいときに走らせる」道具であって、
// スイートの一員ではない)。
//
// 既存の観測用テストはすべて `ProcessInfo.processInfo.environment` を見て自分から降りる
// (`FT_SWEEP_DIR` / `FT_NOTE_COVERAGE` / `FT_OCR_BAND_SWEEP` 等)。この規律を機械で守る。
//
// **`print` そのものは禁止していない** —— assert を持つテストが失敗時の手掛かりを添えるのは
// 既存の慣行(Tests 全体で数十箇所)で、混ぜて禁じると意味のある診断まで消える。
// ここが捕まえるのは「assert が無い」かつ「門番が無い」の**両方**が成り立つ関数だけ。

import Foundation
import XCTest

final class UngatedPrintOnlyTestSourceScanTests: XCTestCase {

    private static let assertish = try! NSRegularExpression(
        pattern: #"XCTAssert|XCTFail|XCTUnwrap|#expect"#)
    /// 自分から降りる門番。`XCTSkip` を投げる形と、`guard … else { return }` の形の両方を許す
    private static let gate = try! NSRegularExpression(
        pattern: #"ProcessInfo\.processInfo\.environment|XCTSkip"#)
    private static let funcHead = try! NSRegularExpression(pattern: #"^\s*func (test\w+)"#)

    private struct Hit { let file: String; let line: Int; let name: String }

    private static var testsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// 関数本体を波括弧の釣り合いで切り出す(ネストした閉包を含めて1関数ぶんを見る)
    private static func scan() -> [Hit] {
        guard let walker = FileManager.default.enumerator(
            at: testsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var found: [Hit] = []
        for case let url as URL in walker {
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = "Tests" + url.path.dropFirst(testsRoot.path.count)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var i = 0
            while i < lines.count {
                let head = lines[i] as NSString
                guard let m = funcHead.firstMatch(
                    in: lines[i], range: NSRange(location: 0, length: head.length))
                else { i += 1; continue }
                let name = head.substring(with: m.range(at: 1))
                var depth = 0, started = false, j = i
                var body: [String] = []
                while j < lines.count {
                    depth += lines[j].filter { $0 == "{" }.count
                    depth -= lines[j].filter { $0 == "}" }.count
                    body.append(lines[j])
                    if lines[j].contains("{") { started = true }
                    if started && depth <= 0 { break }
                    j += 1
                }
                let text = body.joined(separator: "\n")
                if text.contains("print(") && !matches(assertish, text) && !matches(gate, text) {
                    found.append(Hit(file: relative, line: i + 1, name: name))
                }
                i = j + 1
            }
        }
        return found
    }

    private static let hits: [Hit] = scan()

    func testPrintOnlyTestsDeclareAnEnvironmentGate() {
        XCTAssertTrue(Self.hits.isEmpty, """
            assert を持たず print で結果を出すテストは、環境変数で門番して通常スイートから降ろすこと
            (--parallel では出力が混ざって帰属が消え、assert が無いので破っても落ちない)。
            観測が要るなら結果はファイルへ書き、`ProcessInfo.processInfo.environment` で起こす。
            \(Self.hits.map { "\($0.file):\($0.line) \($0.name)" }.joined(separator: "\n"))
            """)
    }

    /// 走査が Tests に届いていること(0件で素通りする変異と区別できないテストを置かない)
    func testTheScanActuallyReadsTheTests() {
        let root = Self.testsRoot
        var swiftFiles = 0
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" { swiftFiles += 1 }
        }
        XCTAssertGreaterThan(swiftFiles, 100, "Tests 配下を走査できていない")
    }
}
