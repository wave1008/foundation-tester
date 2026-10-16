// ft_fold の引数検査と、折りたたみ機での開閉(FoldControl の判定は FTCoreTests 側)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPFoldTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    private func failure(_ args: [String: Any]) async -> String {
        do {
            _ = try await server.call(tool: "ft_fold", args: args)
            XCTFail("expected a refusal for \(args)")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    func testRequiresExactlyOneOfStateOrDegrees() async {
        let neither = await failure(["platform": "android"])
        XCTAssertTrue(neither.contains("exactly one of state"), neither)
        let both = await failure(["platform": "android", "state": "fold", "degrees": 0.0])
        XCTAssertTrue(both.contains("not both"), both)
        XCTAssertFalse(driver.calls.contains("setHingeAngle(0.0)"), "\(driver.calls)")
    }

    func testRejectsUnknownStateAndOutOfRangeDegrees() async {
        let state = await failure(["platform": "android", "state": "half"])
        XCTAssertTrue(state.contains("\"fold\" or \"unfold\""), state)
        for degrees in [-1.0, 181.0] {
            let message = await failure(["platform": "android", "degrees": degrees])
            XCTAssertTrue(message.contains("degrees"), message)
        }
        XCTAssertTrue(driver.calls.filter { $0.hasPrefix("setHingeAngle") }.isEmpty, "\(driver.calls)")
    }

    func testNotFoldableDeviceSendsNothing() async {
        driver.scriptedFoldObservations = [.notFoldable]
        let message = await failure(["platform": "android", "state": "unfold"])
        XCTAssertTrue(message.contains("not foldable"), message)
        XCTAssertTrue(driver.calls.filter { $0.hasPrefix("setHingeAngle") }.isEmpty, "\(driver.calls)")
    }

    func testUnfoldSendsTheHingeAngleAndReturnsTheTree() async throws {
        driver.scriptedFoldObservations = [.state(.folded), .state(.unfolded)]
        let result = try await server.call(tool: "ft_fold", args: ["platform": "android", "state": "unfold"])
        let text = result.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.hasPrefix("Unfolded."), text)
        XCTAssertTrue(driver.calls.contains("setHingeAngle(180.0)"), "\(driver.calls)")
    }

    func testDefinitionIsDeclaredWithTheDrivesDeviceEffect() {
        XCTAssertEqual(MCPServer.toolEffects["ft_fold"], .drivesDevice)
        let definition = MCPServer.toolDefinitions.first { $0["name"] as? String == "ft_fold" }
        XCTAssertNotNil(definition)
    }
}
