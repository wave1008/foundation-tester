import XCTest
@testable import ftester_mcp

/// port/serial/profile/project がスキーマ宣言から漏れる退行を防ぐ
/// (実装は driver(_:) で対応済みでも、宣言が無いと MCP クライアントから送れない)
final class MCPServerToolDefinitionsTests: XCTestCase {
    private static let requiredDeviceKeys: Set<String> = ["platform", "port", "serial", "profile", "project"]

    func testAllToolsDeclareDeviceSelectionProperties() {
        for definition in MCPServer.toolDefinitions {
            let name = definition["name"] as? String ?? "(unnamed)"
            guard let schema = definition["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else {
                XCTFail("\(name): inputSchema.properties がありません")
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
