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
