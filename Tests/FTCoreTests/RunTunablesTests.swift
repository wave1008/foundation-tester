// RunTunables の既定値の固定と、プロファイル → ScenarioExecutionSettings の写像。
// 子プロセス境界の往復は Tests/FTDSLTests/RunTunablesBoundaryTests.swift。

import XCTest
@testable import FTCore

final class RunTunablesTests: XCTestCase {

    /// 既定はリテラルで固定する(production の定数で期待値を書くと既定を戻す変更が素通りする)
    func testDefaultsArePinned() {
        let t = RunTunables()
        XCTAssertEqual(t.defaultTimeout, 5)
        XCTAssertEqual(t.commandTimeout, 120)
        XCTAssertEqual(t.injectedAppProbeTimeout, 10)
        XCTAssertEqual(t.defaultMaxSwipes, 8)
        XCTAssertEqual(t.defaultSwipeDuration, 1.5)
        XCTAssertEqual(t.defaultFlickDuration, 0.25)
        XCTAssertEqual(t.defaultFlickInterval, 0.3)
        XCTAssertEqual(t.defaultPinchDuration, 0.5)
        XCTAssertEqual(t.defaultHoldDuration, 3)
        XCTAssertEqual(t.screenWaitTimeout, 15)
        XCTAssertEqual(t.doUntilTrueTimeout, 10)
        XCTAssertEqual(t.doUntilTrueInterval, 0.5)
        XCTAssertEqual(t.doUntilTrueMaxLoopCount, 100)
        XCTAssertEqual(t.httpRequestTimeout, 30)
        XCTAssertLessThan(t.httpRequestTimeout, t.commandTimeout, "httpRequest の待ちは壁時計の締切より小さく保つ")
    }

    func testProfileDefaultTimeoutMapsIntoTunables() {
        let settings = ScenarioExecutionSettings(DeviceIndependentRunSettings(
            fm: FMConfig(), heal: false, ocrTextOcclusionCheck: true, preferCheckStateClassifier: true,
            iosPreActionPing: true, containerInference: true, enableAnimations: false,
            playProtectBypass: true, homeOnStart: true, record: false, recordFailuresOnly: false,
            recordFullResolution: false, reportDir: nil, defaultTimeout: 12.5, scenarioTimeout: nil,
            recordBitrateKbps: nil))
        XCTAssertEqual(settings.tunables.defaultTimeout, 12.5)
        XCTAssertEqual(settings.tunables.commandTimeout, 120, "プロファイルに無い欄は既定のまま")
    }

    func testUnspecifiedProfileDefaultTimeoutStaysDefault() {
        let settings = ScenarioExecutionSettings(DeviceIndependentRunSettings(
            fm: FMConfig(), heal: false, ocrTextOcclusionCheck: true, preferCheckStateClassifier: true,
            iosPreActionPing: true, containerInference: true, enableAnimations: false,
            playProtectBypass: true, homeOnStart: true, record: false, recordFailuresOnly: false,
            recordFullResolution: false, reportDir: nil, defaultTimeout: nil, scenarioTimeout: nil,
            recordBitrateKbps: nil))
        XCTAssertEqual(settings.tunables.defaultTimeout, 5)
    }

    func testHostArgumentIsSortedKeyJSON() throws {
        let json = try ScenarioHost.tunablesArgument(
            RunTunables(defaultTimeout: 7.5, commandTimeout: 33, injectedAppProbeTimeout: 4,
                        defaultMaxSwipes: 3, defaultSwipeDuration: 2.5, defaultFlickDuration: 0.75,
                        defaultFlickInterval: 0.6, defaultPinchDuration: 1.25, defaultHoldDuration: 4,
                        screenWaitTimeout: 21, doUntilTrueTimeout: 12, doUntilTrueInterval: 0.75,
                        doUntilTrueMaxLoopCount: 7, httpRequestTimeout: 9))
        XCTAssertEqual(json, #"{"commandTimeout":33,"defaultFlickDuration":0.75,"defaultFlickInterval":0.6,"#
            + #""defaultHoldDuration":4,"defaultMaxSwipes":3,"defaultPinchDuration":1.25,"#
            + #""defaultSwipeDuration":2.5,"defaultTimeout":7.5,"doUntilTrueInterval":0.75,"#
            + #""doUntilTrueMaxLoopCount":7,"doUntilTrueTimeout":12,"httpRequestTimeout":9,"injectedAppProbeTimeout":4,"#
            + #""screenWaitTimeout":21}"#)
    }
}
