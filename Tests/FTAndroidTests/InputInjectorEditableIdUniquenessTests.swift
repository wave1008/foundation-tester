// resource-id は画面内で一意とは限らない(Google マップの時刻ピッカーで時/分の EditText が
// 同じ short id を持つ)。InputInjector.findEditable が「最初の一致で即採用」に戻ると、
// ref で指した欄とは別の欄が操作される。ソース走査でこの退行を止める。

import XCTest

final class InputInjectorEditableIdUniquenessTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAndroidTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    private func inputInjectorSource() throws -> String {
        let path = repoRoot.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// クラス直下([Character] を `{`/`}` の深さで追跡し、深さ 1→2 の区間だけを切り出す)の
    /// メソッド本文を全部返す。メソッド名の変更・シグネチャの改行に影響されない。
    private func classLevelBlockBodies(_ source: String) -> [String] {
        let chars = Array(source)
        var depth = 0
        var bodyStart: Int?
        var bodies: [String] = []
        for i in 0..<chars.count {
            switch chars[i] {
            case "{":
                depth += 1
                if depth == 2 { bodyStart = i + 1 }
            case "}":
                if depth == 2, let start = bodyStart {
                    bodies.append(String(chars[start..<i]))
                    bodyStart = nil
                }
                depth -= 1
            default:
                break
            }
        }
        return bodies
    }

    /// id 一致経路(editableById 相当)は「一致件数を数えて一意でなければ座標へ落とす」形で
    /// なければならない。**最初の一致で return する**旧実装(バグ)に戻ったら落ちる。
    func testIdMatchingWalkDoesNotReturnOnFirstHit() throws {
        let source = try inputInjectorSource()
        let bodies = classLevelBlockBodies(source)
        guard let idWalkBody = bodies.first(where: { $0.contains("getViewIdResourceName(") }) else {
            return XCTFail("resource-id を読む走査本体が見つからない(getViewIdResourceName 呼び出し)")
        }
        // 旧バグの構造: マッチしたら node を即 return する。復活したらここで検出する。
        XCTAssertFalse(idWalkBody.contains("return node;"),
                       "id 一致の走査が最初の一致で即 return している(一意性を見ない旧実装に戻っている)")
        XCTAssertTrue(idWalkBody.range(of: #"\.add\(\s*node\s*\)"#, options: .regularExpression) != nil,
                      "id 一致の走査が候補を集める形になっていない(matches への追加が見当たらない)")
    }

    /// id 経由の解決(findEditable 相当)は一致がちょうど1件のときだけ id をそのまま採用し、
    /// **複数一致は ref の座標で選び分け**、0件は座標フォールバック(editableAt)へ落ちること。
    func testResolverFallsBackToCoordinatesUnlessExactlyOneMatch() throws {
        let source = try inputInjectorSource()
        let bodies = classLevelBlockBodies(source)
        guard let resolverBody = bodies.first(where: {
            $0.contains("shortId != null") && $0.contains("editableAt(root, x, y, tmp)")
        }) else {
            return XCTFail("id 優先→座標フォールバックの解決本体が見つからない(findEditable 相当)")
        }
        XCTAssertTrue(resolverBody.range(of: #"\.size\(\)\s*==\s*1"#, options: .regularExpression) != nil,
                      "一致件数が「ちょうど1件」かを見ていない(2件以上でも id を採用してしまう)")
        // 座標フォールバックが id 判定の外側(この関数の最終手段)として残っていること。
        XCTAssertTrue(resolverBody.contains("return editableAt(root, x, y, tmp);"),
                      "id が一意でないときに座標へ落ちる経路が見当たらない")
        // **複数一致の枝は必ず ref の点を使う**: ここが「先頭を採る」に戻ると、ref で指した欄と
        // 別の欄を操作する元のバグに戻る。点を渡していない = 位置で選び分けていない
        let multi = resolverBody.split(separator: "\n")
            .first { $0.range(of: #"\.size\(\)\s*[>!]=?\s*1"#, options: .regularExpression) != nil
                && $0.contains("return") }
        guard let multi else {
            return XCTFail("複数一致(size() > 1)の枝が見当たらない: \(resolverBody)")
        }
        XCTAssertTrue(multi.contains("x, y"),
                      "複数一致の枝が ref の座標を渡していない(先頭を採る形に戻っていないか): \(multi)")
    }

    /// 全角読点混入の退行ガード(下のテストで一般化して掃討済みだが、実害箇所は名指しで固定する)。
    func testErrorMessagesUseAsciiPunctuation() throws {
        let source = try inputInjectorSource()
        XCTAssertFalse(source.contains("lastState + \"、\""),
                       "エラーメッセージ(英文)に全角読点が残っている")
    }

    /// AndroidRunner/src 配下の全 .java ファイルの**文字列リテラル中**に全角文字(仮名・漢字・
    /// 全角記号)が無いこと。コメント(// と /* */)は対象外。誤検知を避けるため、対象は
    /// 「クラス直下のブロック本文」に限らずファイル全文を単純な状態機械でコメント除去してから見る。
    func testNoFullWidthCharactersInStringLiteralsAcrossAndroidRunnerSources() throws {
        let sourcesDir = repoRoot.appendingPathComponent("AndroidRunner/src")
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesDir, includingPropertiesForKeys: nil) else {
            return XCTFail("AndroidRunner/src を列挙できない")
        }
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "java" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (lineNumber, codeOnly) in codeWithCommentsStripped(text) {
                for scalar in codeOnly.unicodeScalars where isFullWidth(scalar) {
                    offenders.append("\(file.lastPathComponent):\(lineNumber): \(codeOnly)")
                    break
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "文字列リテラル中に全角文字が残っている(コメントは対象外): \(offenders)")
    }

    /// 全角(かな・漢字・全角記号・全角英数)判定。半角カナは対象に含めない(このリポジトリでは
    /// エラーメッセージ英文中に混ざる想定が無いため)。
    private func isFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3000...0x303F).contains(v)   // 全角記号(句読点・括弧等)
            || (0x3040...0x30FF).contains(v)   // ひらがな・カタカナ
            || (0x4E00...0x9FFF).contains(v)   // 漢字
            || (0xFF00...0xFFEF).contains(v)   // 全角英数・記号
    }

    /// `//` 行コメントと `/* */` ブロックコメントを取り除いた行を `(行番号, コード部分)` で返す
    /// 簡易パーサ。文字列リテラル内の `//`/`/*` は考慮しない(このリポジトリのソースには
    /// 該当が無く、誤って剥がしても全角検出の対象が広がるだけで見逃しにはならない)。
    private func codeWithCommentsStripped(_ source: String) -> [(Int, String)] {
        var result: [(Int, String)] = []
        var inBlockComment = false
        for (offset, line) in source.components(separatedBy: "\n").enumerated() {
            let chars = Array(line)
            var out = ""
            var i = 0
            while i < chars.count {
                if inBlockComment {
                    if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "/" {
                        inBlockComment = false
                        i += 2
                    } else {
                        i += 1
                    }
                    continue
                }
                if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" {
                    inBlockComment = true
                    i += 2
                    continue
                }
                if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "/" {
                    break
                }
                out.append(chars[i])
                i += 1
            }
            result.append((offset + 1, out))
        }
        return result
    }
}
