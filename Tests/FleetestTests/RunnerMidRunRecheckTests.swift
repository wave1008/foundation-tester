// run 中の XCUITest ランナーの測り直し(RunnerMidRunRecheck)。対象レーンの選別と、2 経路の配線。
// ループ本体はデバイスが要るので単体では通せない —— 配線をソースで固定する
// (RunOrchestrator の `recheckRunner:` は既定 nil なので、渡し忘れはコンパイルで止まらない)。

import FTCore
import XCTest
@testable import fleetest

final class RunnerMidRunRecheckTests: XCTestCase {

    // MARK: - 対象レーンの選別

    /// 素の xcuitest レーン(engine は nil で来る)は主ポートがランナー
    func testPlainXCUITestSimulatorLaneIsTargeted() {
        let connection = DriverConnection(platform: "ios", port: 8124, udid: "SIM-1")
        let target = RunnerMidRunRecheck.target(of: connection)
        XCTAssertEqual(target?.udid, "SIM-1")
        XCTAssertEqual(target?.port, 8124)
    }

    func testExplicitXCUITestEngineIsTargeted() {
        let connection = DriverConnection(platform: "ios", port: 8130, engine: "xcuitest", udid: "SIM-2")
        XCTAssertEqual(RunnerMidRunRecheck.target(of: connection)?.port, 8130)
    }

    /// hybrid はランナーを建て直すと同じ台の in-app ブリッジも消えるので対象外
    func testHybridLaneIsNotTargeted() {
        let connection = DriverConnection(platform: "ios", port: 8135, engine: "hybrid",
                                          udid: "SIM-3", xcuiPort: 8136)
        XCTAssertNil(RunnerMidRunRecheck.target(of: connection))
    }

    func testInAppLaneIsNotTargeted() {
        let connection = DriverConnection(platform: "ios", port: 8137, engine: "inapp", udid: "SIM-4")
        XCTAssertNil(RunnerMidRunRecheck.target(of: connection))
    }

    func testPhysicalDeviceIsNotTargeted() {
        let connection = DriverConnection(platform: "ios", port: 8140, udid: "00008110-001460910E0A201E",
                                          physical: true)
        XCTAssertNil(RunnerMidRunRecheck.target(of: connection))
    }

    func testAndroidLaneIsNotTargeted() {
        let connection = DriverConnection(platform: "android", port: 8150, serial: "emulator-5554")
        XCTAssertNil(RunnerMidRunRecheck.target(of: connection))
    }

    /// udid が分からなければ建て直す台を引けないので対象外
    func testLaneWithoutUDIDIsNotTargeted() {
        XCTAssertNil(RunnerMidRunRecheck.target(of: DriverConnection(platform: "ios", port: 8124)))
    }

    // MARK: - 配線(run / api run の 2 経路)

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func count(_ needle: String, in path: String) throws -> Int {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        return text.components(separatedBy: needle).count - 1
    }

    func testBothRunPathsPassTheRecheck() throws {
        for path in ["Sources/fleetest/ProfileRunner.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            XCTAssertEqual(try count("recheckRunner: { worker, maxStepSnapshotMs, log in", in: path), 1, path)
            XCTAssertEqual(try count("RunnerMidRunRecheck.recheck(", in: path), 1, path)
        }
    }

    /// 門の材料(ステップの snapshot 所要)を集めて、緑の直後に呼ぶ配線
    func testWorkerLoopFeedsTheRecheck() throws {
        let path = "Sources/FTCore/RunOrchestrator.swift"
        XCTAssertEqual(try count("slowestStep.note(ms)", in: path), 1)
        XCTAssertEqual(try count("await recheckRunner(worker, slowestStep.value)", in: path), 1)
    }
}
