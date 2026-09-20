// run 進捗(docs/design.md §18)の記帳の注入をソース走査で固定する。
//
// **型では守れない継ぎ目**: `writeRunProgress`/`removeRunProgress` を RunOrchestrator へ渡し
// 忘れても run は緑のまま通り、その経路(`fleetest run --profile` または `fleetest api run`)は
// 台帳を1バイトも書かない = モニターのフリート横断ボードにその run が永久に映らない。
// `fleetest run` と `fleetest api run` は実装を別々に持つ2実装(CLAUDE.md)なので両方を見る
// (ParentDeathWatchWiringTests / SupplyLeaseHandOffWiringTests と同型)。

import XCTest

final class RunProgressLedgerWiringTests: XCTestCase {

    private static let sources = ["Sources/fleetest/ProfileRunner.swift",
                                  "Sources/fleetest/ApiRunCommand.swift"]

    private static func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 2経路とも RunOrchestrator へ writeRunProgress/removeRunProgress を注入し、
    /// 実体(RunProgressLedger.write/remove)を呼んでいること
    func testBothRunOrchestratorCallSitesWireRunProgress() throws {
        for path in Self.sources {
            let text = try Self.code(path)
            XCTAssertTrue(text.contains("writeRunProgress: { record in"),
                          "\(path): writeRunProgress を注入していない(この経路の run が" +
                          " フリート横断ボードに出ない)")
            XCTAssertTrue(text.contains("removeRunProgress: {"),
                          "\(path): removeRunProgress を注入していない(run 終了後も台帳が残る)")
            XCTAssertTrue(text.contains("RunProgressLedger.write("),
                          "\(path): writeRunProgress が RunProgressLedger.write を呼んでいない")
            XCTAssertTrue(text.contains("RunProgressLedger.remove("),
                          "\(path): removeRunProgress が RunProgressLedger.remove を呼んでいない")
            XCTAssertTrue(text.contains("profile: resolved.runName") || text.contains("profile: profileName"),
                          "\(path): RunOrchestrator へプロファイル名を渡していない" +
                          " (RunProgressRecord.profile が常に nil になる)")
        }
    }

    /// 2経路とも、供給(デバイスの供給・iOS lateWorkers 等)が終わる前に
    /// phase: "preparing" の記録を書いていること(段階「準備中」)。片方だけだと
    /// その経路の run はボードに「空き」のまま何十秒も映らない
    func testBothCallSitesWritePreparingBeforeSupplyCompletes() throws {
        for path in Self.sources {
            let text = try Self.code(path)
            XCTAssertTrue(text.contains("phase: \"preparing\""),
                          "\(path): 供給の前に phase: \"preparing\" を書いていない" +
                          " (供給中の run がボードに1本も出ない)")
        }
    }

    /// **段階「building」**(docs/design.md §18.1)は run の入口・シナリオの swift build より
    /// 前に書く(実測: build から phase: "preparing" が出るまで ~15秒。書かないとその間ボードに
    /// 1本も出ない)。**build 呼び出しは ProfileRunner.swift の外に居る** ——
    /// `fleetest run --profile` は Sources/fleetest/Fleetest.swift(RunScenarios.run)、
    /// `fleetest api run` は Sources/fleetest/ApiRunCommand.swift(run)がビルドを呼ぶ
    /// (ProfileRunner.run/runWithProfileParallel はどちらもビルド完了後にしか呼ばれない)ので、
    /// "building" の書き手はビルド呼び出し元のファイルで確かめる
    func testBuildingPhaseIsWrittenBeforeTheScenarioBuildCall() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try Self.code(path)
            guard let buildRange = text.range(of: "→ Building scenarios") else {
                XCTFail("\(path): build のログ行が見つからない(この走査の前提が崩れている)")
                continue
            }
            guard let phaseRange = text.range(of: "phase: \"building\"") else {
                XCTFail("\(path): phase: \"building\" を書いていない" +
                        " (ビルド中の run がボードに1本も出ない)")
                continue
            }
            XCTAssertTrue(phaseRange.lowerBound < buildRange.lowerBound,
                          "\(path): phase: \"building\" がビルド呼び出しより後ろにある" +
                          " (ビルド中はボードに1本も出ない)")
        }
    }

    /// **sweep は run の入口(building を書くところ)に1回だけ** —— 段階ごとに呼ぶと
    /// 1 run で何度も走る。死んだ控えが溜まると `api monitor` が毎周期そのぶんを読む
    func testSweepRunsOncePerRunAtTheEntry() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try Self.code(path)
            let sweeps = text.components(separatedBy: "RunProgressLedger.sweep(").count - 1
            XCTAssertEqual(sweeps, 1, "\(path): sweep は run の入口に1回だけ(いま \(sweeps) 箇所)")
        }
        let profileRunner = try Self.code("Sources/fleetest/ProfileRunner.swift")
        XCTAssertFalse(profileRunner.contains("RunProgressLedger.sweep("),
                       "ProfileRunner はビルドの後に呼ばれる —— 入口(Fleetest.swift)で済んでいる")
    }
}
