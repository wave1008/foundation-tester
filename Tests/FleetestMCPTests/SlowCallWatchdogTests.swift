// 止まった呼び出しの記録と、ft_status が FM を呼ばないこと(2026-10-11: ft_status が FM の実呼び出しで2分以上止まった)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class SlowCallWatchdogTests: XCTestCase {

    /// 記録し始めるまでの秒(正常な最長 25 秒の2倍強)。値はリテラルで固定する
    func testTheReportThresholdIsPinned() {
        XCTAssertEqual(SlowCallWatchdog.reportAfterSeconds, 60)
    }

    /// 記録にはツール名・いまの段階が載り、呼び出しが終われば消える
    func testTheReportNamesTheToolAndThePhaseAndEndsWithTheCall() {
        let callID = 987_654
        let watchdog = SlowCallWatchdog.start(callID: callID, tool: "ft_status")
        MCPServer.$currentCallID.withValue(callID) {
            SlowCallWatchdog.mark("resolving the device's bridge")
        }
        let line = SlowCallWatchdog.report(callID: callID, now: Date().addingTimeInterval(61))
        XCTAssertTrue(line?.contains("ft_status") == true, line ?? "nil")
        XCTAssertTrue(line?.contains("phase: resolving the device's bridge") == true, line ?? "nil")
        XCTAssertTrue(line?.contains("bridge requests in flight") == true, line ?? "nil")
        watchdog.finish()
        XCTAssertNil(SlowCallWatchdog.report(callID: callID, now: Date()))
    }

    /// 入れ子の段階を抜けたら外側の段階へ戻る(ドライバの解決の後に「解決中」が残らない)
    func testANestedPhaseRestoresTheOuterOne() async {
        let callID = 987_655
        let watchdog = SlowCallWatchdog.start(callID: callID, tool: "ft_tap")
        defer { watchdog.finish() }
        await MCPServer.$currentCallID.withValue(callID) {
            SlowCallWatchdog.mark("running ft_tap")
            await SlowCallWatchdog.marking("resolving the device's bridge") {}
        }
        XCTAssertTrue(SlowCallWatchdog.report(callID: callID, now: Date())?.contains("phase: running ft_tap") == true)
    }

    /// **ft_status は FM を呼ばない**(台帳を読むだけ)。MCP のソースに FM の実呼び出しの口が出たら落とす
    /// (ft_doctor は FMDoctor 経由で呼ぶ = 実呼び出しで確かめるのが役目)
    func testTheMCPServerNeverProbesFMOutsideTheDoctor() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest-mcp")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "走査が Sources/fleetest-mcp に届いていない")
        var offenders: [String] = []
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in code where line.contains("FMLivenessProbe.refresh") || line.contains("FMLivenessProbe.probeOnce") {
                offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
