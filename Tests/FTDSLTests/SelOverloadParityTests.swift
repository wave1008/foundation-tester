// セレクタを取るトップレベルコマンドは **String 版と Sel 版が1対1**(design.md §10「型付きセレクタ」)。
// 片方だけ足すと「型付き経路を選ぶと機能が減る」状態になり、生成側を Sel 既定に寄せられなくなる。
//
// `SelTests` は個別ケースの列挙なので、**String 版だけ足しても落ちない**(構文ごとの等価は見るが、
// コマンドの集合は見ない)。ここはソース走査で集合一致を固定する
// (FTElement のチェーン側は vscode-ftester/test/ftElementChainSync.test.mjs が同じ役割)。

import XCTest

final class SelOverloadParityTests: XCTestCase {

    /// **セレクタを取らない**のに String を取るコマンド。ここに載っていない新しい String 引数の
    /// コマンドは「Sel 版を忘れた」として落とす(分類を意識的に迫るための一覧)
    private static let nonSelectorStringCommands: Set<String> = [
        "appIs",            // アプリ ID(ニックネーム機構は持たない)
        "clearAppData", "installApp", "launchApp", "removeApp", "restartApp",  // bundleID / パス
        "openURL",          // ディープリンクの URL
        "tapAppIcon",       // アプリ表示名
        "screenshot",       // ファイル名
        "screenIs",         // 画面の説明文(FM の視覚照合)
        "group", "procedure", "scene", "verify", "doUntilTrue",  // 記録用のタイトル・説明
    ]

    /// **検証コマンド**(2026-08-04 以降): String を取るが**期待値であってセレクタではない**
    /// (対象は直前に掴んだ要素 = 暗黙の lastElement)。Sel 版は要らない —— 対象を指すのは
    /// `select` 側で、そちらに Sel 版がある(セレクタを取る形は置かない)
    private static let expectedValueStringCommands: Set<String> = [
        "textIs", "textIsNot", "textContains", "textContainsNot",
        "textStartsWith", "textStartsWithNot", "textEndsWith", "textEndsWithNot",
        "textMatches", "textMatchesNot", "textMatchesDateFormat",
        "valueIs", "valueIsNot", "valueContains", "valueContainsNot",
        "valueStartsWith", "valueStartsWithNot", "valueEndsWith", "valueEndsWithNot",
        "valueMatches", "valueMatchesNot", "valueMatchesDateFormat",
        "idIs",
    ]

    /// **承認済みの差分**(ユーザー決定 2026-08-04・**再提案しない**): `scrollFrame:`
    /// (スクロール領域のセレクタ式)は String 固定で Sel 版を持たない。1対1を保証するのは
    /// **対象セレクタ**まで(`scrollTo` の Sel 版でも `scrollFrame:` は String のまま)。
    /// 一覧が増減したらここを更新する — **Sel 版を足す判断ではなく**、コマンドの増減の追随
    private static let scrollFrameStringOnlyCommands: Set<String> = [
        "scrollDown", "scrollUp", "scrollLeft", "scrollRight",
        "scrollToBottom", "scrollToTop", "scrollToRightEdge", "scrollToLeftEdge",
        "withScrollDown", "withScrollUp", "withScrollLeft", "withScrollRight",
        "flickCenterToTop", "flickCenterToBottom", "flickCenterToLeft", "flickCenterToRight",
        "flickLeftToRight", "flickRightToLeft", "flickBottomToTop", "flickTopToBottom",
    ]

    private struct Declaration {
        let name: String
        let signature: String
    }

    /// 行頭 `public func` から行頭 `}` までを1宣言として切り出す(FTElement 等のメンバは
    /// インデントされているので拾わない = トップレベルの自由関数だけが対象)
    private func declarations() throws -> [Declaration] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTDSLTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("Sources/FTDSL/Commands.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        var found: [Declaration] = []
        var current: [String]?
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("public func ") {
                current = [String(line)]
            } else if current != nil {
                current?.append(String(line))
                if line == "}" {
                    let block = current!.joined(separator: "\n")
                    current = nil
                    let rest = block.dropFirst("public func ".count)
                    guard let paren = rest.firstIndex(of: "("),
                          let brace = block.firstIndex(of: "{") else { continue }
                    found.append(Declaration(name: String(rest[rest.startIndex..<paren]),
                                             signature: String(block[block.startIndex..<brace])))
                }
            }
        }
        return found
    }

    /// `名前: 型` の引数名を拾う(`file: StaticString` は `String` に一致しない)
    private func parameterNames(ofType type: String, in signature: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"([A-Za-z]+)\s*:\s*\#(type)\??\s*[,)\n=]"#)
        let range = NSRange(signature.startIndex..<signature.endIndex, in: signature)
        return Set(regex.matches(in: signature, range: range).compactMap { match in
            Range(match.range(at: 1), in: signature).map { String(signature[$0]) }
        })
    }

    /// String 版と Sel 版の集合が一致すること。**セレクタ引数の語彙は Sel 版から導く**ので、
    /// 引数名を増やしてもこのテスト自体は追随する(vocabulary を手で保守しない)
    func testSelectorCommandsHaveBothOverloads() throws {
        let declarations = try declarations()
        var selNames: Set<String> = []
        var selectorParameterNames: Set<String> = []
        for declaration in declarations {
            let selParams = try parameterNames(ofType: "Sel", in: declaration.signature)
            guard !selParams.isEmpty else { continue }
            selNames.insert(declaration.name)
            selectorParameterNames.formUnion(selParams)
        }
        XCTAssertFalse(selNames.isEmpty, "Sel 版が1つも見つからない(走査が壊れている)")

        var stringNames: Set<String> = []
        for declaration in declarations {
            let stringParams = try parameterNames(ofType: "String", in: declaration.signature)
            if !stringParams.isDisjoint(with: selectorParameterNames) {
                stringNames.insert(declaration.name)
            }
        }

        XCTAssertEqual(stringNames.subtracting(selNames), [],
                       "String 版だけがあるセレクタコマンド(Sel 版を足すこと)")
        XCTAssertEqual(selNames.subtracting(stringNames), [],
                       "Sel 版だけがあるセレクタコマンド(String 版を足すこと)")
    }

    /// String を取る全コマンドが「セレクタ」「セレクタでない(allowlist)」のどちらかに分類済みであること。
    /// 新しいコマンドを足したときに**分類を迫る**のが目的(セレクタなら Sel 版も要る)
    func testEveryStringCommandIsClassified() throws {
        let declarations = try declarations()
        let selNames = Set(try declarations.filter {
            !(try parameterNames(ofType: "Sel", in: $0.signature).isEmpty)
        }.map(\.name))

        var unclassified: Set<String> = []
        for declaration in declarations
        where !(try parameterNames(ofType: "String", in: declaration.signature).isEmpty) {
            let name = declaration.name
            guard !selNames.contains(name),
                  !Self.nonSelectorStringCommands.contains(name),
                  !Self.expectedValueStringCommands.contains(name),
                  !Self.scrollFrameStringOnlyCommands.contains(name) else { continue }
            unclassified.insert(name)
        }
        XCTAssertEqual(unclassified, [],
                       "String を取る未分類のコマンド。セレクタなら Sel 版を足し、"
                       + "そうでなければ nonSelectorStringCommands に登録すること")
    }

    /// 承認済みの差分(`scrollFrame:` は String 固定)が**そのまま**であること。
    /// Sel 版を足すと落ちる = 決定を破る変更に気付ける
    func testScrollFrameRemainsStringOnly() throws {
        for declaration in try declarations()
        where Self.scrollFrameStringOnlyCommands.contains(declaration.name) {
            XCTAssertTrue(
                try parameterNames(ofType: "String", in: declaration.signature).contains("scrollFrame"),
                "\(declaration.name) の scrollFrame が String でなくなった"
                + "(Sel 版を足したなら scrollFrameStringOnlyCommands から外す)")
        }
    }
}
