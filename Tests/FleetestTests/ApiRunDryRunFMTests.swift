// `fleetest api run --dry-run` は FM を丸ごと切る(`fleetest run --dry-run` / `ft_dry_run` と同じ)。
// 以前は resolved の fm をそのまま通しており、失敗ステップごとに FM の直列化待ちを払っていた。

import XCTest
import FTCore
@testable import fleetest

final class ApiRunDryRunFMTests: XCTestCase {

    func testDryRunSwitchesFMOffEntirely() {
        var input = ScenarioExecutionSettings(fm: FMConfig(enabled: true, fmTextOcclusionCheck: true), heal: true)
        input.defaultTimeout = 7
        let out = ApiRun.withDryRunFM(input, dryRun: true)
        XCTAssertFalse(out.fm.enabled, "dry-run では FM を有効のまま通さない")
        XCTAssertFalse(out.fm.fmTextOcclusionCheck)
        XCTAssertEqual(out.defaultTimeout, 7, "fm 以外の欄は触らない")
        XCTAssertTrue(out.heal, "heal は FM ではないので触らない")
    }

    func testRealRunKeepsTheSettingsUntouched() {
        let input = ScenarioExecutionSettings(fm: FMConfig(enabled: true, fmTextOcclusionCheck: true), heal: true)
        let out = ApiRun.withDryRunFM(input, dryRun: false)
        XCTAssertEqual(out, input)
    }
}
