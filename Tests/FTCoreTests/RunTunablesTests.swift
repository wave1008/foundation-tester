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
    }

    func testProfileDefaultTimeoutMapsIntoTunables() {
        let settings = ScenarioExecutionSettings(DeviceIndependentRunSettings(
            fm: FMConfig(), heal: false, ocrTextOcclusionCheck: true, preferCheckStateClassifier: true,
            iosFastInput: false,
            iosPreActionWarmup: true, containerInference: true, enableAnimations: false,
            playProtectBypass: true, homeOnStart: true, record: false, recordFailuresOnly: false,
            recordFullResolution: false, reportDir: nil, defaultTimeout: 12.5, scenarioTimeout: nil,
            recordBitrateKbps: nil))
        XCTAssertEqual(settings.tunables.defaultTimeout, 12.5)
        XCTAssertEqual(settings.tunables.commandTimeout, 120, "プロファイルに無い欄は既定のまま")
    }

    func testUnspecifiedProfileDefaultTimeoutStaysDefault() {
        let settings = ScenarioExecutionSettings(DeviceIndependentRunSettings(
            fm: FMConfig(), heal: false, ocrTextOcclusionCheck: true, preferCheckStateClassifier: true,
            iosFastInput: false,
            iosPreActionWarmup: true, containerInference: true, enableAnimations: false,
            playProtectBypass: true, homeOnStart: true, record: false, recordFailuresOnly: false,
            recordFullResolution: false, reportDir: nil, defaultTimeout: nil, scenarioTimeout: nil,
            recordBitrateKbps: nil))
        XCTAssertEqual(settings.tunables.defaultTimeout, 5)
    }

    func testHostArgumentIsSortedKeyJSON() throws {
        let json = try ScenarioHost.tunablesArgument(
            RunTunables(defaultTimeout: 7.5, commandTimeout: 33, injectedAppProbeTimeout: 4))
        XCTAssertEqual(json, #"{"commandTimeout":33,"defaultTimeout":7.5,"injectedAppProbeTimeout":4}"#)
    }
}
