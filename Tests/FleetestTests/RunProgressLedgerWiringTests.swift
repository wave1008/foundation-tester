// run 進捗(docs/design.md §18)の記帳の注入をソース走査で固定する。
//
// **型では守れない継ぎ目**: `writeRunProgress`/`removeRunProgress` を RunOrchestrator へ渡し
// 忘れても run は緑のまま通り、その経路(`fleetest run --profile` または `fleetest api run`)は
// 台帳を1バイトも書かない = モニターのフリート横断ボードにその run が永久に映らない。
// 注入は `fleetest run` / `fleetest api run` が共有する ProfileRunOrchestrator の1箇所
// (2経路がそこを通ることは ProfileRunOrchestratorWiringTests)。

import XCTest

final class RunProgressLedgerWiringTests: XCTestCase {

    private static let sources = ["Sources/fleetest/ProfileRunOrchestrator.swift"]

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
            XCTAssertTrue(text.contains("profile: profile,"),
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

    /// **段階「building」は本当にビルドしている間だけ**(ユーザー決定 2026-09-22)——
    /// 以前は run の入口で "building" を書いていたので、`--skip-build`(機械分担のローカル子は
    /// 常にこれ)では**1バイトもビルドしないまま「ビルド中」**が出て、ビルドが終わってからも
    /// 供給が始まるまで「ビルド中」のままだった。入口は "preparing" で書き(書かないと
    /// その間ボードに1本も出ない)、`ScenarioHost.build` を挟む間だけ "building" にして
    /// **直後に戻す**。**build 呼び出しは ProfileRunner.swift の外に居る** ——
    /// `fleetest run --profile` は Sources/fleetest/Fleetest.swift(RunScenarios.run)、
    /// `fleetest api run` は Sources/fleetest/ApiRunCommand.swift(run)がビルドを呼ぶ
    func testBuildingPhaseIsWrittenOnlyAroundTheScenarioBuildCall() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try Self.code(path)
            guard let buildRange = text.range(of: "→ Building scenarios") else {
                XCTFail("\(path): build のログ行が見つからない(この走査の前提が崩れている)")
                continue
            }
            guard let phaseRange = text.range(of: "writeProgress(phase: \"building\")") else {
                XCTFail("\(path): phase: \"building\" を書いていない" +
                        " (ビルド中の run がボードに1本も出ない)")
                continue
            }
            XCTAssertTrue(phaseRange.lowerBound < buildRange.lowerBound,
                          "\(path): phase: \"building\" がビルド呼び出しより後ろにある" +
                          " (ビルド中はボードに1本も出ない)")
            // **入口ではない** —— ビルド呼び出しの直前でだけ立てる(間に入口の記帳や defer が
            // 挟まっていないこと。以前は 20 行以上離れた run の入口に居た)
            let gap = text.distance(from: phaseRange.upperBound, to: buildRange.lowerBound)
            XCTAssertLessThan(gap, 200,
                              "\(path): phase: \"building\" がビルド呼び出しから離れている" +
                              " (--skip-build でも「ビルド中」が出る形に戻っている)")
            // 入口は "preparing"(ビルドの前に1本書いておく = その間ボードから消えない)
            let entry = text.range(of: "writeProgress(phase: \"preparing\")")
            XCTAssertNotNil(entry, "\(path): 入口で phase: \"preparing\" を書いていない")
            if let entry {
                XCTAssertTrue(entry.lowerBound < phaseRange.lowerBound,
                              "\(path): 入口の記帳がビルドの段より後ろにある")
            }
            // ビルドが終わったら戻す(終わっているのに「ビルド中」のままにしない)
            let after = text.range(of: "writeProgress(phase: \"preparing\")",
                                   range: buildRange.upperBound..<text.endIndex)
            XCTAssertNotNil(after,
                            "\(path): ビルドの後に phase: \"preparing\" へ戻していない" +
                            " (供給が始まるまで「ビルド中」のまま出る)")
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

    // MARK: - 供給の段階(台帳の supply)

    /// 入口の2経路が箱を作り、供給と台帳の書き手へ渡していること。片方だけだと、その経路の
    /// 準備中表示に段階が出ない(run は緑のまま通る)
    func testBothEntriesCreateTheSupplyBoxAndHandItOn() throws {
        let fleetest = try Self.code("Sources/fleetest/Fleetest.swift")
        XCTAssertTrue(fleetest.contains("let supplyProgress = RunSupplyProgress()"), "Fleetest.swift が箱を作っていない")
        XCTAssertTrue(fleetest.contains("supplyProgress: supplyProgress,"),
                      "Fleetest.swift が ProfileRunner.run へ箱を渡していない")
        XCTAssertTrue(fleetest.contains("entryProgress.attach()"), "入口の書き手が箱の変更通知を引き継いでいない")

        let api = try Self.code("Sources/fleetest/ApiRunCommand.swift")
        let box = try XCTUnwrap(api.range(of: "let supplyProgress = RunSupplyProgress()"),
                                "ApiRunCommand.swift が箱を作っていない")
        // 供給のタスクを起こす前に作る(段階は入口の書き込みより前に起きうる)
        let task = try XCTUnwrap(api.range(of: "androidWorkersTask = Task {"))
        XCTAssertTrue(box.lowerBound < task.lowerBound, "箱を供給のタスクより後で作っている")
        XCTAssertTrue(api.contains("supplyProgress: supplyProgress,"), "runWithProfileParallel へ箱を渡していない")
        XCTAssertTrue(api.contains("supply: supplyProgress,"), "ProfileRunOrchestrator.make へ箱を渡していない")
        XCTAssertTrue(api.contains("entryProgress.attach()"), "入口の書き手が箱の変更通知を引き継いでいない")

        let runner = try Self.code("Sources/fleetest/ProfileRunner.swift")
        XCTAssertTrue(runner.contains("supply: supplyProgress,"), "ProfileRunOrchestrator.make へ箱を渡していない")
        XCTAssertTrue(runner.contains("writePreparingProgress(")
                      && runner.contains("supply: supplyProgress)"), "準備中の書き手へ箱を渡していない")
        let orchestrator = try Self.code("Sources/fleetest/ProfileRunOrchestrator.swift")
        XCTAssertTrue(orchestrator.contains("supplyProgress: supply,"),
                      "RunOrchestrator へ箱を渡していない(混在 run の準備中表示が出ない)")
    }

    /// 台帳の書き手3つ(入口/準備中=PreparingProgressWriter・RunProgressState)が supply を record に載せること
    func testAllThreeLedgerWritersCarryTheSupplySnapshot() throws {
        let writer = try Self.code("Sources/fleetest/PreparingProgressWriter.swift")
        XCTAssertTrue(writer.contains("supply: supply.snapshot()"), "PreparingProgressWriter が supply を載せていない")
        let core = try Self.code("Sources/FTCore/RunOrchestrator.swift")
        XCTAssertTrue(core.contains("supply: supply?.snapshot() ?? []"), "RunProgressState が supply を載せていない")
        // RunProgressRecord を組む箇所はこの2つだけ(増えたら supply の載せ方を見直す)
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift",
                     "Sources/fleetest/ProfileRunOrchestrator.swift"] {
            XCTAssertFalse(try Self.code(path).contains("RunProgressRecord("),
                           "\(path): record を直接組んでいる(PreparingProgressWriter を通す)")
        }
    }

    /// 供給側の通知(supplyStage)を渡し忘れていないこと。既定値を置かない引数なのでコンパイルが止めるが、
    /// `nil` を渡してよい場所は限る(台帳を書かない経路・run 中の復帰・回復)
    func testSupplyCallSitesPassSupplyStage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/fleetest/ProfileRunner.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try Self.code(path)
            for call in ["bootMissingDevices(", "buildIOSWorkers(", "installIfNeeded("] {
                var from = text.startIndex
                while let hit = text.range(of: call, range: from..<text.endIndex) {
                    let window = String(text[hit.upperBound...].prefix(500))
                    XCTAssertTrue(window.contains("supplyStage:"), "\(path): \(call) に supplyStage: が無い")
                    from = hit.upperBound
                }
            }
        }
        let api = try Self.code("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertEqual(api.components(separatedBy: "supplyStage: supplyProgress.reporter").count - 1, 4,
                       "api run の供給(Android 起こし直し・Android install・iOS 供給・iOS install)が箱へ通知する")
        let runner = try Self.code("Sources/fleetest/ProfileRunner.swift")
        XCTAssertEqual(runner.components(separatedBy: "supplyStage: supplyProgress.reporter").count - 1, 4,
                       "run の供給(Android 起こし直し・Android install・iOS 供給・iOS install)が箱へ通知する")
        let factory = try String(contentsOf: root.appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(factory.contains("BridgeProvisioner(repoRoot: repoRoot, supplyStage: supplyStage)"),
                      "buildIOSWorkers が BridgeProvisioner へ通知を渡していない")
    }
}
