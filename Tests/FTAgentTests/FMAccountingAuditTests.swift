// FM 呼び出しの計測漏れを検出するソース監査。
//
// 実行時の FM 経路(occlusion / heal / screenIs / triage)は **FMHealth.record を必ず呼ぶ**のが不変条件。
// 記録は①結果 JSON の fm(呼び出し回数・失敗・レイテンシ)②FMBreaker(連続失敗で打ち切り)の
// 両方を養うため、欠けると「fm が空 = 呼ばれていない」と誤読され、かつ FM が死んだホストで
// 失敗が延々と時間を捨てる。実害: triage が記録を欠いたまま入っていた(2026-07-30 に発見)。
//
// **判定は関数単位**。ファイル単位で「どこかに record があるか」を見る作りでは、上記の triage 欠落
// (同一ファイルの heal / screenIs は記録済み)を検出できない。

import XCTest

final class FMAccountingAuditTests: XCTestCase {

    private var agentSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAgentTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("Sources/FTAgent")
    }

    /// 記録しなくてよい呼び出し元とその理由。**追加するときは理由を書く**
    /// (実行 run の結果に紐づかない = fm フィールドにもブレーカにも意味を持たない経路だけ)。
    private let exempt: [String: String] = [
        "FMDoctor.swift": "可用性判定(doctor の実呼び出し)。run の実績ではない",
        "ScenarioNamer.swift": "シナリオ作成時(explore/gen-scenario)。run の結果に紐づかない",
        "TestbaseDrafter.swift": "テストベース作成時。run の結果に紐づかない",
    ]

    func testEveryRuntimeFMCallSiteRecordsToFMHealth() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: agentSourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "Sources/FTAgent が読めていない")

        var checkedFunctions = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            let source = try String(contentsOf: file, encoding: .utf8)
            let callSites = Self.functionBodies(containing: "LanguageModelSession(", in: source)
            if let reason = exempt[name] {
                // 免除ファイルは「本当に FM を呼んでいる」ことだけ確かめる(誤って残った免除の掃除)
                XCTAssertFalse(callSites.isEmpty,
                               "\(name) は FM を呼んでいないので exempt から外す(理由: \(reason))")
                continue
            }
            for (funcName, body) in callSites {
                checkedFunctions += 1
                // **コメントを落としてから判定する**。判定を素の contains("FMHealth.record") で
                // 書くと、記録の必要性を説明したコメント自身に一致して**変異で落ちない無力な
                // テスト**になる(実際にそれで一度素通りした)。呼び出しの形まで見る。
                XCTAssertTrue(Self.strippingComments(body).contains("FMHealth.record(kind:"),
                              "\(name) の \(funcName) が LanguageModelSession を呼ぶのに "
                              + "FMHealth.record を呼んでいない(fm フィールドとブレーカに載らない)")
            }
        }
        // 監査が空振りしていないこと(対象0件で緑になるのを防ぐ)
        XCTAssertGreaterThanOrEqual(checkedFunctions, 3,
                                    "実行時の FM 経路が3つ未満しか見えていない = 走査が壊れている")
    }

    /// 行コメント(`//` 以降)を落とす。コメント中の記述に一致して監査が空振りするのを防ぐ。
    static func strippingComments(_ source: String) -> String {
        source.components(separatedBy: "\n")
            .map { line -> String in
                guard let r = line.range(of: "//") else { return line }
                return String(line[..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// needle を含む関数の (関数名, 本文) を返す。`func` 行から中括弧の対応で本文末尾を求める。
    static func functionBodies(containing needle: String, in source: String) -> [(String, String)] {
        let chars = Array(source)
        var results: [(String, String)] = []
        let lines = source.components(separatedBy: "\n")
        var offset = 0
        var starts: [(name: String, index: Int)] = []
        for line in lines {
            if let r = line.range(of: #"func\s+\w+"#, options: .regularExpression) {
                starts.append((String(line[r]).replacingOccurrences(of: "func ", with: ""), offset))
            }
            offset += line.count + 1
        }
        for (i, start) in starts.enumerated() {
            // 本文は次の func 開始まで(入れ子の func は無いので十分)
            let end = i + 1 < starts.count ? starts[i + 1].index : chars.count
            let body = String(chars[start.index..<min(end, chars.count)])
            if body.contains(needle) { results.append((start.name, body)) }
        }
        return results
    }
}
