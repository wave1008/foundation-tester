// CLI の表示文字列は英語だけ(ユーザー決定 2026-07-30。切替機構は入れない)。
// コメント・docs・SKILL.md・拡張 UI は日本語のままで、ここが縛るのは **Sources/ の文字列リテラル**だけ。
// コンパイルでは落ちない誤りで、実際に一度戻った(AndroidWebViewUpdate が
// `fleetest run` のログへ日本語を5行出していた)ので走査で落とす。
//
// 日本語を**正しく持つ**ファイルは下の表に理由付きで載せる。載っていないファイルに日本語の
// リテラルを書いたらここで落ちる —— 新しい表示文字列は英語で書き、どうしても日本語が要るなら
// 理由を表へ足す。

import Foundation
import XCTest

final class CLIEnglishStringsScanTests: XCTestCase {

    /// 日本語のリテラルを持ってよいファイル(前方一致)と、その理由。
    private static let exempt: [(prefix: String, reason: String)] = [
        ("Sources/FTTestSupport/",
         "保守者だけが見る precondition / throw の文言(利用者の CLI 出力ではない)"),
        ("Sources/FTDSL/StepDescription.swift",
         "ステップ説明は per-step の isJapanese 判定で日英を作り分ける"),
        ("Sources/FTDSL/ScenarioDraftCodeGen.swift",
         "日本語のテストベースを読むための語彙表(入力の照合であって表示ではない)"),
        ("Sources/FTCore/TestbaseOutline.swift",
         "同上(見出し語の照合表)"),
        ("Sources/FTFoundationModels/TestbaseDrafter.swift",
         "@Guide の description が FM の出力言語を決める(instructions では決まらない)"),
        ("Sources/FTFoundationModels/ScenarioNamer.swift",
         "同上"),
        ("Sources/FTCore/ProjectScaffold.swift",
         "新規プロジェクトへ書き出す日本語の見本シナリオ(生成物)"),
        ("Sources/FTCore/ScenarioCodeGen.swift",
         "生成するシナリオの本文(内容由来 = 入力に追従)"),
        ("Sources/fleetest/ApiGenScenarioCommand.swift",
         "生成するシナリオの既定クラス名(生成物)"),
        ("Sources/FTCore/CommandIndex.swift",
         "DSL の signature に載せる日本語の使用例"),
        ("Sources/FTCore/PackageManifestEditor.swift",
         "受け手の Package.swift へ書き込むマーカー(既存のファイルに実在するので変えられない)"),
        ("Sources/FTCore/BridgeSourceSet.swift",
         "versionConstantHint の読み手は BridgeContractTests の失敗文言(保守者向け)"),
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // 仮名と漢字だけ。**中黒 U+30FB は除く** —— 英語の出力でも箇条書きに使っている
            (0x3041...0x3096).contains(scalar.value)          // ひらがな
                || (0x30A1...0x30FA).contains(scalar.value)   // カタカナ(中黒より前)
                || (0x4E00...0x9FFF).contains(scalar.value)   // 漢字
        }
    }

    /// 行からコメント部分を落として、残った二重引用符の中身だけを返す。
    /// `//` が文字列の内側(URL など)にあるときに切らないよう、引用符の状態を見ながら走る。
    static func quotedText(inCodeOf line: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        var previous: Character?
        for character in line {
            if escaped { if inString { current.append(character) }; escaped = false; previous = character; continue }
            if character == "\\" { escaped = true; previous = character; continue }
            if character == "\"" {
                if inString { literals.append(current); current = "" }
                inString.toggle()
                previous = character
                continue
            }
            if !inString, character == "/", previous == "/" { break }  // 行コメントの開始
            if inString { current.append(character) }
            previous = character
        }
        return literals
    }

    private struct Hit { let file: String; let line: Int; let text: String }

    private static func scan() -> [Hit] {
        let root = repoRoot
        let sources = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var hits: [Hit] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if exempt.contains(where: { relative.hasPrefix($0.prefix) }) { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                for literal in quotedText(inCodeOf: String(line)) where containsCJK(literal) {
                    hits.append(Hit(file: relative, line: index + 1, text: literal))
                }
            }
        }
        return hits
    }

    func testSourcesHaveNoJapaneseStringLiterals() {
        let hits = Self.scan()
        let report = hits.map { "\($0.file):\($0.line)  \"\($0.text)\"" }.joined(separator: "\n")
        XCTAssertTrue(hits.isEmpty,
                      "CLI の表示文字列は英語だけ(ユーザー決定 2026-07-30)。"
                      + "日本語のリテラルが \(hits.count) 件ある:\n\(report)\n"
                      + "正しく日本語を持つファイルなら CLIEnglishStringsScanTests.exempt へ理由付きで足す")
    }

    /// 走査そのものが効いていること(除外表が全部を飲み込んでいないか)。
    /// **Sources 配下の .swift を1本でも読めていれば良い** —— 0 件なら走査が空振りしている
    func testScanReachesSources() {
        let root = Self.repoRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return XCTFail("Sources/ を列挙できない") }
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(Self.repoRoot.path.count + 1))
            if Self.exempt.contains(where: { relative.hasPrefix($0.prefix) }) { continue }
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 100, "Sources/ の .swift をほとんど除外している")
    }

    /// 行コメントの切り出しが文字列の中の `//` を誤って切らないこと(URL を含む行で実害が出る)
    func testQuotedTextKeepsSlashesInsideStrings() {
        XCTAssertEqual(Self.quotedText(inCodeOf: #"let url = "http://example.com/x"  // 説明"#),
                       ["http://example.com/x"])
        XCTAssertEqual(Self.quotedText(inCodeOf: #"log("あ")"#), ["あ"])
        XCTAssertEqual(Self.quotedText(inCodeOf: #"// log("あ")"#), [])
    }
}
