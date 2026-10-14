import XCTest
@testable import FTCore

final class HooksSettingsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-hooks-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func config(_ json: String) throws -> URL {
        let url = dir.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    func testMissingFileOrMissingSectionIsNil() throws {
        XCTAssertNil(try HooksSettings.load(configURL: dir.appendingPathComponent("none.json"), home: "/h"))
        XCTAssertNil(try HooksSettings.load(configURL: try config("{\"sandbox\": {}}"), home: "/h"))
    }

    func testUnknownKeyIsRefused() throws {
        let url = try config("{\"hooks\": {\"writablePath\": []}}")
        XCTAssertThrowsError(try HooksSettings.load(configURL: url, home: "/h")) { error in
            XCTAssertEqual(error as? HooksSettings.ConfigError,
                           .unknownKeys(url.path, keys: ["writablePath"]))
        }
    }

    func testRelativeAndEmptyEntriesAreRefused() throws {
        for entry in ["data", "./data", ""] {
            let url = try config("{\"hooks\": {\"writablePaths\": [\"\(entry)\"]}}")
            XCTAssertThrowsError(try HooksSettings.load(configURL: url, home: "/h"), entry) { error in
                guard case .invalidValue(_, let key, _)? = error as? HooksSettings.ConfigError else {
                    return XCTFail("\(error)")
                }
                XCTAssertEqual(key, "writablePaths")
            }
        }
    }

    func testTildeIsExpandedAgainstTheGivenHome() throws {
        let url = try config("{\"hooks\": {\"writablePaths\": [\"~/x\", \"/abs/y\"]}}")
        let settings = try HooksSettings.load(configURL: url, home: "/Users/someone")
        XCTAssertEqual(settings?.writablePaths, ["/Users/someone/x", "/abs/y"])
    }

    func testHooksSectionWithoutPathsLoadsAsEmptySettings() throws {
        let settings = try HooksSettings.load(configURL: try config("{\"hooks\": {}}"), home: "/h")
        XCTAssertEqual(settings, HooksSettings())
    }

    private let protected = [(label: "scripts", path: "/ws/scripts")]

    private func overlap(_ entry: String) -> HooksSettings.ConfigError? {
        do { try HooksSettings.validate(writablePaths: [entry], protected: protected); return nil }
        catch { return error as? HooksSettings.ConfigError }
    }

    func testEqualInsideAndEnclosingEntriesAreRefusedWithTheLabel() {
        let expected = { (entry: String) in
            HooksSettings.ConfigError.overlapsProtectedLocation(path: entry, protected: "scripts")
        }
        XCTAssertEqual(overlap("/ws/scripts"), expected("/ws/scripts"))
        XCTAssertEqual(overlap("/ws/scripts/sub"), expected("/ws/scripts/sub"))
        XCTAssertEqual(overlap("/ws"), expected("/ws"))
    }

    func testDisjointEntriesPass() throws {
        XCTAssertNil(overlap("/ws/scripts2"))
        XCTAssertNil(overlap("/elsewhere"))
        try HooksSettings.validate(writablePaths: [], protected: protected)
    }
}
