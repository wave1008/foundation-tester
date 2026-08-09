import XCTest
@testable import ftester_mcp

/// デバイス選択プロパティの過不足を防ぐ。**「全ツールに付ける」ではなく「要るツールにだけ付ける」**
/// (2026-08-05 変更): 5つ × ツール数で定義全体の約4割を占めるため、デバイスに触らないツールに
/// 並べるとコンテキストを食うだけでなく「渡せば効く」と誤解させる。
/// 逆に**デバイス系から漏れると MCP クライアントから送れない**ので、両方向を検査する。
final class MCPServerToolDefinitionsTests: XCTestCase {
    private static let requiredDeviceKeys: Set<String> = ["platform", "port", "serial", "profile", "project"]

    /// デバイスを掴まないツール(driver(_:) を呼ばない)と、そこで**意味を持つ**選択プロパティ。
    /// 空 = 1つも宣言してはいけない。増減したらここも直す。
    /// ft_list_devices はプロファイルを読むだけ・ft_logs は adb とホストのファイルだけを見るので、
    /// 宛先を絞る引数は要るが port/serial/profile の全部は要らない
    private static let deviceFreeTools: [String: Set<String>] = [
        "ft_list_scenarios": [], "ft_dry_run": [], "ft_list_projects": [], "ft_doctor": [],
        "ft_dsl_commands": [],
        // 記録済みの操作列から下書きを組むだけ = デバイスに触らない
        "ft_draft_scenario": [],
        "ft_list_devices": ["platform", "profile"],
        "ft_logs": ["platform", "serial"],
    ]

    func testDeviceToolsDeclareDeviceSelectionProperties() {
        for definition in MCPServer.toolDefinitions {
            let name = definition["name"] as? String ?? "(unnamed)"
            guard let schema = definition["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else {
                XCTFail("\(name): inputSchema.properties がありません")
                continue
            }
            if let allowed = Self.deviceFreeTools[name] {
                let declared = Self.requiredDeviceKeys.subtracting(["project"])
                    .intersection(properties.keys)
                XCTAssertEqual(declared, allowed,
                               "\(name) の選択プロパティが許可集合と違う: 宣言 \(declared.sorted())"
                                + " / 許可 \(allowed.sorted())")
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
