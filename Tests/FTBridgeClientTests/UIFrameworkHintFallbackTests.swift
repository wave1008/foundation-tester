// 空打ちゲート(StepExecutor.shouldEmptyDrag)へ渡す uiFramework を、**プローブの締切に
// 預けていない**ことを固定する(2026-08-15)。
//
// 起動時プローブの締切は「suspend したアプリは TCP を受理して答えない」を素早く諦めるための
// 値で、**冷えた実機ブリッジがそこに収まる保証は無い**。外れて nil のまま進むと
// shouldEmptyDrag は「不明なら打つ」へ倒れ、RN では 4pt の横抜きが pressRetentionOffset
// (既定20pt)に収まって onPress が成立する = **scrollTo しただけで行が選択される**。
// 何も失敗しないので、緑は証拠にならない —— ここでは「自己申告が無いときに受け皿へ落ちること」を
// ソースで固定する(実挙動の受け皿そのものは AppBundleInspectorTests が見る)。

import XCTest
@testable import FTCore

final class UIFrameworkHintFallbackTests: FTBridgeClientSourceScanCase {

    private static let runnerPath = "Sources/FTScenarioRunner/ScenarioRunnerMain.swift"

    /// `uiFrameworkHint` への代入は**すべて**バンドルのマーカーへ落ちること。
    /// 1箇所でも自己申告だけに戻ると、その経路だけが黙って盲打ちに戻る
    func testEveryUIFrameworkHintAssignmentFallsBackToTheBundleMarker() throws {
        let source = try Self.readSource(Self.runnerPath)
        let statements = Self.statements(in: source, startingWith: "uiFrameworkHint = ")
        XCTAssertGreaterThanOrEqual(statements.count, 3,
                                    "走査対象が見つからない = 変数名か書式が変わった(\(statements.count) 箇所)")
        let offenders = statements.filter { !$0.contains("AppBundleInspector.detect(") }
        XCTAssertTrue(offenders.isEmpty,
                      "uiFramework をプローブの応答だけで決めている(締切を外すと盲打ちになる): \(offenders)")
    }

    /// プローブの締切は**クライアントと呼び出しで同じ値**を使うこと。片方だけ変えると
    /// 短い方が実効値になり、「30 秒に延ばしたつもりが 4 秒のまま」が起きる
    func testTheProbeTimeoutIsNamedAndUsedOnBothSides() throws {
        let source = try Self.readSource(Self.runnerPath)
        let uses = source.components(separatedBy: "Self.injectedAppProbeTimeout").count - 1
        XCTAssertEqual(uses, 2,
                       "プローブの締切は BridgeClient(timeoutSeconds:) と status(timeout:) の"
                       + " 両方で同じ定数を使うこと(見つかった数 \(uses))")
    }
}

extension FTBridgeClientSourceScanCase {
    /// `prefix`(比較 `==` と取り違えないよう末尾の空白まで含める)で始まる**文**(継続行を含む)を取り出す。継続の判定は
    /// 「カッコが閉じていない」か「行末が演算子/カンマ」か「次の行が `??` で始まる」
    static func statements(in source: String, startingWith prefix: String) -> [String] {
        var result: [String] = []
        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard lines[index].contains(prefix) else { continue }
            var text = lines[index]
            var next = index + 1
            while next < lines.count {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let opens = text.filter { $0 == "(" }.count
                let closes = text.filter { $0 == ")" }.count
                let continues = opens > closes || trimmed.hasSuffix("??") || trimmed.hasSuffix(",")
                    || lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("??")
                guard continues else { break }
                text += " " + lines[next]
                next += 1
            }
            result.append(Self.collapsed(text))
        }
        return result
    }
}
