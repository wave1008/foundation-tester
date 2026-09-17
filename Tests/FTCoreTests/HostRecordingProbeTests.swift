// HostRecordingProbe(run 前の「端末側の録画セッション」検査)の判定と、壊さないための規律。
// 検査そのものは simctl を撃つので単体では通せない(実物での確認は docs/verification.md の手順)。

import XCTest
@testable import FTCore

final class HostRecordingProbeTests: XCTestCase {

    /// simctl が実際に出した行(残留セッションの台で採取)
    func testBusyLineFromSimctlIsBusy() {
        let line = "Error starting video recorder: Error Domain=NSPOSIXErrorDomain Code=16 \"Resource busy\""
            + " UserInfo={NSLocalizedFailureReason=Host recording is already in progress}."
        XCTAssertEqual(HostRecordingProbe.classify(line: line), .busy)
        XCTAssertEqual(HostRecordingProbe.classify(line: "Host recording is already in progress"), .busy)
    }

    func testRecordingStartedIsFree() {
        XCTAssertEqual(HostRecordingProbe.classify(line: "Recording started"), .free)
    }

    /// 前置きの行では決めない(決めると健全機を早々に閉じ、busy の行を見逃す)
    func testUnrelatedLinesDecideNothing() {
        XCTAssertNil(HostRecordingProbe.classify(
            line: "Note: No display specified. Defaulting to display: EA0DD068 (screenID: 1, name: LCD)"))
        XCTAssertNil(HostRecordingProbe.classify(line: ""))
    }

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// **検査がこの状態を作らない**: recordVideo を SIGINT 以外で止めると端末側のセッションが残る
    func testProbeNeverKillsTheRecorderHarshly() throws {
        let code = try source("Sources/FTCore/HostRecordingProbe.swift")
        XCTAssertTrue(code.contains("process.interrupt()"), "停止は SIGINT(interrupt)で行う")
        for forbidden in [".terminate()", "SIGKILL", "SIGTERM", "kill("] {
            let executable = code.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(executable.contains(forbidden), "\(forbidden) で recordVideo を止めている")
        }
    }

    /// 録画側と検査側で simctl の文言を別々に持たない(片方だけ変わると検査と録画の判断が割れる)
    func testRecorderSharesTheSimctlMarkers() throws {
        let code = try source("Sources/FTCore/IOSSimulatorVideoRecorder.swift")
        XCTAssertTrue(code.contains("HostRecordingProbe.busyMarker"))
        XCTAssertTrue(code.contains("HostRecordingProbe.startedMarker"))
        XCTAssertFalse(code.contains("line.contains(\"Host recording is already in progress\")"))
        XCTAssertFalse(code.contains("line.contains(\"Recording started\")"))
    }

    /// iOS ワーカーの供給口は3つ(ProfileRunner の遅延合流 / ApiRunCommand の遅延合流・直接供給)。
    /// **全部で**凍結のトリアージの後に検査を通す(片方だけだと、その経路の録画だけ欠ける)
    func testEverySupplyPathRecoversStaleRecordingAfterTheBlankTriage() throws {
        for (file, expected) in [("Sources/fleetest/ProfileRunner.swift", 1),
                                 ("Sources/fleetest/ApiRunCommand.swift", 2)] {
            let code = try source(file)
            let call = "ProfileWorkerFactory.recoverStaleRecordingIOSWorkers("
            let triage = "BlankWorkerTriage.excludeBlankScreenWorkers("
            XCTAssertEqual(code.components(separatedBy: call).count - 1, expected, "\(file) の呼び出し数")
            XCTAssertEqual(code.components(separatedBy: triage).count - 1, expected, "\(file) の供給口の数")
            var searchStart = code.startIndex
            while let triageRange = code.range(of: triage, range: searchStart..<code.endIndex) {
                guard let callRange = code.range(of: call, range: triageRange.upperBound..<code.endIndex) else {
                    return XCTFail("\(file): 凍結のトリアージの後に録画セッションの検査が無い")
                }
                let nextTriage = code.range(of: triage, range: triageRange.upperBound..<code.endIndex)
                XCTAssertTrue(nextTriage.map { callRange.lowerBound < $0.lowerBound } ?? true,
                              "\(file): トリアージと検査の組がずれている")
                XCTAssertLessThan(code.distance(from: triageRange.lowerBound, to: callRange.lowerBound), 2_500,
                                  "\(file): 検査がトリアージから離れすぎている(別の供給口に付いている疑い)")
                searchStart = callRange.upperBound
            }
        }
    }
}
