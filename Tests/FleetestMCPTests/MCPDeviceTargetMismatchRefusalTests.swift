// platform と宛先(udid/port/serial)が食い違う呼び出しは、撃つ前に断る(判定は
// FTCore.DeviceTargetConsistency。CLI の DriverOptions.validate() と共有)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPDeviceTargetMismatchRefusalTests: XCTestCase {

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

    private func assertRefusedBeforeDriving(_ args: [String: Any], contains fragment: String,
                                            file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await server.call(tool: "ft_snapshot", args: args)
            XCTFail("mismatched platform/target must be refused: \(args)", file: file, line: line)
        } catch {
            let message = (error as? MCPError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains(fragment), message, file: file, line: line)
        }
        XCTAssertEqual(driverResolved, 0, "no device may be resolved (or driven) before refusing",
                       file: file, line: line)
    }

    func testSerialWithPlatformIOSIsRefused() async {
        await assertRefusedBeforeDriving(["serial": "emulator-5554", "platform": "ios"],
                                         contains: "platform is \"ios\" but serial")
    }

    func testUDIDWithPlatformAndroidIsRefused() async {
        await assertRefusedBeforeDriving(["udid": "257324AF-0000", "platform": "android"],
                                         contains: "platform is \"android\" but udid/port")
    }

    func testPortWithPlatformAndroidIsRefused() async {
        await assertRefusedBeforeDriving(["port": 8130, "platform": "android"],
                                         contains: "platform is \"android\" but udid/port")
    }

    func testUDIDAndSerialWithNoPlatformIsRefused() async {
        await assertRefusedBeforeDriving(["udid": "257324AF-0000", "serial": "emulator-5554"],
                                         contains: "no platform to say which one to use")
    }

    /// ft_logs は udid を持たず port/serial だけを持つ——同じ規則が port/serial の組でも効くこと
    func testPortAndSerialWithNoPlatformIsRefusedEvenWithoutUDID() async {
        do {
            _ = try await server.call(tool: "ft_logs", args: ["port": 8130, "serial": "emulator-5554"])
            XCTFail("port + serial with no platform must be refused")
        } catch {
            let message = (error as? MCPError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("no platform to say which one to use"), message)
        }
    }

    // MARK: - 断ってはいけない組み合わせ

    func testPlatformOmittedWithOnlySerialIsNotRefused() {
        XCTAssertNil(MCPServer.deviceTargetMismatchRefusal(["serial": "emulator-5554"]))
    }

    func testPlatformAndroidWithSerialIsNotRefused() {
        XCTAssertNil(MCPServer.deviceTargetMismatchRefusal(["platform": "android", "serial": "emulator-5554"]))
    }

    func testPlatformIOSWithUDIDAndPortIsNotRefused() {
        XCTAssertNil(MCPServer.deviceTargetMismatchRefusal(
            ["platform": "ios", "udid": "257324AF-0000", "port": 8130]))
    }

    func testEverythingOmittedIsNotRefused() {
        XCTAssertNil(MCPServer.deviceTargetMismatchRefusal([:]))
    }
}
