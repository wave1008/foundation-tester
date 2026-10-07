// 各シナリオの直前に、ソフトキーボードを縮めない設定を書き直す(XCUITest の Return で iOS が true に戻すため。
// ProfileWorkerFactory.keepSoftwareKeyboardShown の doc)。run の入口の2経路の両方が呼ぶこと

import XCTest

final class KeepSoftwareKeyboardWiringTests: XCTestCase {

    func testBothRunPathsReassertTheSoftwareKeyboardBeforeEachScenario() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest")
        for name in ["ProfileRunOrchestrator.swift", "Fleetest.swift"] {
            let source = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let start = try XCTUnwrap(source.range(of: "clearResidualSystemAlert: { worker in"), name)
            let hook = source[start.upperBound...].prefix(300)
            XCTAssertTrue(hook.contains("ProfileWorkerFactory.keepSoftwareKeyboardShown(worker: worker)"),
                          "\(name) の各シナリオ前の口がソフトキーボードの設定を書き直していない")
        }
    }
}
