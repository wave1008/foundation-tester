// AppDriver の既定実装は**必ずプロトコル要件としても宣言する**ことを守る。
//
// Swift の存在型(`let driver: AppDriver`)越しの呼び出しは、プロトコル要件なら witness table 経由で
// 実装へ、要件でなければ**静的ディスパッチで extension の既定実装へ**落ちる。つまり
// extension にだけ足したメンバは、ドライバ側で実装しても**呼ばれないまま黙って既定値が返る**。
// テストは緑・ビルドも通るので、実機で挙動が出ないところまで気付けない
// (2026-08-01 に `snapshot(bypassingCache:)` で実際に踏んだ。Android が実装しているのに
// ホストから呼ぶと常に既定の素通しになり、キャッシュ捨てが一度も効かなかった)。
//
// 個々のメンバ名を列挙せず、**ソースから両ブロックの宣言を取り出して突き合わせる**。
// 新しい既定実装を足したときも自動的に対象になる。

import XCTest

final class AppDriverDefaultDispatchTests: XCTestCase {

    /// `func`/`var` の宣言を「`{` の手前まで」に正規化して取り出す
    /// (プロトコル側 `var x: T { get }` と extension 側 `var x: T { nil }` が同じ前置きになる)
    private func declarations(in block: String) -> [String] {
        var out: [String] = []
        // 改行をまたぐ宣言があるので空白を潰してから走査する
        let flat = block.split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
            .joined(separator: " ")
        // 宣言の開始位置を先に全部拾う(`{` を持たない要件が次の宣言まで飲み込むのを防ぐ)
        var starts: [String.Index] = []
        var cursor = flat.startIndex
        while let range = flat.range(of: #"\b(func|var) "#, options: .regularExpression,
                                     range: cursor..<flat.endIndex) {
            starts.append(range.lowerBound)
            cursor = range.upperBound
        }
        for (i, start) in starts.enumerated() {
            let hardEnd = i + 1 < starts.count ? starts[i + 1] : flat.endIndex
            let braceEnd = flat[start..<hardEnd].firstIndex(of: "{") ?? hardEnd
            let decl = flat[start..<braceEnd].trimmingCharacters(in: .whitespaces)
            if !decl.isEmpty { out.append(decl) }
        }
        return out
    }

    private func block(_ source: String, opening: String) throws -> String {
        guard let start = source.range(of: opening) else {
            throw XCTSkip("\(opening) が見つかりません(AppDriver.swift の構造が変わった)")
        }
        var depth = 0
        var end = start.upperBound
        for index in source.indices[start.lowerBound...] {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
        }
        return String(source[start.upperBound..<end])
    }

    func testEveryDefaultImplementationIsAlsoAProtocolRequirement() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        let path = root.appendingPathComponent("Sources/FTCore/AppDriver.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        let requirements = Set(declarations(in: try block(source, opening: "public protocol AppDriver {")))
        let defaults = declarations(in: try block(source, opening: "public extension AppDriver {"))

        XCTAssertFalse(requirements.isEmpty, "プロトコル要件を1つも取り出せていない(走査が壊れている)")
        XCTAssertFalse(defaults.isEmpty, "既定実装を1つも取り出せていない(走査が壊れている)")

        let orphans = defaults.filter { !requirements.contains($0) }
        XCTAssertTrue(orphans.isEmpty,
                      "既定実装だけあってプロトコル要件に無い(存在型越しの呼び出しが実装に届かない): "
                      + orphans.joined(separator: " / ")
                      + " —— AppDriver のプロトコル本体にも同じ宣言を足すこと")
    }
}
