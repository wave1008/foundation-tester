// `ScenarioHost.run(scenarioTimeoutOverride:)` の呼び手は、実行するシナリオの `ScenarioInfo.scenarioTimeout`
// (= `@Test(scenarioTimeout:)`)を渡す。引数に既定値が無いので渡し忘れはコンパイルで止まるが、`nil` を
// 書いた呼び手は黙ってプロファイル → 既定へ落ち、`@Test` の指定が効かない(どのテストも緑のまま)。
// 一覧の info を持たない経路(クラス単位の tearDownDevice・ステップ一覧の dry-run)だけを理由付きで許す。

import Foundation
import XCTest

final class ScenarioTimeoutOverrideWiringTests: XCTestCase {

    /// Sources からの相対パス → nil を渡してよい理由
    private static let nilAllowed: [String: String] = [
        "FTCore/RunDeviceSession.swift": "tearDownDevice はクラス単位で、シナリオの info が無い",
        "FTCore/ScenarioHost.swift": "dryRunSteps はステップ一覧を出すだけでデバイスに触らない",
    ]

    func testEveryCallerPassesTheScenarioInfoValue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        var callers = 0
        var offenders: [String] = []
        var seenAllowed: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//")[0]
                // 宣言(`scenarioTimeoutOverride: Int?`)は呼び出しではない
                guard let range = code.range(of: "scenarioTimeoutOverride:"),
                      !code.contains("Int?") else { continue }
                let argument = code[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",)"))
                callers += 1
                if argument.hasSuffix(".scenarioTimeout") { continue }
                if argument == "nil", Self.nilAllowed[relative] != nil {
                    seenAllowed.insert(relative)
                    continue
                }
                offenders.append("\(relative):\(index + 1): \(argument)")
            }
        }
        // 走査が呼び手に届いていること(run / api run ×2 / MCP ×2 / dry-run + 許可の2箇所)
        XCTAssertGreaterThanOrEqual(callers, 8, "scan did not reach the ScenarioHost.run callers")
        XCTAssertEqual(offenders, [], "callers must pass ScenarioInfo.scenarioTimeout")
        XCTAssertEqual(seenAllowed, Set(Self.nilAllowed.keys), "stale allowlist entry")
    }
}
