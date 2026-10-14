import XCTest
@testable import fleetest_mcp

/// ft_services の引数の組み立てと入口の検査。CLI の実起動はテストしない(ビルドが要る)
final class MCPServicesToolTests: XCTestCase {

    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                           recordSnapshot: { _, _, _ in })
    }

    func testArgumentsAreComposedForEachAction() {
        XCTAssertEqual(MCPServices.arguments(action: "up", project: "P", profile: "ios"),
                       ["swift", "run", "fleetest", "services", "up", "--project", "P", "--profile", "ios"])
        XCTAssertEqual(MCPServices.arguments(action: "down", project: "P", profile: "ios"),
                       ["swift", "run", "fleetest", "services", "down", "--project", "P", "--profile", "ios"])
        XCTAssertEqual(MCPServices.arguments(action: "status", project: nil, profile: nil),
                       ["swift", "run", "fleetest", "services", "status"])
        XCTAssertEqual(MCPServices.arguments(action: "status", project: "P", profile: nil),
                       ["swift", "run", "fleetest", "services", "status", "--project", "P"])
        XCTAssertEqual(MCPServices.arguments(action: "up", project: "P", profile: "r", physical: true, serials: ["A1", "B2"]),
                       ["swift", "run", "fleetest", "services", "up", "--project", "P", "--profile", "r",
                        "--physical", "--serial", "A1", "--serial", "B2"])
        // physical / serial は up だけ(down / status には渡さない)
        XCTAssertEqual(MCPServices.arguments(action: "down", project: "P", profile: "r", physical: true, serials: ["A1"]),
                       ["swift", "run", "fleetest", "services", "down", "--project", "P", "--profile", "r"])
    }

    func testOptionLikeValuesAreRefused() {
        XCTAssertNotNil(MCPServices.optionLikeValueRefusal(project: nil, profile: "--set=x"))
        XCTAssertNotNil(MCPServices.optionLikeValueRefusal(project: " -p", profile: "ios"))
        XCTAssertNil(MCPServices.optionLikeValueRefusal(project: "P", profile: "ios"))
        XCTAssertNil(MCPServices.optionLikeValueRefusal(project: nil, profile: nil))
        XCTAssertNotNil(MCPServices.optionLikeValueRefusal(project: nil, profile: "ios", serials: ["A1", "-s"]))
    }

    func testOptionLikeValuesAreRefusedAtTheEntrance() async {
        let noProject = "no-such-project-for-this-test"
        await assertRefused(["action": "up", "profile": "--x", "project": noProject], contains: "profile must not start with \"-\"")
        await assertRefused(["action": "status", "project": "-x"], contains: "project must not start with \"-\"")
        await assertRefused(["action": "up", "profile": "ios", "androidSerials": ["--x"], "project": noProject],
                            contains: "androidSerials must not start with \"-\"")
    }

    /// **`project` に実在しない名前を添える** —— 入口の検査が(変異などで)抜けても、プロジェクトの解決で止まり、
    /// 本物の `swift run fleetest services …` を起こさない(起こすと `swift test` のビルドロックと待ち合って止まる)
    func testBadActionAndMissingProfileAreRefused() async {
        let noProject = "no-such-project-for-this-test"
        await assertRefused(["action": "restart", "profile": "ios", "project": noProject], contains: "action must be one of up, down, status")
        await assertRefused(["project": noProject], contains: "action is required")
        await assertRefused(["action": "up", "project": noProject], contains: "profile is required for action up")
        await assertRefused(["action": "down", "project": noProject], contains: "profile is required for action down")
    }

    func testResponseTextKeepsTheExitCodeAndTheTail() {
        let output = (1...300).map { "line\($0)" }.joined(separator: "\n")
        let text = MCPServices.responseText(action: "up", status: 3, output: output)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "fleetest services up: exit 3")
        XCTAssertEqual(lines.count, 201)
        XCTAssertEqual(lines[1], "line101")
        XCTAssertEqual(lines.last, "line300")
        XCTAssertEqual(MCPServices.responseText(action: "status", status: 0, output: ""),
                       "fleetest services status: exit 0")
    }

    private func assertRefused(_ args: [String: Any], contains expected: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await server.call(tool: "ft_services", args: args)
            XCTFail("ft_services should refuse \(args)", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(expected),
                          "\(error.localizedDescription)", file: file, line: line)
        }
    }
}
