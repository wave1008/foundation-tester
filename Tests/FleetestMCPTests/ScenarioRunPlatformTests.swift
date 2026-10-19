// `MCPServer.profileLessScenarioPlatform` — profile 無しの ft_run_scenario で、シナリオの platform 宣言が
// 呼び手の名指しした宛先(serial / udid / port / platform)を黙って上書きしないこと。
// 上書きすると、名指しした Emulator ではなく走査で見つかった iOS のブリッジのデバイスでシナリオが走る。

import XCTest
@testable import fleetest_mcp

final class ScenarioRunPlatformTests: XCTestCase {

    private func platform(_ declared: String?, _ args: [String: Any]) throws -> String {
        try MCPServer.profileLessScenarioPlatform(declared: declared, scenarioID: "A.S0010", args: args)
    }

    private func refusal(_ declared: String?, _ args: [String: Any]) -> String? {
        do {
            _ = try platform(declared, args)
            return nil
        } catch {
            return (error as? MCPError)?.message
        }
    }

    /// 宣言と逆の OS の宛先を名指ししたら断る(serial / port / udid / platform のどれでも)
    func testDeclarationThatContradictsTheNamedTargetIsRefused() {
        let bySerial = refusal("ios", ["serial": "emulator-5554"])
        XCTAssertNotNil(bySerial)
        XCTAssertTrue(bySerial?.contains("A.S0010 is declared for ios") == true, bySerial ?? "")
        XCTAssertTrue(bySerial?.contains("serial (an Android device)") == true, bySerial ?? "")
        XCTAssertNotNil(refusal("android", ["port": 8124]))
        XCTAssertNotNil(refusal("android", ["udid": "0000-1111"]))
        XCTAssertNotNil(refusal("android", ["platform": "ios"]))
    }

    /// 宣言と同じ OS を名指しした・何も名指ししていないなら宣言を採る
    func testDeclarationIsUsedWhenTheCallAgreesOrNamesNothing() throws {
        XCTAssertEqual(try platform("android", ["serial": "emulator-5554"]), "android")
        XCTAssertEqual(try platform("ios", ["port": 8124]), "ios")
        XCTAssertEqual(try platform("android", [:]), "android")
        XCTAssertEqual(try platform("ios", [:]), "ios")
    }

    /// 宣言の無いシナリオは呼び手の宛先から決める。`serial` だけなら android(`?? "ios"` に倒さない)
    func testUndeclaredScenarioFollowsTheNamedTarget() throws {
        XCTAssertEqual(try platform(nil, ["serial": "emulator-5554"]), "android")
        XCTAssertEqual(try platform(nil, ["port": 8124]), "ios")
        XCTAssertEqual(try platform(nil, ["platform": "android"]), "android")
        XCTAssertEqual(try platform(nil, [:]), "ios")
    }

    /// 記憶から差し込まれた宛先は呼び手の名指しではないので断らず、宣言を採る
    func testTargetInjectedFromMemoryDoesNotOverrideOrRefuse() throws {
        let injected: [String: Any] = ["port": 8124, "platform": "ios", MCPServer.deviceFromMemoryKey: true]
        XCTAssertEqual(try platform("android", injected), "android")
        XCTAssertEqual(try platform(nil, injected), "ios")
    }
}
