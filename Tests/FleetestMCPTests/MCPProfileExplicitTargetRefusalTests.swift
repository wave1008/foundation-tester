// デバイス操作系のツールで profile と udid/port/serial を併用したら、撃つ前に断る。
// profile の枝は宛先をプロファイルから決め明示の宛先を見ないので、通すと名指ししていない台を操作する。
// platform は併用してよい(プロファイル内の OS を選ぶ)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPProfileExplicitTargetRefusalTests: XCTestCase {

    private var driverResolved = 0
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driverResolved = 0
        server = MCPServer(write: { _ in }, makeDriver: { [unowned self] _ in
            self.driverResolved += 1
            return FakeDriver()
        }, recordSnapshot: { _, _, _ in })
    }

    private func assertRefusedBeforeDriving(_ args: [String: Any], file: StaticString = #filePath,
                                            line: UInt = #line) async {
        do {
            _ = try await server.call(tool: "ft_snapshot", args: args)
            XCTFail("profile + explicit target must be refused: \(args)", file: file, line: line)
        } catch {
            let message = (error as? MCPError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("cannot be combined with udid/port/serial"), message,
                          file: file, line: line)
            XCTAssertTrue(message.contains("\"ios-inapp\""), message, file: file, line: line)
        }
        XCTAssertEqual(driverResolved, 0, "no device may be resolved (or driven) before refusing",
                       file: file, line: line)
    }

    func testProfileWithUDIDIsRefused() async {
        await assertRefusedBeforeDriving(["profile": "ios-inapp", "udid": "257324AF-0000"])
    }

    func testProfileWithPortIsRefused() async {
        await assertRefusedBeforeDriving(["profile": "ios-inapp", "port": 8130])
    }

    func testProfileWithSerialIsRefused() async {
        await assertRefusedBeforeDriving(["profile": "ios-inapp", "serial": "emulator-5554"])
    }

    /// platform はプロファイル内の OS を選ぶだけなので断らない
    func testProfileWithPlatformOnlyIsNotRefused() {
        XCTAssertNil(MCPServer.profileWithExplicitTargetRefusal(["profile": "ios-inapp", "platform": "ios"]))
    }

    /// 空の udid/serial は「指定なし」(argsGaveIOSTarget と同じ読み)
    func testEmptyTargetsDoNotCountAsExplicit() {
        XCTAssertNil(MCPServer.profileWithExplicitTargetRefusal(["profile": "ios-inapp", "udid": "", "serial": ""]))
    }

    func testExplicitTargetWithoutProfileIsNotRefused() {
        XCTAssertNil(MCPServer.profileWithExplicitTargetRefusal(["udid": "257324AF-0000"]))
    }
}
