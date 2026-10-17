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

    /// FM を撃つ箇所ごとに直前で種類を数える(外すとその種類が 0 のまま記録され、暖機と実要求の比較が黙って崩れる)
    func testEachFMCallSiteCountsItsKind() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTFoundationModels/FMServeServer.swift"),
                                encoding: .utf8)
        let pairs = [
            (".keepWarm", "try await keepAlive()"),
            (".prewarm", "prewarmSpare()"),
            (".transcribe", "try await transcribe(image)"),
            (".screen", "try await screen(image, expected: expected)"),
            (".probe", "try await probe(request.path ?? .vision)"),
        ]
        for (kind, call) in pairs {
            let note = try XCTUnwrap(source.range(of: "FMHostMemory.noteFMCall(\(kind))"), "\(kind) を数えていない")
            XCTAssertEqual(source.components(separatedBy: "FMHostMemory.noteFMCall(\(kind))").count, 2, "\(kind) は1箇所")
            let rest = source[note.upperBound...]
            let next = try XCTUnwrap(rest.range(of: call), "\(kind) の後に \(call) が無い")
            let between = rest[..<next.lowerBound]
            XCTAssertFalse(between.contains("FMHostMemory.noteFMCall("), "\(kind) の直後の呼び出しが \(call) ではない")
            XCTAssertLessThan(between.split(separator: "\n").count, 4, "\(kind) が \(call) の直前にない")
        }
    }
}
