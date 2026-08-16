// **MCP と DSL の全呼び出し元が KeyboardOcclusion を通ること**の配線ゲート(2026-08-14)。
// 型を keyboardFrame: FTRect? から keyboardOcclusion: KeyboardOcclusion へ変えるだけでは、
// 呼び出し側が `.none` を渡す・毎回新しい空の値を作るといった「実質何も除外しない」変異を
// コンパイラは止められない。ここは各ファイルのソースを読んで
// `KeyboardOcclusion.resolve(reported:` が実際にそのスナップショットから作られていることまで見る。

import XCTest

final class KeyboardOcclusionWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/FTesterMCPTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリ直下

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/" + relativePath),
                    encoding: .utf8)
    }

    /// 空白と改行を落とした形で照合する。**引数の改行位置に依存させない** ——
    /// 素のリテラル照合だと `resolve(\n    reported:` のような普通の折り返しで落ち、
    /// 配線ではなく整形を検査するテストになる(実際に落ちた)
    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// スナップショットから KeyboardOcclusion を組み立てる側の4箇所。**ft_double_tap
    /// (MCPServer+Dispatch.swift)も同じ被覆にする契約なので同列に含む**
    /// (RefGuard.keyboardWarning は呼び出し元から渡された値を転送するだけなので対象外)
    func testAllResolveSitesBuildKeyboardOcclusionFromTheSnapshot() throws {
        let sites = [
            "FTCore/StepExecutor+Actions.swift",
            "ftester-mcp/MCPServer+Snapshot.swift",
            "ftester-mcp/MCPServer+Hints.swift",
            "ftester-mcp/MCPServer+Dispatch.swift",
        ]
        for site in sites {
            let text = compact(try source(site))
            XCTAssertTrue(text.contains("KeyboardOcclusion.resolve(reported:"),
                          "\(site) が KeyboardOcclusion.resolve から作っていない"
                          + "(chrome 除外を持ち回らない生の keyboardFrame へ後退していないか)")
        }
    }

    /// RefGuard 側は`KeyboardOcclusion` を受け取って転送するだけ。生の `FTRect?` を
    /// keyboardFrame という名で受ける古いシグネチャへ戻っていないこと
    func testRefGuardKeyboardWarningTakesKeyboardOcclusionNotARawFrame() throws {
        let text = compact(try source("ftester-mcp/RefGuard.swift"))
        XCTAssertTrue(text.contains(compact("keyboardWarning(_ element: ElementInfo, keyboardOcclusion: KeyboardOcclusion)")),
                      "RefGuard.keyboardWarning が KeyboardOcclusion を受けていない")
        XCTAssertTrue(text.contains(compact("preTapWarnings(_ element: ElementInfo, keyboardOcclusion: KeyboardOcclusion)")),
                      "RefGuard.preTapWarnings が KeyboardOcclusion を受けていない")
    }

    /// `TapTargetGeometry.advisory` の keyboard 引数も KeyboardOcclusion であること
    /// (doubleTap の gestureAdvisory がここを通る唯一の経路)
    func testTapTargetGeometryAdvisoryTakesKeyboardOcclusion() throws {
        let text = try source("FTCore/TapTargetGeometry.swift")
        XCTAssertTrue(text.contains("keyboardOcclusion: KeyboardOcclusion = .none"),
                      "TapTargetGeometry.advisory が KeyboardOcclusion を既定引数に取っていない")
    }
}
