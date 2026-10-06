// 全ツールが annotations を持ち、プロジェクトのコードを実行するツールが読み取り専用を名乗らないこと。
// クライアントはこれで承認の扱いを分ける(読み取り専用を自動承認にする設定がある)。

import XCTest
@testable import fleetest_mcp

final class ToolAnnotationsTests: XCTestCase {

    private var definitions: [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: MCPServer.toolDefinitions.map { ($0["name"] as! String, $0) })
    }

    func testEveryToolIsClassified() {
        XCTAssertEqual(Set(MCPServer.toolEffects.keys), Set(definitions.keys),
                       "ツールを足した・消したら ToolAnnotations.swift の toolEffects も直す")
        for (name, definition) in definitions {
            let annotations = definition["annotations"] as? [String: Any]
            XCTAssertNotNil(annotations?["readOnlyHint"] as? Bool, name)
            XCTAssertNotNil(annotations?["openWorldHint"] as? Bool, "\(name): 省くと true と読まれる")
        }
    }

    func testToolsThatRunProjectCodeAreNotReadOnly() {
        for name in ["ft_list_scenarios", "ft_dry_run", "ft_run_scenario", "ft_start_run"] {
            let annotations = definitions[name]?["annotations"] as? [String: Any]
            XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(annotations?["destructiveHint"] as? Bool, true, name)
            XCTAssertEqual(annotations?["openWorldHint"] as? Bool, true, name)
        }
    }

    func testToolsThatChangeTheDeviceAreNotReadOnly() {
        for name in ["ft_tap", "ft_type", "ft_launch", "ft_batch", "ft_clear_app_data", "ft_install",
                     "ft_capture_element", "ft_stop_run"] {
            let annotations = definitions[name]?["annotations"] as? [String: Any]
            XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, false, name)
        }
        for name in ["ft_clear_app_data", "ft_install"] {
            let annotations = definitions[name]?["annotations"] as? [String: Any]
            XCTAssertEqual(annotations?["destructiveHint"] as? Bool, true, name)
        }
    }
}
