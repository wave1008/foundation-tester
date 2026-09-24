// ref と x/y (ft_drag は fromRef/fromX,fromY・toX/dx・toY/dy) を同時に渡すと、後発の枝が
// 黙って捨てられていた(B2。実測: `ft_tap {ref:1, x:1, y:1}` → "tap [1] done."。x/y は未読)。
// `MCPServer.targetExclusivityViolation` が入口で断ることを表の全ツールぶん固定する。

import XCTest
@testable import fleetest_mcp

final class TargetExclusivityTests: XCTestCase {

    private func refusal(_ tool: String, _ args: [String: Any]) -> String? {
        MCPServer.targetExclusivityViolation(tool: tool, args: args)
    }

    func testTapRefAndCoordinatesTogetherIsRefused() {
        XCTAssertNotNil(refusal("ft_tap", ["ref": 1, "x": 1.0, "y": 2.0]))
    }

    func testTapRefOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_tap", ["ref": 1]))
    }

    func testTapCoordinatesOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_tap", ["x": 1.0, "y": 2.0]))
    }

    func testDoubleTapRefAndCoordinatesTogetherIsRefused() {
        XCTAssertNotNil(refusal("ft_double_tap", ["ref": 1, "x": 1.0, "y": 2.0]))
    }

    func testDoubleTapRefOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_double_tap", ["ref": 1]))
    }

    func testDoubleTapCoordinatesOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_double_tap", ["x": 1.0, "y": 2.0]))
    }

    func testLongPressRefAndCoordinatesTogetherIsRefused() {
        XCTAssertNotNil(refusal("ft_long_press", ["ref": 1, "x": 1.0, "y": 2.0]))
    }

    func testLongPressRefOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_long_press", ["ref": 1]))
    }

    func testLongPressCoordinatesOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_long_press", ["x": 1.0, "y": 2.0]))
    }

    func testPinchRefAndCoordinatesTogetherIsRefused() {
        XCTAssertNotNil(refusal("ft_pinch", ["ref": 1, "x": 1.0, "y": 2.0]))
    }

    func testPinchRefOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_pinch", ["ref": 1]))
    }

    func testPinchCoordinatesOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_pinch", ["x": 1.0, "y": 2.0]))
    }

    func testDragFromRefAndFromCoordinatesTogetherIsRefused() {
        XCTAssertNotNil(refusal("ft_drag", ["fromRef": 1, "fromX": 1.0, "fromY": 2.0, "dx": 10.0]))
    }

    func testDragFromRefOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_drag", ["fromRef": 1, "dx": 10.0]))
    }

    func testDragFromCoordinatesOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_drag", ["fromX": 1.0, "fromY": 2.0, "dx": 10.0]))
    }

    func testDragToXAndDxTogetherIsRefused() {
        XCTAssertNotNil(refusal("ft_drag", ["fromX": 1.0, "fromY": 2.0, "toX": 40.0, "dx": 10.0]))
    }

    func testDragToXOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_drag", ["fromX": 1.0, "fromY": 2.0, "toX": 40.0]))
    }

    func testDragDxOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_drag", ["fromX": 1.0, "fromY": 2.0, "dx": 10.0]))
    }

    func testDragToYAndDyTogetherIsRefused() {
        XCTAssertNotNil(refusal("ft_drag", ["fromX": 1.0, "fromY": 2.0, "toY": 40.0, "dy": 10.0]))
    }

    func testDragToYOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_drag", ["fromX": 1.0, "fromY": 2.0, "toY": 40.0]))
    }

    func testDragDyOnlyIsAllowed() {
        XCTAssertNil(refusal("ft_drag", ["fromX": 1.0, "fromY": 2.0, "dy": 10.0]))
    }

    /// `call()` の入口で実際に断ること・デバイスへ一度も触れないことを1本だけ end-to-end で確かめる
    /// (残りは純粋関数の単体で足りる)
    func testCallRefusesBeforeTouchingTheDriver() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        do {
            _ = try await server.call(tool: "ft_pinch", args: ["ref": 1, "x": 1.0, "y": 2.0])
            XCTFail("ref と x/y の併用が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ft_pinch takes either ref or x/y, not both"),
                          error.localizedDescription)
        }
        XCTAssertTrue(driver.calls.isEmpty, "デバイスに触れる前に断るはず: \(driver.calls)")
    }
}
