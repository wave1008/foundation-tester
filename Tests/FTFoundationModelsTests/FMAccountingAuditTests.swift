// FM 呼び出しの計測漏れを検出するソース監査。
//
// 実行時の FM 経路(occlusion / heal / screenLooksLike)は **FMHealth.record を必ず呼ぶ**のが不変条件。
// 記録は①結果 JSON の fm(呼び出し回数・失敗・レイテンシ)②FMBreaker(連続失敗で打ち切り)の
// 両方を養うため、欠けると「fm が空 = 呼ばれていない」と誤読され、かつ FM が死んだホストで
// 失敗が延々と時間を捨てる。実害: 失敗トリアージ(撤去済み)が記録を欠いたまま入っていた(2026-07-30 に発見)。
//
// **判定は関数単位**。ファイル単位で「どこかに record があるか」を見る作りでは、上記の欠落
// (同一ファイルの heal / screenLooksLike は記録済み)を検出できない。

import XCTest

final class FMAccountingAuditTests: XCTestCase {

    private var agentSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTFoundationModelsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("Sources/FTFoundationModels")
    }

    /// 記録しなくてよい呼び出し元とその理由。**追加するときは理由を書く**
    /// (実行 run の結果に紐づかない = fm フィールドにもブレーカにも意味を持たない経路だけ)。
    private let exempt: [String: String] = [
        "FMLivenessProbe.swift": "死活プローブ。**実仕事ではない**ので FMHealth/FMUsageLedger には"
            + "載せない(載せると誰も run を回していないのにモニターの FM レートが動く ="
            + " 測る対象を自分で消費して見せる)。ブレーカは probeOnce が直接養う",
        "ScenarioNamer.swift": "シナリオ作成時(explore/gen-scenario)。run の結果に紐づかない",
        "TestbaseDrafter.swift": "テストベース作成時。run の結果に紐づかない",
        "FMServeServer.swift": "FM の常駐プロセス。記録は要求した側(シナリオ・プローブ)が自分の所要で行う"
            + "(ここで記録すると run の結果 JSON = シナリオのプロセスの集計と食い違い、暖機も呼び出しに数えてしまう)",
    ]

    static let fmCallNeedles = ["LanguageModelSession(", "FMServeWire.Request(kind: .transcribe",
                                "FMServeWire.Request(kind: .screen", "FMServeWire.Request(kind: .probe"]

    func testEveryRuntimeFMCallSiteRecordsToFMHealth() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: agentSourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "Sources/FTFoundationModels が読めていない")

        var checkedFunctions = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            let source = try String(contentsOf: file, encoding: .utf8)
            // FM を呼ぶ形は2つ: 自分でセッションを作る / 常駐プロセスへ実呼び出しを頼む
            let callSites = Self.fmCallNeedles.flatMap { Self.functionBodies(containing: $0, in: source) }
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
                              "\(name) の \(funcName) が FM を呼ぶのに "
                              + "FMHealth.record を呼んでいない(fm フィールドとブレーカに載らない)")
            }
        }
        // 監査が空振りしていないこと(対象0件で緑になるのを防ぐ)
        XCTAssertGreaterThanOrEqual(checkedFunctions, 3,
                                    "実行時の FM 経路が3つ未満しか見えていない = 走査が壊れている")
    }

    /// send の差し替え口が無いので、refused / timeout の return より前に計上する配線を守る
    func testRuntimeRetryAccountingPrecedesEveryResponseBranch() throws {
        for (file, kind, requestKind) in [
            ("OcclusionVerifier.swift", "occlusion", "transcribe"),
            ("ReplayAssist.swift", "screenLooksLike", "screen"),
        ] {
            let source = try String(contentsOf: agentSourceDir.appendingPathComponent(file), encoding: .utf8)
            let functions = Self.functionBodies(containing: "FMServeWire.Request(kind: .\(requestKind)", in: source)
            XCTAssertEqual(functions.count, 1, file)
            let function = try XCTUnwrap(functions.first, file)
            let body = Self.strippingComments(function.1)
            let counter = try XCTUnwrap(body.range(of: "FMHealth.recordRetry("), file)
            let branch = try XCTUnwrap(body.range(of: "switch response.status"), file)
            XCTAssertLessThan(counter.lowerBound, branch.lowerBound,
                              "\(file) が拒否・期限切れを返す前に撃ち直しを計上していない")
            XCTAssertEqual(body.components(separatedBy: "FMHealth.recordRetry(").count - 1, 1, file)
            let beforeBranch = String(body[..<branch.lowerBound])
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            XCTAssertTrue(beforeBranch.contains("FMHealth.recordRetry(kind:\"\(kind)\",count:response.retryCount,"),
                          "\(file) が応答の実試行数を正しい用途へ渡していない")
        }
    }

    func testRuntimeRetrySuccessRequiresFinalOKAndPresentPayload() throws {
        for (file, payload) in [("OcclusionVerifier.swift", "text"), ("ReplayAssist.swift", "pass")] {
            let source = try String(contentsOf: agentSourceDir.appendingPathComponent(file), encoding: .utf8)
            let body = Self.strippingComments(source)
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            XCTAssertTrue(body.contains("succeeded:response.status==.ok&&response.\(payload)!=nil)"),
                          "\(file) は .ok の有効payloadを成功とする(pass=falseもFMの有効な答え)")
        }
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
