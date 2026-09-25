// 座標コマンド(`tap(x:y:)` / `swipePointToPoint`)は FlowStep を組んで StepExecutor を通す。
// ドライバを直に叩く形へ戻ると、システム UI の門・直前の操作記録のリセット・hybrid の drag フォールバック
// (dragWithFallback)が座標経路だけ効かなくなる(ft_batch の `tap x: y:` とも挙動が割れる)

import XCTest

final class CoordinateCommandsRouteTests: XCTestCase {

    func testCoordinateCommandsDoNotDriveTheDriverDirectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/Commands.swift"),
                                encoding: .utf8)
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for call in [".drag(fromX:", ".tap(x:", ".press(x:", "performCustom("] {
            XCTAssertFalse(code.contains(call), "Commands.swift が \(call) を直に呼んでいる — FlowStep を通すこと")
        }
        // 走査が空振りしていないこと(対象の関数が実在する)
        XCTAssertTrue(code.contains("func coordinateTap("))
        XCTAssertTrue(code.contains("action: \"swipePointToPoint\""))
    }
}
