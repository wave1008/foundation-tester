// fm-serve の周期(tick)がホストのメモリの採取を撃つ配線の固定(ソース走査)。外すと死の直前の推移が残らない。

import XCTest

final class FMHostMemoryWiringTests: XCTestCase {
    func testTickCallsSampleIfDue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTFoundationModelsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/FMServeServer.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static func tick("))
        let body = String(source[start.lowerBound...].prefix(1200))
        XCTAssertTrue(body.contains("FMHostMemory.sampleIfDue(now: now)"), "tick が採取を撃っていない")
    }
}
