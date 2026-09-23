// 宛先(udid/port/serial)を取らないツールは、引数に udid が添えられていても
// **ブリッジの解決を撃たない**。撃つと、端末を1つ駆動している呼び手(udid を毎回添える)は
// ブリッジが死んだ瞬間に一覧・診断のツールまで失い、しかも文面が案内する `ft_list_devices`
// 自身が同じ「no running bridge」を返す袋小路になる(実地 2026-09-23 の負荷テスト)。
//
// 門は `MCPServer.call` の `toolAcceptsDeviceTarget(tool)` 分岐1箇所。

import XCTest
@testable import fleetest_mcp

final class DeviceIndependentToolsIgnoreTargetTests: XCTestCase {

    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                           recordSnapshot: { _, _, _ in })
    }

    /// 宛先を取らないツールの集合を等号で固定する。**新しいツールを足したらここで止まる** ——
    /// 宛先を取らない側に入るなら下の門が効くことを、取る側なら従来どおりの解決が要ることを確かめる
    func testDeviceIndependentToolSetIsPinned() {
        let independent = Set(MCPServer.toolDefinitions.compactMap { definition -> String? in
            guard let name = definition["name"] as? String else { return nil }
            return MCPServer.toolAcceptsDeviceTarget(name) ? nil : name
        })
        XCTAssertEqual(independent, [
            "ft_list_devices", "ft_list_projects", "ft_list_scenarios",
            "ft_dsl_commands", "ft_dry_run", "ft_draft_scenario", "ft_doctor",
        ])
    }

    /// ブリッジの居ない udid を添えても、宛先を取らないツールは「no running bridge」で落ちない。
    /// (デバイス IO を持たない2つで踏む —— 一覧系はホストの simctl/adb を触るので別の砦の担当)
    func testDeadUDIDDoesNotBlockDeviceIndependentTools() async {
        for tool in ["ft_dsl_commands", "ft_list_projects"] {
            do {
                _ = try await server.call(tool: tool, args: ["udid": "no-such-simulator-udid-0000"])
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("no running bridge"),
                               "\(tool): \(error.localizedDescription)")
            }
        }
    }

    /// 逆向き: 宛先を取るツールは従来どおり udid を解決し、居なければ名指しで断る
    func testDeviceTargetToolStillResolvesTheUDID() async {
        do {
            _ = try await server.call(tool: "ft_snapshot", args: ["udid": "no-such-simulator-udid-0000"])
            XCTFail("ブリッジの居ない udid が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no running bridge"),
                          error.localizedDescription)
        }
    }
}
