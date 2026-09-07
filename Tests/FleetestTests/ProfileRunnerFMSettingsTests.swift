// CLI の --heal/--no-heal/--no-false-positive-check → ProfileRunner.effectiveFMSettings の写像。
// run.json の fmSettings が「プロファイルの値」でなく「実効値」(CLI 上書き後)を記録することを
// 固定する。ProfileRunnerHealOverrideTests と同じ理由でデバイスの要らない純粋関数へ切り出してある。

import XCTest
@testable import FTCore
@testable import fleetest

final class ProfileRunnerFMSettingsTests: XCTestCase {

    /// memberwise init は internal なので `@testable import FTCore` で触る
    /// (ResolvedProfileDeviceScopeTests と同じ手段)
    private func profile(fm: FMConfig, ocr: Bool = true, ocrFalsePositiveCheck: Bool = true) -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "p", machineName: "local", appName: "app", apps: [:],
            devices: [], fm: fm,
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosFastInput: false, iosPreActionWarmup: true, containerInference: true,
            ocr: ocr, ocrFalsePositiveCheck: ocrFalsePositiveCheck,
            enableAnimations: false,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
    }

    /// 何も指定しなければプロファイルの値をそのまま写す(実効値 = プロファイル値)
    func testNoOverridesRecordsTheProfileValuesVerbatim() {
        let resolved = profile(fm: FMConfig(enabled: true, heal: true, falsePositiveCheck: true,
                                            screenLooksLike: true, triage: true))
        let (fm, record) = ProfileRunner.effectiveFMSettings(
            resolved: resolved, healOverride: nil, noFalsePositiveCheck: false)
        XCTAssertTrue(fm.heal)
        XCTAssertEqual(record, FMSettingsRecord(
            fm: true, heal: true, falsePositiveCheck: true, screenLooksLike: true, triage: true,
            ocr: true, ocrFalsePositiveCheck: true))
    }

    /// --no-false-positive-check はプロファイルが true でも実効値を false に落とす
    /// (これが記録される値 —— プロファイルの値ではなく実効値を run.json に残す契約)
    func testNoFalsePositiveCheckOverridesToFalseRegardlessOfProfile() {
        let resolved = profile(fm: FMConfig(enabled: true, heal: false, falsePositiveCheck: true,
                                            screenLooksLike: true, triage: true))
        let (fm, record) = ProfileRunner.effectiveFMSettings(
            resolved: resolved, healOverride: nil, noFalsePositiveCheck: true)
        XCTAssertFalse(fm.falsePositiveCheck)
        XCTAssertFalse(record.falsePositiveCheck)
    }

    /// --no-false-positive-check はプロファイルの既定(既に false)にも安全に効く(冪等)
    func testNoFalsePositiveCheckIsANoOpWhenAlreadyOff() {
        let resolved = profile(fm: FMConfig(enabled: true, heal: false, falsePositiveCheck: false,
                                            screenLooksLike: true, triage: true))
        let (_, record) = ProfileRunner.effectiveFMSettings(
            resolved: resolved, healOverride: nil, noFalsePositiveCheck: true)
        XCTAssertFalse(record.falsePositiveCheck)
    }

    /// --heal と --no-false-positive-check は独立に効く(片方が他方を巻き込まない)
    func testHealOverrideAndFalsePositiveCheckOverrideAreIndependent() {
        let resolved = profile(fm: FMConfig(enabled: true, heal: false, falsePositiveCheck: true,
                                            screenLooksLike: true, triage: true))
        let (fm, record) = ProfileRunner.effectiveFMSettings(
            resolved: resolved, healOverride: true, noFalsePositiveCheck: true)
        XCTAssertTrue(fm.heal, "--heal は独立に ON へ効く")
        XCTAssertTrue(record.heal)
        XCTAssertFalse(record.falsePositiveCheck, "--no-false-positive-check も同時に効く")
    }

    /// ocr/ocrFalsePositiveCheck は FMConfig の外(RunProfileDocument の兄弟キー)なので
    /// CLI 上書きの対象外 —— resolved の実効値をそのまま写す
    func testOcrFieldsPassThroughUnchanged() {
        let resolved = profile(fm: FMConfig(), ocr: false, ocrFalsePositiveCheck: false)
        let (_, record) = ProfileRunner.effectiveFMSettings(
            resolved: resolved, healOverride: nil, noFalsePositiveCheck: false)
        XCTAssertFalse(record.ocr)
        XCTAssertFalse(record.ocrFalsePositiveCheck)
    }
}
