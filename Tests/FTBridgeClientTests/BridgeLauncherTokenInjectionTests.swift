// BridgeLauncher.injectPort が LAN 認証トークン(BridgeLauncher.bridgeToken)を xctestrun へ
// 注入すること。実機だけが FT_BIND_ALL と揃えて FT_BRIDGE_TOKEN を持つ(不変条件は BridgeAPI 参照)。
// 既存の FT_PORT/FT_BIND_ALL 注入と同じ v2 形式(TestConfigurations[].TestTargets[])で確認する。

import XCTest
@testable import FTBridgeClient
import FTCore

final class BridgeLauncherTokenInjectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-launcher-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeXCTestRun(name: String) throws -> URL {
        let plist: [String: Any] = [
            "TestConfigurations": [
                ["TestTargets": [
                    ["TestBundlePath": "FleetestRunnerUITests.xctest",
                     "EnvironmentVariables": [String: Any]()],
                ]],
            ],
        ]
        let url = root.appendingPathComponent("\(name).xctestrun")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    private func environment(of injected: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: injected)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let configurations = plist["TestConfigurations"] as? [[String: Any]],
              let targets = configurations.first?["TestTargets"] as? [[String: Any]],
              let env = targets.first?["EnvironmentVariables"] as? [String: Any] else {
            XCTFail("injected xctestrun の形が想定と違う")
            return [:]
        }
        return env
    }

    func testPhysicalLauncherInjectsItsOwnToken() throws {
        let launcher = BridgeLauncher(repoRoot: root, device: "00008130-000A1B2C3D4E5678",
                                      port: 8901, physical: true)
        let injected = try launcher.injectPort(into: try makeXCTestRun(name: "FleetestRunner_physical"))
        let env = try environment(of: injected)
        XCTAssertNotNil(launcher.bridgeToken)
        XCTAssertEqual(env["FT_BRIDGE_TOKEN"] as? String, launcher.bridgeToken)
        XCTAssertEqual(env["FT_BIND_ALL"] as? String, "1")
    }

    func testSimulatorLauncherInjectsNeitherBindAllNorToken() throws {
        let launcher = BridgeLauncher(repoRoot: root, device: "iPhone 17", port: 8902, physical: false)
        let injected = try launcher.injectPort(into: try makeXCTestRun(name: "FleetestRunner_simulator"))
        let env = try environment(of: injected)
        XCTAssertNil(launcher.bridgeToken)
        XCTAssertNil(env["FT_BIND_ALL"])
        XCTAssertNil(env["FT_BRIDGE_TOKEN"])
    }
}
