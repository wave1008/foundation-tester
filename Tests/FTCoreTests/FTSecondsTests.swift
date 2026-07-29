import XCTest

@testable import FTCore

/// FTSeconds.format の境界値と、FlowStep.timeout(Double 化)の JSON 往復を固定する。
/// 「破ったら落ちる」ことの確認対象: format の小数点有無の分岐、旧 Int JSON との互換。
final class FTSecondsTests: XCTestCase {
    func testFormatDropsDecimalPointForIntegralValues() {
        XCTAssertEqual(FTSeconds.format(5.0), "5")
        XCTAssertEqual(FTSeconds.format(0), "0")
    }

    func testFormatKeepsDecimalPointForFractionalValues() {
        XCTAssertEqual(FTSeconds.format(1.2), "1.2")
        XCTAssertEqual(FTSeconds.format(0.5), "0.5")
    }

    /// FlowStep(timeout: 1.2) が JSON へ往復し、小数が失われないこと
    func testFlowStepEncodesAndDecodesFractionalTimeout() throws {
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"), timeout: 1.2)
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(FlowStep.self, from: data)
        XCTAssertEqual(decoded.timeout, 1.2)
    }

    /// 既存プロファイル/ヒールキャッシュ由来の整数 JSON("timeout": 5)がそのまま Double へデコードできること
    /// (Double 化で既存データを壊さない回帰ガード)
    func testFlowStepDecodesLegacyIntegerTimeoutJSON() throws {
        let json = """
        { "assert": "exists", "locator": { "id": "msg" }, "timeout": 5 }
        """
        let decoded = try JSONDecoder().decode(FlowStep.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.timeout, 5)
    }
}
