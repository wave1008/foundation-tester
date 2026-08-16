// MeasurementValidity.verdict の判定規則(performanceMode のときだけ判定する)。

import XCTest
@testable import FTCore

final class MeasurementValidityTests: XCTestCase {

    /// **本丸1**: 既定モードは証跡があっても判定しない。「performanceMode のときだけ判定する」
    /// のガード(`guard performanceMode else { ... }`)を外す変異が入ると、この値でも
    /// invalid=true になり落ちる
    func testDefaultModeIsAlwaysValidEvenWithEvidence() {
        let verdict = MeasurementValidity.verdict(
            performanceMode: false, degradedWorkers: ["ios:iphone-a: frozen"],
            blankExclusions: ["android:pixel-b"])
        XCTAssertFalse(verdict.invalid)
        XCTAssertTrue(verdict.reasons.isEmpty)
    }

    func testPerformanceModeWithNoEvidenceIsValid() {
        let verdict = MeasurementValidity.verdict(
            performanceMode: true, degradedWorkers: [], blankExclusions: [])
        XCTAssertFalse(verdict.invalid)
        XCTAssertTrue(verdict.reasons.isEmpty)
    }

    /// **本丸2**: degradedWorkers を見なくなる変異(`!degradedWorkers.isEmpty` を常に false 等)が
    /// 入ると、この呼び出しは invalid=false のまま通り落ちる
    func testPerformanceModeWithDegradedWorkersIsInvalidAndCountsThem() {
        let verdict = MeasurementValidity.verdict(
            performanceMode: true, degradedWorkers: ["android:pixel-a: unreachable", "android:pixel-b: frozen"],
            blankExclusions: [])
        XCTAssertTrue(verdict.invalid)
        XCTAssertEqual(verdict.reasons, ["2 lane(s) degraded or dropped during the run"])
    }

    /// **本丸3**: blankExclusions を見なくなる変異が入ると、この呼び出しは invalid=false のまま
    /// 通り落ちる(degradedWorkers 側だけ見て blankExclusions を無視するリグレッションを検出)
    func testPerformanceModeWithBlankExclusionsIsInvalidAndCountsThem() {
        let verdict = MeasurementValidity.verdict(
            performanceMode: true, degradedWorkers: [], blankExclusions: ["android:pixel-c"])
        XCTAssertTrue(verdict.invalid)
        XCTAssertEqual(verdict.reasons, ["1 lane(s) excluded before the run started (blank screen)"])
    }

    /// 両方あるときは reasons が2本(片方だけ拾って早期returnする変異を検出)
    func testPerformanceModeWithBothKindsOfEvidenceReportsBothReasons() {
        let verdict = MeasurementValidity.verdict(
            performanceMode: true, degradedWorkers: ["ios:iphone-a: frozen"],
            blankExclusions: ["android:pixel-b", "android:pixel-c"])
        XCTAssertTrue(verdict.invalid)
        XCTAssertEqual(verdict.reasons, [
            "1 lane(s) degraded or dropped during the run",
            "2 lane(s) excluded before the run started (blank screen)"
        ])
    }
}
