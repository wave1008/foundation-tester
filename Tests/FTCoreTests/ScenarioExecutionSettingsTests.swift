// `ScenarioExecutionSettings` は `DeviceIndependentRunSettings`/`ResolvedProfile` からの変換 init が
// 唯一の写像経路。欄を足して変換 init への写像を書き忘れると、その欄はコンパイルでは捕まらず
// 静かに ScenarioExecutionSettings() の既定へ落ちる。Mirror で全欄を機械的に確認する。

import XCTest
@testable import FTCore

final class ScenarioExecutionSettingsTests: XCTestCase {

    func testDefaultsArePinned() {
        let settings = ScenarioExecutionSettings()
        XCTAssertEqual(settings.occlusionOCR, true)
        XCTAssertEqual(settings.containerInference, true)
        XCTAssertNil(settings.defaultTimeout)
        XCTAssertNil(settings.scenarioTimeout)
        XCTAssertEqual(settings.fm, FMConfig())
    }

    /// 既定インスタンスと同名欄を `String(describing:)` で突き合わせ、1件でも既定のままなら
    /// 変換 init がその欄を運んでいない証拠として落とす
    private func assertNoFieldStaysDefault(_ value: ScenarioExecutionSettings,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let defaults = Mirror(reflecting: ScenarioExecutionSettings())
        let defaultsByLabel = Dictionary(uniqueKeysWithValues: defaults.children.compactMap {
            child -> (String, String)? in
            guard let label = child.label else { return nil }
            return (label, String(describing: child.value))
        })
        for child in Mirror(reflecting: value).children {
            guard let label = child.label else { continue }
            XCTAssertNotEqual(String(describing: child.value), defaultsByLabel[label],
                              "\(label) が既定値のまま(変換 init がこの欄を運んでいない)",
                              file: file, line: line)
        }
    }

    func testDeviceIndependentRunSettingsMappingCarriesEveryField() {
        let nonDefault = DeviceIndependentRunSettings(
            fm: FMConfig(enabled: false, heal: true, falsePositiveCheck: true,
                        screenLooksLike: false, triage: false),
            ocr: true,
            ocrFalsePositiveCheck: false,
            iosFastInput: true,
            iosPreActionWarmup: false,
            containerInference: false,
            enableAnimations: true,
            playProtectBypass: false,
            homeOnStart: false,
            record: true,
            recordFailuresOnly: true,
            recordFullResolution: true,
            reportDir: "/tmp/reports",
            defaultTimeout: 12.5,
            scenarioTimeout: 42,
            recordBitrateKbps: 2500)
        assertNoFieldStaysDefault(ScenarioExecutionSettings(nonDefault))
    }

    /// `ResolvedProfile` の memberwise init は internal なので `@testable import FTCore` で触る
    /// (ResolvedProfileDeviceScopeTests.swift と同じ手段)
    func testResolvedProfileMappingCarriesEveryField() {
        let profile = ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "run", machineName: "machine", appName: "app", apps: [:],
            devices: [],
            fm: FMConfig(enabled: false, heal: true, falsePositiveCheck: true,
                        screenLooksLike: false, triage: false),
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: 12.5, scenarioTimeout: 42, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosFastInput: false, iosPreActionWarmup: true, containerInference: false,
            ocr: true, ocrFalsePositiveCheck: false,
            enableAnimations: false,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
        assertNoFieldStaysDefault(ScenarioExecutionSettings(profile))
    }
}
