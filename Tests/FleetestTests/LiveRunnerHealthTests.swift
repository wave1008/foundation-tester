import FTBridgeClient
import XCTest
@testable import fleetest

/// ライブ操作のランナー劣化の警告(`ApiLiveServe.checkRunnerHealth` / `LiveRunnerHealthMemo`)。
/// 実地: DragUI.druid の remote element に毎問 ~17s かかる状態で、ライブ操作は命令ごとに 30s の
/// watchdog に当たって serve の強制終了を繰り返し、利用者には何も言っていなかった(run には
/// RunnerAccessibilityHealth の測り直しがあるのに、live には無かった)
final class LiveRunnerHealthTests: XCTestCase {

    /// 知らせるのは劣化の初回だけ・次の観測1回にだけ載せる。reset(ブリッジの起動し直し)で再び測る
    func testMemoWarnsOnceUntilReset() async {
        let memo = LiveRunnerHealthMemo()
        let first = await memo.noteDegraded("slow")
        XCTAssertTrue(first)
        let again = await memo.noteDegraded("slow")
        XCTAssertFalse(again, "同じ劣化を二度知らせた")
        let taken = await memo.takeNotes()
        XCTAssertEqual(taken, ["slow"])
        let emptied = await memo.takeNotes()
        XCTAssertEqual(emptied, [], "注記が2回の観測に載った")
        await memo.reset()
        let warnedAfterReset = await memo.warned
        XCTAssertFalse(warnedAfterReset)
        let afterReset = await memo.noteDegraded("slow")
        XCTAssertTrue(afterReset, "起動し直した後の劣化を知らせない")
    }

    /// 測った値と、そのポートで撃てる対処を言う。自動起動できない serve では「起動し直せ」まで言う
    func testLiveDegradedNoteNamesTheMeasurementAndTheRemedy() {
        let auto = RunnerAccessibilityHealth.liveDegradedNote(port: 8170, probeSeconds: 17.31,
                                                              injected: false, autoStarts: true)
        XCTAssertEqual(auto,
            "the xcuitest bridge on port 8170 answered a one-element accessibility query in 17.3s;"
            + " normal is under 0.3s, and every operation here pays that wait on each accessibility"
            + " query (a stale remote element after a system daemon restart). Restart the bridge first:"
            + " `fleetest bridge down --port 8170` (live control starts it again on the next action);"
            + " if it is still this slow afterwards, reboot the simulator")
        let manual = RunnerAccessibilityHealth.liveDegradedNote(port: 8123, probeSeconds: nil,
                                                                injected: true, autoStarts: false)
        XCTAssertTrue(manual.contains("is injected as slow (FT_FAKE_SLOW_RUNNER_PORTS)"))
        XCTAssertTrue(manual.contains("`fleetest bridge down --port 8123`, then start it again"))
    }

    // MARK: - 配線(ソース走査)

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 測るのは操作の後(所要を知ってから)で、watchdog の区間の外。観測の notes に控えが載る。
    /// 自動起動で宛先を引き直したら控えを解除する
    func testServeLoopMeasuresAfterTheCommandAndObservationCarriesTheNote() throws {
        let code = try source()
        guard let loop = code.range(of: "for await line in lines {"),
              let loopEnd = code.range(of: "deviceLease?.release()", range: loop.upperBound..<code.endIndex) else {
            return XCTFail("serve のループが見当たらない — テストを見直すこと")
        }
        let body = String(code[loop.upperBound..<loopEnd.lowerBound])
        guard let handle = body.range(of: "await handle(command: command"),
              let end = body.range(of: "ResidentProcessGuard.noteCommandEnd()", range: handle.upperBound..<body.endIndex),
              let check = body.range(of: "await checkRunnerHealth(command: command", range: end.upperBound..<body.endIndex)
        else {
            return XCTFail("handle → noteCommandEnd → checkRunnerHealth の順になっていない")
        }
        _ = check
        XCTAssertTrue(body.contains("await runnerHealth.reset()"), "自動起動の後に控えを解除していない")

        guard let start = code.range(of: "private func emitObservation("),
              let stop = code.range(of: "private func emitFrame(") else {
            return XCTFail("emitObservation が見当たらない")
        }
        XCTAssertTrue(String(code[start.upperBound..<stop.lowerBound]).contains("runnerHealth.takeNotes()"),
                      "観測の notes に劣化の注記を載せていない")
    }

    /// 判定は run と同じ RunnerAccessibilityHealth(門・1問・閾値・注入口)。2つ目の判定を作らない
    func testCheckUsesTheSharedJudgement() throws {
        let code = try source()
        guard let start = code.range(of: "private func checkRunnerHealth("),
              let stop = code.range(of: "private func handle(", range: start.upperBound..<code.endIndex) else {
            return XCTFail("checkRunnerHealth が見当たらない")
        }
        let body = String(code[start.upperBound..<stop.lowerBound])
        for needle in ["RunnerAccessibilityHealth.injectedSlowPorts()",
                       "RunnerAccessibilityHealth.shouldRecheck(",
                       "RunnerAccessibilityHealth.probe(",
                       "RunnerAccessibilityHealth.isDegraded(",
                       "await !memo.warned"] {
            XCTAssertTrue(body.contains(needle), "checkRunnerHealth が \(needle) を通っていない")
        }
    }
}
