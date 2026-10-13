// ReplayDelegate の「既定実装に黙って落ちる」型を2方向から塞ぐ。
//
// ① **既定実装はプロトコル要件としても宣言する**。存在型(`let delegate: ReplayDelegate`)越しの
//    呼び出しは、要件なら witness table 経由で実装へ、要件でなければ**静的ディスパッチで
//    extension の既定実装へ**落ちる = 実装しても呼ばれないまま既定値が返る
//    (AppDriver で実際に踏んだ型。AppDriverDefaultDispatchTests と同じ規律)。
// ② **転送デリゲート(`LazyFMDelegate`)は全要件を転送する**。1つ忘れると、その機能だけが
//    既定実装(nil / no-op)に落ちて黙って無効になる。ソースにも「転送しないと素通りする」と
//    書いてあるが、書いてあるだけでは守れない —— 実際に要件を足したとき、
//    転送を書かなければその要件は1度も FM へ届かなかった。

import XCTest

final class ReplayDelegateDispatchTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// `func <name>(` の <name> を集める(コメント行は落とす)
    private func functionNames(in block: String) -> Set<String> {
        var names: Set<String> = []
        for raw in block.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//") else { continue }
            guard let range = line.range(of: #"\bfunc [A-Za-z_][A-Za-z0-9_]*\("#,
                                         options: .regularExpression) else { continue }
            let decl = line[range].dropFirst("func ".count).dropLast()
            names.insert(String(decl))
        }
        return names
    }

    /// `needle` から始まるブロックを中括弧の対応で切り出す
    private func block(after needle: String, in source: String) -> String? {
        guard let found = source.range(of: needle),
              let open = source[found.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    func testEveryDefaultImplementationIsAlsoAProtocolRequirement() throws {
        let source = try source("Sources/FTCore/StepExecutor.swift")
        let requirements = functionNames(
            in: try XCTUnwrap(block(after: "public protocol ReplayDelegate", in: source)))
        let defaults = functionNames(
            in: try XCTUnwrap(block(after: "public extension ReplayDelegate", in: source)))
        XCTAssertFalse(defaults.isEmpty, "既定実装が1つも読めていない = 走査が壊れている")
        XCTAssertTrue(defaults.isSubset(of: requirements),
                      "既定実装だけにあるメンバ \(defaults.subtracting(requirements).sorted()) —— "
                      + "プロトコル要件にも宣言しないと存在型越しの呼び出しが既定実装へ落ちる")
    }

    func testLazyFMDelegateForwardsEveryRequirement() throws {
        let core = try source("Sources/FTCore/StepExecutor.swift")
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        let requirements = functionNames(
            in: try XCTUnwrap(block(after: "public protocol ReplayDelegate", in: core)))
        let forwarded = functionNames(
            in: try XCTUnwrap(block(after: "final class LazyFMDelegate", in: runner)))
        XCTAssertGreaterThanOrEqual(requirements.count, 2,
                                    "要件が2つ未満しか見えていない = 走査が壊れている")
        XCTAssertTrue(requirements.isSubset(of: forwarded),
                      "LazyFMDelegate が転送していない要件 \(requirements.subtracting(forwarded).sorted()) —— "
                      + "既定実装(nil / no-op)に落ちて、その機能だけが黙って無効になる")
    }
}
