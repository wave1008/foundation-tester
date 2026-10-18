// responseMeasurement の検査・強制値・モニター hold の判定・子プロセス境界の配線。

import XCTest
@testable import FTCore

final class ResponseMeasurementTests: XCTestCase {

    private func device(_ platform: String, physical: Bool, name: String = "d") -> ResolvedDevice {
        ResolvedDevice(platform: platform, spec: DeviceSpec(
            name: name, kind: physical ? .physical : .virtual,
            udid: platform == "ios" ? "U" : nil, serial: platform == "android" ? "S" : nil))
    }

    private func message(_ doc: RunProfileDocument, _ devices: [ResolvedDevice]) -> String? {
        do { try ResponseMeasurementPolicy.validate(doc, devices: devices, run: "r"); return nil }
        catch { return error.localizedDescription }
    }

    func testOnePhysicalAndroidPasses() {
        XCTAssertNil(message(RunProfileDocument(), [device("android", physical: true)]))
        XCTAssertNil(message(RunProfileDocument(enableAnimations: true), [device("android", physical: true)]))
    }

    func testDeviceCountMustBeOne() {
        XCTAssertTrue(message(RunProfileDocument(), [])?.contains("exactly one enabled device (found 0)") == true)
        let two = [device("android", physical: true, name: "a"), device("android", physical: true, name: "b")]
        XCTAssertTrue(message(RunProfileDocument(), two)?.contains("exactly one enabled device (found 2)") == true)
    }

    func testMustBePhysicalAndAndroid() {
        XCTAssertTrue(message(RunProfileDocument(), [device("android", physical: false)])?
            .contains("needs a physical device") == true)
        XCTAssertTrue(message(RunProfileDocument(), [device("ios", physical: true)])?
            .contains("supports only Android physical devices in this version") == true)
    }

    func testExplicitConflictsAreRejected() {
        let dev = [device("android", physical: true)]
        XCTAssertTrue(message(RunProfileDocument(enableAnimations: false), dev)?
            .contains("requires enableAnimations to be true") == true)
        XCTAssertTrue(message(RunProfileDocument(fmTextVisibilityCheck: true), dev)?
            .contains("requires fmTextVisibilityCheck to be false") == true)
        XCTAssertTrue(message(RunProfileDocument(ocrTextVisibilityCheck: true), dev)?
            .contains("requires ocrTextVisibilityCheck to be false") == true)
        XCTAssertTrue(message(RunProfileDocument(screenLooksLike: true), dev)?
            .contains("requires screenLooksLike to be false") == true)
        XCTAssertTrue(message(RunProfileDocument(record: true), dev)?
            .contains("requires record to be false") == true)
        // 明示の false は衝突しない
        XCTAssertNil(message(RunProfileDocument(fmTextVisibilityCheck: false, record: false), dev))
    }

    func testResolvedSettingsAreForcedWhenMeasuring() {
        let s = DeviceIndependentRunSettings.resolve(RunProfileDocument(responseMeasurement: true))
        XCTAssertTrue(s.responseMeasurement)
        XCTAssertTrue(s.enableAnimations)
        XCTAssertFalse(s.fm.enabled)
        XCTAssertFalse(s.fm.fmTextVisibilityCheck)
        XCTAssertFalse(s.fm.screenLooksLike)
        XCTAssertFalse(s.ocrTextVisibilityCheck)
        XCTAssertFalse(s.record)
        let off = DeviceIndependentRunSettings.resolve(RunProfileDocument())
        XCTAssertFalse(off.responseMeasurement)
        XCTAssertFalse(off.enableAnimations)
        XCTAssertTrue(off.ocrTextVisibilityCheck)
        XCTAssertTrue(off.record)
    }

    func testSetOverrideAndProfileOnlyKey() throws {
        let parsed = try RunProfileSetOverride.parse(["responseMeasurement=true"])
        XCTAssertTrue(ResponseMeasurementPolicy.isRequested(by: parsed))
        XCTAssertEqual(RunProfileDocument().applyingOverrides(parsed).responseMeasurement, true)
        XCTAssertTrue(RunProfileDocument.profileOnlyKeys.contains("responseMeasurement"))
    }

    func testCombinationRejectionNamesTheFlag() {
        XCTAssertTrue(ResponseMeasurementPolicy.combinationRejection(flag: "--broadcast").hasPrefix("--broadcast cannot be combined"))
    }

    // MARK: responseRepeat

    func testRepeatDefaultsToFiveAndAcceptsBounds() {
        XCTAssertEqual(DeviceIndependentRunSettings.resolve(RunProfileDocument(responseMeasurement: true)).responseRepeat, 5)
        XCTAssertEqual(DeviceIndependentRunSettings.resolve(
            RunProfileDocument(responseMeasurement: true, responseRepeat: 12)).responseRepeat, 12)
        let dev = [device("android", physical: true)]
        XCTAssertNil(message(RunProfileDocument(responseMeasurement: true, responseRepeat: 2), dev))
        XCTAssertNil(message(RunProfileDocument(responseMeasurement: true, responseRepeat: 50), dev))
    }

    func testRepeatOutOfRangeIsRejectedWithBothBounds() {
        let dev = [device("android", physical: true)]
        for value in [1, 0, -3] {
            XCTAssertTrue(message(RunProfileDocument(responseMeasurement: true, responseRepeat: value), dev)?
                .contains("responseRepeat in run profile r must be at least 2") == true, "value \(value)")
        }
        XCTAssertTrue(message(RunProfileDocument(responseMeasurement: true, responseRepeat: 51), dev)?
            .contains("must be at most 50") == true)
    }

    func testRepeatWithoutMeasurementIsRejected() {
        for measurement in [nil, false] as [Bool?] {
            do {
                try ResponseMeasurementPolicy.validateRepeatScope(
                    RunProfileDocument(responseMeasurement: measurement, responseRepeat: 3), run: "r")
                XCTFail("responseRepeat without responseMeasurement must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("responseRepeat in run profile r needs responseMeasurement"))
            }
        }
        XCTAssertNoThrow(try ResponseMeasurementPolicy.validateRepeatScope(RunProfileDocument(), run: "r"))
        XCTAssertNoThrow(try ResponseMeasurementPolicy.validateRepeatScope(
            RunProfileDocument(responseMeasurement: true, responseRepeat: 3), run: "r"))
    }

    func testRepeatSetOverrideParsesAsIntAndIsProfileOnly() throws {
        let parsed = try RunProfileSetOverride.parse(["responseMeasurement=true", "responseRepeat=7"])
        XCTAssertEqual(RunProfileDocument().applyingOverrides(parsed).responseRepeat, 7)
        XCTAssertTrue(RunProfileDocument.profileOnlyKeys.contains("responseRepeat"))
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["responseRepeat=x"]))
    }

    // MARK: 繰り返しの展開

    private func runItem(_ id: String) -> ScenarioRunItem { ScenarioRunItem(info: ScenarioInfo(id: id, title: id)) }

    func testExpandRepeatsEachItemBackToBackWithUniqueURLs() {
        let out = ResponseMeasurementRepeat.expand([runItem("A.S1"), runItem("日本語.S2")], count: 3)
        XCTAssertEqual(out.map(\.info.id), ["A.S1", "A.S1", "A.S1", "日本語.S2", "日本語.S2", "日本語.S2"])
        XCTAssertEqual(Set(out.map(\.url)).count, 6, "URL は一意キー: 重複すると Dictionary(uniqueKeysWithValues:) が落ちる")
        XCTAssertEqual(out.map(\.repeatIndex), [1, 2, 3, 1, 2, 3])
        for item in out { XCTAssertEqual(item.url.lastPathComponent, item.info.id) }
        XCTAssertTrue(out[1].url.absoluteString.hasSuffix("?repeat=2"))
    }

    func testExpandKeepsLaneAndCountOneIsIdentity() {
        let laned = ScenarioRunItem(info: ScenarioInfo(id: "A.S1", title: "t"), lane: "dev(1)")
        let out = ResponseMeasurementRepeat.expand([laned], count: 2)
        XCTAssertTrue(out[1].url.absoluteString.contains("lane=dev"))
        XCTAssertTrue(out[1].url.absoluteString.hasSuffix("&repeat=2"))
        XCTAssertEqual(ResponseMeasurementRepeat.expand([laned], count: 1).map(\.url), [laned.url])
    }

    // MARK: run.json の識別

    private func resolvedProfile(measuring: Bool, devices: [ResolvedDevice]) -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "r", appName: "app", apps: [:], devices: devices, fm: FMConfig(), heal: false,
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosPreActionPing: true, containerInference: true, ocrTextVisibilityCheck: true,
            preferCheckStateClassifier: true,
            enableAnimations: measuring, responseMeasurement: measuring, responseRepeat: 4,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
    }

    func testRunInfoCarriesDeviceIdentityOnlyWhenMeasuring() {
        let dev = ResolvedDevice(platform: "android", spec: DeviceSpec(
            name: "Pixel-4a", kind: .physical, osVersion: "13", serial: "SER1", model: "Pixel 4a"))
        XCTAssertEqual(ResponseMeasurementPolicy.runInfo(resolved: resolvedProfile(measuring: true, devices: [dev])),
                       ResponseMeasurementRunInfo(deviceName: "Pixel-4a", serial: "SER1", model: "Pixel 4a",
                                                  osVersion: "13", repeatCount: 4))
        XCTAssertNil(ResponseMeasurementPolicy.runInfo(resolved: resolvedProfile(measuring: false, devices: [dev])))
    }

    // MARK: モニター hold

    func testShouldAcquireOnlyWhenNoActiveHold() {
        let now = Date()
        XCTAssertTrue(ResponseMeasurementMonitorHold.shouldAcquire(existing: nil, now: now))
        XCTAssertFalse(ResponseMeasurementMonitorHold.shouldAcquire(
            existing: MonitorHold(until: nil, startedAt: 1), now: now))
        XCTAssertFalse(ResponseMeasurementMonitorHold.shouldAcquire(
            existing: MonitorHold(until: now.timeIntervalSince1970 + 60, startedAt: 1), now: now))
        XCTAssertTrue(ResponseMeasurementMonitorHold.shouldAcquire(
            existing: MonitorHold(until: now.timeIntervalSince1970 - 60, startedAt: 1), now: now))
    }

    func testShouldReleaseOnlyMyOwnHold() {
        let mine = MonitorHold(until: nil, startedAt: 100)
        XCTAssertTrue(ResponseMeasurementMonitorHold.shouldRelease(current: mine, mine: mine))
        XCTAssertFalse(ResponseMeasurementMonitorHold.shouldRelease(current: nil, mine: mine))
        XCTAssertFalse(ResponseMeasurementMonitorHold.shouldRelease(
            current: MonitorHold(until: nil, startedAt: 200), mine: mine))
    }

    func testAcquireAndReleaseRoundTripInTempDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rm-hold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = ResponseMeasurementMonitorHold.acquire(stateDir: dir) { _ in }
        XCTAssertNotNil(handle)
        XCTAssertNotNil(MonitorHold.load(stateDir: dir))
        // 既に有効な hold があれば触らない(取れない)
        XCTAssertNil(ResponseMeasurementMonitorHold.acquire(stateDir: dir) { _ in })
        ResponseMeasurementMonitorHold.release(handle) { _ in }
        XCTAssertNil(MonitorHold.load(stateDir: dir))
        // 利用者の hold を release が消さない
        let first = ResponseMeasurementMonitorHold.acquire(stateDir: dir) { _ in }
        try MonitorHold.save(MonitorHold(until: nil, startedAt: 1), stateDir: dir)
        ResponseMeasurementMonitorHold.release(first) { _ in }
        XCTAssertNotNil(MonitorHold.load(stateDir: dir))
    }

    // MARK: 子プロセス境界(型の効かない継ぎ目だけ)

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testScenarioHostForwardsTheFlagAndDropsPacing() throws {
        let host = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertTrue(host.contains("if responseMeasurement { args.append(\"--response-measurement\") }"),
                      "responseMeasurement が子ランナーへ伝わっていない")
        XCTAssertTrue(host.contains("if !dryRun && !responseMeasurement {"),
                      "計測中にホスト負荷の減速を子へ渡している(反応時間に待ちが混ざる)")
    }

    func testScenarioRunnerMainParsesAndForwardsTheFlag() throws {
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains("customLong(\"response-measurement\")"), "--response-measurement を受け取れない")
        XCTAssertTrue(runner.contains("responseMeasurement: responseMeasurement,"),
                      "--response-measurement を FTDriveCore へ渡していない")
    }
}
