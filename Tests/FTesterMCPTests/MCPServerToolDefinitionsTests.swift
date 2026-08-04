import XCTest
@testable import ftester_mcp

/// デバイス選択プロパティの過不足を防ぐ。**「全ツールに付ける」ではなく「要るツールにだけ付ける」**
/// (2026-08-05 変更): 5つ × ツール数で定義全体の約4割を占めるため、デバイスに触らないツールに
/// 並べるとコンテキストを食うだけでなく「渡せば効く」と誤解させる。
/// 逆に**デバイス系から漏れると MCP クライアントから送れない**ので、両方向を検査する。
final class MCPServerToolDefinitionsTests: XCTestCase {
    private static let requiredDeviceKeys: Set<String> = ["platform", "port", "serial", "profile", "project"]

    /// デバイスを掴まないツール(driver(_:) を呼ばない)。増減したらここも直す
    private static let deviceFreeTools: Set<String> = [
        "ft_list_scenarios", "ft_dry_run", "ft_list_projects", "ft_doctor", "ft_dsl_commands",
    ]

    func testDeviceToolsDeclareDeviceSelectionProperties() {
        for definition in MCPServer.toolDefinitions {
            let name = definition["name"] as? String ?? "(unnamed)"
            guard let schema = definition["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else {
                XCTFail("\(name): inputSchema.properties がありません")
                continue
            }
            if Self.deviceFreeTools.contains(name) {
                let extra = Self.requiredDeviceKeys.subtracting(["project"]).intersection(properties.keys)
                XCTAssertTrue(extra.isEmpty,
                              "\(name) はデバイスを掴まないのに選択プロパティを宣言している: \(extra.sorted())")
                continue
            }
            let missing = Self.requiredDeviceKeys.subtracting(properties.keys)
            XCTAssertTrue(missing.isEmpty, "\(name) にデバイス選択プロパティが不足: \(missing.sorted())")
        }
    }

    func testToolDefinitionsIsNonEmpty() {
        XCTAssertFalse(MCPServer.toolDefinitions.isEmpty)
    }
}

final class MCPServerDriverCacheKeyTests: XCTestCase {
    func testDirectKeyDiffersByPort() {
        let a = MCPServer.driverCacheKey(platform: "ios", port: 8123, serial: nil)
        let b = MCPServer.driverCacheKey(platform: "ios", port: 8124, serial: nil)
        XCTAssertNotEqual(a, b)
    }

    func testDirectKeyDiffersBySerial() {
        let a = MCPServer.driverCacheKey(platform: "android", port: nil, serial: "AAA")
        let b = MCPServer.driverCacheKey(platform: "android", port: nil, serial: "BBB")
        XCTAssertNotEqual(a, b)
    }

    func testProfileKeyDiffersByProfileName() {
        let a = MCPServer.driverCacheKey(profile: "device-a", project: "E2E", platform: nil)
        let b = MCPServer.driverCacheKey(profile: "device-b", project: "E2E", platform: nil)
        XCTAssertNotEqual(a, b)
    }

    func testProfileKeyDiffersByProject() {
        let a = MCPServer.driverCacheKey(profile: "device-a", project: "E2E", platform: nil)
        let b = MCPServer.driverCacheKey(profile: "device-a", project: "SampleApp", platform: nil)
        XCTAssertNotEqual(a, b)
    }

    func testProfileKeyNeverCollidesWithDirectKey() {
        let direct = MCPServer.driverCacheKey(platform: "ios", port: 8123, serial: nil)
        let profile = MCPServer.driverCacheKey(profile: "device-a", project: nil, platform: "ios")
        XCTAssertNotEqual(direct, profile)
    }

    func testSameInputsProduceSameKey() {
        let a = MCPServer.driverCacheKey(profile: "device-a", project: "E2E", platform: "ios")
        let b = MCPServer.driverCacheKey(profile: "device-a", project: "E2E", platform: "ios")
        XCTAssertEqual(a, b)
    }
}
