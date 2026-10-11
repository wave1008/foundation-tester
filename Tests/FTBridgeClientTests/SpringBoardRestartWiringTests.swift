import XCTest
import FTCore

/// **劣化したランナーの回復は、シミュレータでは SpringBoard を先に起こし直す**。劣化の物差し(`/systemalert` = SpringBoard への
/// 1問)が遅いのは SpringBoard の側で、ランナーの起動し直しだけでは 3.5s のままだった(起こし直すと 0.11〜0.18s)。
/// 起こし直しの部品は残ったシステムアラートの3段目と共有する(2か所で別に書かない)
final class SpringBoardRestartWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheCommandRestartsSpringBoardInTheGivenSimulator() {
        XCTAssertEqual(SimulatorSpringBoard.command(udid: "ABC"),
                       ["xcrun", "simctl", "spawn", "ABC", "launchctl", "kickstart", "-k", "system/com.apple.SpringBoard"])
    }

    func testRestartRunnerRestartsSpringBoardFirstOnASimulator() throws {
        let code = try source("Sources/FTBridgeClient/BridgeProvisioner.swift")
        let start = try XCTUnwrap(code.range(of: "private func restartRunner("))
        let body = String(code[start.upperBound...].prefix(2500))
        let respring = try XCTUnwrap(body.range(of: "SimulatorSpringBoard.restart(udid: sim.udid)"),
                                     "restartRunner が SpringBoard を起こし直していない")
        let launch = try XCTUnwrap(body.range(of: "try await executeBridge("))
        XCTAssertLessThan(respring.lowerBound, launch.lowerBound, "ランナーを起動し直す前に起こし直すこと")
        XCTAssertTrue(body.contains("if !sim.physical {"), "実機には撃たないこと")
    }

    func testTheResidualAlertClearingSharesTheSameRestart() throws {
        let code = try source("Sources/FTAndroid/ProfileWorkerFactory.swift")
        XCTAssertTrue(code.contains("SimulatorSpringBoard.restart(udid: udid)"))
        XCTAssertFalse(code.contains("\"system/com.apple.SpringBoard\""), "起こし直しのコマンドを2か所に書いている")
    }
}
