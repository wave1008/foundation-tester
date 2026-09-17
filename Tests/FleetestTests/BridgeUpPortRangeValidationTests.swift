// `fleetest bridge up --port` はブリッジの走査範囲(BridgeDiscovery.portRange)の外だと、
// run/MCP のどちらからも見つからない孤立ブリッジを作ってしまう(実測 2026-09-17:
// --port 8190 は起動できたが、既定の走査範囲 8123...8154 の外で誰にも発見されなかった)。

import XCTest
import ArgumentParser
@testable import fleetest

final class BridgeUpPortRangeValidationTests: XCTestCase {

    // 実際の走査範囲(8123...8154)をここへ持ち込まない —— production の定数を期待値に使うと、
    // 定数を動かした変更がこのテストを黙って通してしまう
    private let range: ClosedRange<UInt16> = 100...200

    func testAPortInsideTheRangeIsAccepted() throws {
        XCTAssertNoThrow(try Bridge.Up.validatePort(150, in: range))
    }

    func testAPortOutsideTheRangeIsRejectedWithTheRangeNamed() {
        XCTAssertThrowsError(try Bridge.Up.validatePort(9999, in: range)) { error in
            guard let validation = error as? ValidationError else {
                return XCTFail("expected ValidationError, got \(error)")
            }
            XCTAssertTrue(validation.message.contains("9999"), validation.message)
            XCTAssertTrue(validation.message.contains("100") && validation.message.contains("200"),
                          validation.message)
        }
    }

    /// 省略(--port を渡さない)は既定ポートに解決される呼び出し元の責務。ここでは弾かない
    func testOmittingThePortIsAccepted() throws {
        XCTAssertNoThrow(try Bridge.Up.validatePort(nil, in: range))
    }

    func testBothBoundsThemselvesAreInsideTheRange() throws {
        XCTAssertNoThrow(try Bridge.Up.validatePort(range.lowerBound, in: range))
        XCTAssertNoThrow(try Bridge.Up.validatePort(range.upperBound, in: range))
    }

    func testOneBelowTheLowerBoundIsRejected() {
        XCTAssertThrowsError(try Bridge.Up.validatePort(range.lowerBound - 1, in: range))
    }
}
