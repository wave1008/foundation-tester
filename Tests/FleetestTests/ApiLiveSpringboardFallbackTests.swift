import XCTest
@testable import fleetest

/// 木が読めないときの springboard 退避は iOS だけ(Android の 422 は a11y 根の一時欠落で、
/// そこへ com.apple.springboard の launch を撃つと 500 に化けて元の事実が消えた。実地 2026-09-24)
final class ApiLiveSpringboardFallbackTests: XCTestCase {
    func testOnlyIOSFallsBackToSpringboard() {
        XCTAssertTrue(ApiLiveServe.usesSpringboardFallback(platform: "ios"))
        XCTAssertFalse(ApiLiveServe.usesSpringboardFallback(platform: "android"))
    }

    /// 退避の catch 節が platform の判定を通っていること(判定だけ正しくて配線が無い形を落とす)
    func testFallbackCatchIsGatedByPlatform() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        guard let start = code.range(of: "private func snapshotWithSessionFallback("),
              let end = code.range(of: "static func usesSpringboardFallback(") else {
            return XCTFail("snapshotWithSessionFallback が見当たらない — テストを見直すこと")
        }
        let body = String(code[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("Self.usesSpringboardFallback(platform: driverOptions.resolvedPlatform)"),
                      "springboard 退避の catch が platform で絞られていない")
    }
}
