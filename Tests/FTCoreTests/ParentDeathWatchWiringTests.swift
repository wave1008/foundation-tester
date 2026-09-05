// ParentDeathWatch の配線をソース走査で固定する。
//
// **武装するのは spawn 側が `FT_PARENT_PID` を渡した子だけ**(既定は no-op)。この集合を
// 等号で固定するのは、新しい spawn 元(`Process()` で fleetest / fleetest-scenarios を
// 子に持つ経路)を足したときに「渡し忘れて孤児のまま残る」を検出するため。

import XCTest
@testable import FTCore

final class ParentDeathWatchWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// `fleetest` / `fleetest-scenarios` の子を `Process()` で起こす5箇所すべてが
    /// `FT_PARENT_PID` を環境へ書いていること
    func testEverySpawnSiteWritesTheParentPIDEnvironmentKey() throws {
        let spawnSites = [
            "Sources/FTCore/ScenarioHost.swift",
            "Sources/fleetest/ApiRunMachineFanout.swift",
            "Sources/fleetest/RemoteDeviceFanout.swift",
            "Sources/fleetest/RemoteMonitorFanout.swift",
            "Sources/fleetest/FleetRunner.swift",
        ]
        for path in spawnSites {
            let text = try source(path)
            // 鍵を直接書く形(ScenarioHost)と、環境ごと組み立てる `childEnvironment()` の両方を認める
            XCTAssertTrue(text.contains("ParentDeathWatch.environmentKey")
                              || text.contains("ParentDeathWatch.childEnvironment("),
                          "\(path) が FT_PARENT_PID を子へ渡していない(孤児のまま残る)")
        }
    }

    /// `fleetest` / `fleetest-scenarios` の2エントリポイントが起動時に武装すること
    func testBothEntryPointsArmOnStartup() throws {
        let entryPoints = [
            "Sources/FTScenarioRunner/ScenarioRunnerMain.swift",
            "Sources/fleetest/Fleetest.swift",
        ]
        for path in entryPoints {
            let text = try source(path)
            XCTAssertTrue(text.contains("ParentDeathWatch.armIfRequested"),
                          "\(path) が起動時に武装していない(FT_PARENT_PID を渡されても孤児化を防げない)")
        }
    }
}
