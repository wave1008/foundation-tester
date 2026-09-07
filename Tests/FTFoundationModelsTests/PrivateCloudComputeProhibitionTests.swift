// PCC(Private Cloud Compute)へのアクセスは完全に禁止(ユーザー決定 2026-09-07)。
//
// FoundationModels は macOS 27 SDK で **オンデバイスと PCC の2つのモデル型**を持つ:
//   SystemLanguageModel                 … オンデバイス。本ツールが使う唯一のモデル
//   PrivateCloudComputeLanguageModel    … Apple のクラウドで動く別バリアント(32K ctx)
// 後者を使うとアプリの画面情報が Mac の外へ出る。受け手向けドキュメント
// (docs/user-docs/overview/environments.md / about.md と各 _ja)が「画面情報は Mac の外に
// 出ない」と断定しているので、これは表現ではなく**守るべき不変条件**。
//
// **この走査が門として完全な理由**: PCC のセッションは `PrivateCloudComputeLanguageModel` を
// 名指ししないと作れない(`@_hasMissingDesignatedInitializers` の final class で、
// 型名を書かずにインスタンスを得る経路が無い)。よって Sources からこの1語を締め出せば経路は閉じる。
// 規則②は「明示的にモデルを渡す」形そのものを止める二重の備え。
//
// 守っているのは型ではなく **`LanguageModelSession` の init の既定値**である点に注意:
//   init(model: SystemLanguageModel = .default, …)   ← `model:` を省くとこちらに束縛される
//   init(model: some LanguageModel, …)               ← **既定値が無い**ので明示しないと選べない
// つまり `model:` を渡さない限りオンデバイスに落ちる。逆に言えば `model:` を1つ書くだけで
// クラウドへ出られるので、機械で止める。

import Foundation
import XCTest

final class PrivateCloudComputeProhibitionTests: XCTestCase {

    /// 規則②(明示的な `model:`)の免除。**空のまま維持する**。
    /// 既定以外の `SystemLanguageModel`(`useCase:` 違い等)が必要になったときだけ、
    /// 「PCC ではない」ことを確かめた上でここへ相対パスを足す。
    private static let explicitModelExempt: Set<String> = []

    private struct Hit {
        let file: String
        let line: Int
        let text: String
    }

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FTFoundationModelsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources")
    }

    /// 行コメント(`//`)より右は落とす —— 禁止の由来を doc コメントに書けるようにするため。
    /// コメントは何も呼ばないので、門の強度は落ちない
    private static func stripComment(_ line: String) -> String {
        line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
    }

    /// Sources 配下の .swift を1行ずつ、コメントを落として述語に掛ける
    private static func scan(_ matches: (_ relativePath: String, _ code: String) -> Bool) -> [Hit] {
        let root = sourcesRoot
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var found: [Hit] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            guard url.pathExtension == "swift" else { continue }
            let relative = "Sources" + url.path.dropFirst(root.path.count)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, substring) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(substring)
                let code = stripComment(line)
                guard matches(relative, code) else { continue }
                found.append(Hit(file: relative, line: index + 1,
                                 text: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return found
    }

    // MARK: 規則① PCC のモデル型を名指ししない

    func testPrivateCloudComputeModelTypeIsNeverNamedInSources() {
        let offenders = Self.scan { _, code in code.contains("PrivateCloudComputeLanguageModel") }
        XCTAssertTrue(offenders.isEmpty, """
            PCC(Private Cloud Compute)は完全に禁止 —— アプリの画面情報が Mac の外へ出る。
            FM はオンデバイスの SystemLanguageModel だけを使うこと。
            \(offenders.map { "\($0.file):\($0.line) \($0.text)" }.joined(separator: "\n"))
            """)
    }

    // MARK: 規則② セッションにモデルを明示的に渡さない

    /// `LanguageModelSession(model: …)`。改行を挟んで書かれても拾えるよう、
    /// 行単位ではなくファイル全体を空白正規化してから当てる
    private static let explicitModelPattern =
        try! NSRegularExpression(pattern: #"LanguageModelSession\s*\(\s*model\s*:"#)

    func testSessionsNeverPassAnExplicitModel() {
        let root = Self.sourcesRoot
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return XCTFail("Sources を走査できなかった") }
        var offenders: [String] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            guard url.pathExtension == "swift" else { continue }
            let relative = "Sources" + url.path.dropFirst(root.path.count)
            if Self.explicitModelExempt.contains(relative) { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { Self.stripComment(String($0)) }
                .joined(separator: " ")
            let ns = code as NSString
            let matches = Self.explicitModelPattern.matches(
                in: code, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty { offenders.append(relative) }
        }
        XCTAssertTrue(offenders.isEmpty, """
            `LanguageModelSession` にモデルを明示的に渡さない —— `model:` を省くと
            既定値 `SystemLanguageModel.default`(オンデバイス)に束縛される。明示する形は
            PCC への差し替えと1語しか違わないので置かない。
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: 陰性の担保

    /// 走査そのものが生きていること(Sources を1件も読めていないと、上の2本は空集合で
    /// 素通りする)。**「常に空を返す」変異と区別できないテストを置かない**
    func testTheScanActuallyReadsTheSources() {
        let sessions = Self.scan { _, code in code.contains("LanguageModelSession(") }
        XCTAssertGreaterThanOrEqual(sessions.count, 8, """
            FM のセッション生成が1つも見つからない = 走査が Sources に届いていない。
            禁止テストが素通りしている可能性がある
            """)
    }
}
