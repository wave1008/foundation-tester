// 縁またぎの判定(DSL の寄せと MCP の警告が共有する `TapTargetGeometry.straddlingContainerEdge`)。

import XCTest
@testable import FTCore

final class StraddlingContainerEdgeTests: XCTestCase {

    private let container = FTRect(x: 16, y: 300, width: 370, height: 300)

    private func elements(rowY: Double) -> [ElementInfo] {
        [
            ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil,
                        placeholder: nil, enabled: true, frame: container, depth: 1),
            ElementInfo(ref: 2, type: "clickable", identifier: "a", label: "A", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 16, y: 400, width: 370, height: 56), depth: 2),
            ElementInfo(ref: 3, type: "clickable", identifier: "b", label: "B", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 16, y: 460, width: 370, height: 56), depth: 2),
            ElementInfo(ref: 4, type: "clickable", identifier: "target", label: "T", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 16, y: rowY, width: 370, height: 56), depth: 2),
        ]
    }

    func testStraddlingRowIsDetectedWithAJumpAndAWarning() throws {
        let tree = elements(rowY: container.y - 30)
        let target = try XCTUnwrap(tree.first { $0.ref == 4 })
        let hit = try XCTUnwrap(TapTargetGeometry.straddlingContainerEdge(target, in: tree))
        XCTAssertLessThan(hit.jump, 0, "上端をまたぐので負(指を下へ)の寄せ量")
        XCTAssertNotNil(TapTargetGeometry.straddleAdvisory(for: target, in: tree))
    }

    func testFullyInsideRowIsNotFlagged() throws {
        let tree = elements(rowY: container.y + 200)
        let target = try XCTUnwrap(tree.first { $0.ref == 4 })
        XCTAssertNil(TapTargetGeometry.straddlingContainerEdge(target, in: tree))
        XCTAssertNil(TapTargetGeometry.straddleAdvisory(for: target, in: tree))
    }

    func testFullyOutsideRowIsNotFlagged() throws {
        let tree = elements(rowY: container.y - 200)
        let target = try XCTUnwrap(tree.first { $0.ref == 4 })
        XCTAssertNil(TapTargetGeometry.straddlingContainerEdge(target, in: tree),
                     "完全に容器の外(ghost)はまたぎではない")
    }

    /// MCP の ft_tap が共有の警告を実際に呼んでいる(配線)
    func testMCPTapUsesTheSharedStraddleAdvisory() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/fleetest-mcp/MCPServer+Snapshot.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("TapTargetGeometry.straddleAdvisory("))
        let dsl = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/StepExecutor+Actions.swift"),
                             encoding: .utf8)
        XCTAssertTrue(dsl.contains("TapTargetGeometry.straddlingContainerEdge("))
    }
}
