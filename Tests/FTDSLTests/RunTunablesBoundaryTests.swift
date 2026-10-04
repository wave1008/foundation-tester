// ホスト(ScenarioHost.tunablesArgument)→ 子(RunScenario.decodeTunables)の往復。
// 型の効かない継ぎ目(JSON 文字列)なので値を変えて往復させる。

import XCTest
import FTCore
@testable import FTScenarioRunner

final class RunTunablesBoundaryTests: XCTestCase {

    func testHostArgumentRoundTripsThroughChildDecoder() throws {
        let sent = RunTunables(defaultTimeout: 7.5, commandTimeout: 33, injectedAppProbeTimeout: 4)
        let json = try ScenarioHost.tunablesArgument(sent)
        XCTAssertEqual(try RunScenario.decodeTunables(json), sent)
    }

    func testMissingOptionYieldsDefaults() throws {
        XCTAssertEqual(try RunScenario.decodeTunables(nil), RunTunables())
    }

    func testInvalidJSONThrowsInsteadOfFallingBackToDefaults() {
        XCTAssertThrowsError(try RunScenario.decodeTunables("not json"))
        XCTAssertThrowsError(try RunScenario.decodeTunables(#"{"defaultTimeout":7.5}"#),
                             "欄の欠けも既定へ倒さず止める")
    }
}
