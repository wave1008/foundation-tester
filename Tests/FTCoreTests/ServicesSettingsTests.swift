import XCTest
@testable import FTCore

final class ServicesSettingsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-services-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func load(_ json: String) throws -> ServicesSettings? {
        let url = dir.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: url)
        return try ServicesSettings.load(configURL: url)
    }

    func testValidSettingsLoad() throws {
        let s = try load(#"{"services":{"runtime":"docker","buildSources":["/src/a"],"publishForPhysicalDevices":"192.168.1.20"}}"#)
        XCTAssertEqual(s, ServicesSettings(runtime: .docker, buildSources: ["/src/a"],
                                           publishForPhysicalDevices: "192.168.1.20"))
    }

    func testMissingFileOrSectionIsNil() throws {
        XCTAssertNil(try ServicesSettings.load(configURL: dir.appendingPathComponent("none.json")))
        XCTAssertNil(try load(#"{"defaultProject":"x"}"#))
    }

    func testUnknownKeyThrows() {
        XCTAssertThrowsError(try load(#"{"services":{"runtme":"docker"}}"#)) {
            guard case ServicesSettings.ConfigError.unknownKeys(_, let keys) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(keys, ["runtme"])
        }
    }

    func testInvalidRuntimeThrows() {
        XCTAssertThrowsError(try load(#"{"services":{"runtime":"podman"}}"#)) {
            guard case ServicesSettings.ConfigError.invalidValue(_, let key, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(key, "runtime")
        }
    }

    func testRelativeAndTildeBuildSourcesThrow() {
        for bad in ["rel/path", "~/src"] {
            XCTAssertThrowsError(try load(#"{"services":{"buildSources":["\#(bad)"]}}"#)) {
                guard case ServicesSettings.ConfigError.invalidValue(_, let key, _) = $0 else { return XCTFail("\($0)") }
                XCTAssertEqual(key, "buildSources")
            }
        }
    }

    func testNonIPv4AddressThrows() {
        for bad in ["host.local", "192.168.1", "192.168.1.256", "192.168.01.1", "::1", ""] {
            XCTAssertThrowsError(try load(#"{"services":{"publishForPhysicalDevices":"\#(bad)"}}"#), bad)
        }
    }
}
