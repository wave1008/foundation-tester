// BridgeLogRotationSampler: 周期を止めないこと(scheduleIfDue は即返る)・測る契機は間隔が
// 経ったときだけであること・測れた値は次の間隔まで控えに残ること。
// BridgeLogRotationCandidateMapping: ポート→デバイスの対応(純粋関数)。

import FTCore
import XCTest

@testable import fleetest

final class BridgeLogRotationSamplerTests: XCTestCase {

    private func rawCandidate(port: UInt16 = 8123) -> BridgeLogRotationSampler.RawCandidate {
        BridgeLogRotationSampler.RawCandidate(
            port: port, bundleBytes: 10, usageBytes: 20, limitBytes: 100,
            bundlePath: URL(fileURLWithPath: "/tmp/bridge-\(port)-1.xcresult"))
    }

    func testScheduleIfDueDoesNotWaitForTheMeasurement() {
        let calls = LockedCounter()
        let sampler = BridgeLogRotationSampler(measure: {
            Thread.sleep(forTimeInterval: 1.0)
            calls.increment()
            return nil
        })
        let started = Date()
        sampler.scheduleIfDue()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "周期の中で計測を待ってはいけない")
    }

    /// 起動直後(まだ一度も測っていない)は間隔を待たず即座に測る
    func testFirstCallMeasuresImmediately() {
        let calls = LockedCounter()
        let sampler = BridgeLogRotationSampler(measure: { calls.increment(); return nil })
        sampler.scheduleIfDue()
        waitUntil { calls.value == 1 }
    }

    /// 間隔が経つまで撃ち直さない
    func testDoesNotMeasureAgainBeforeTheInterval() {
        let calls = LockedCounter()
        let clock = LockedClock(Date(timeIntervalSince1970: 0))
        let sampler = BridgeLogRotationSampler(measure: { calls.increment(); return nil },
                                               now: { clock.value })
        sampler.scheduleIfDue()
        waitUntil { calls.value == 1 }
        clock.value = Date(timeIntervalSince1970: 1)  // 1 秒後(間隔 600 秒未満)
        sampler.scheduleIfDue()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 1)
    }

    /// 間隔(600秒)を過ぎたら次のサイクルで測り直す
    func testMeasuresAgainAfterTheInterval() {
        let calls = LockedCounter()
        let clock = LockedClock(Date(timeIntervalSince1970: 0))
        let sampler = BridgeLogRotationSampler(measure: { calls.increment(); return nil },
                                               now: { clock.value })
        sampler.scheduleIfDue()
        waitUntil { calls.value == 1 }
        clock.value = Date(timeIntervalSince1970: 601)
        sampler.scheduleIfDue()
        waitUntil { calls.value == 2 }
    }

    /// 測れた値は次に測り直すまで控えに残る(周期は控えを読むだけ)
    func testSnapshotHoldsTheLastMeasuredValue() {
        let sampler = BridgeLogRotationSampler(measure: { self.rawCandidate() }, bundleExists: { _ in true })
        XCTAssertNil(sampler.snapshot())
        sampler.scheduleIfDue()
        waitUntil { sampler.snapshot() != nil }
        XCTAssertEqual(sampler.snapshot(), rawCandidate())
    }

    /// 建て直しで束が消えたら、次に測り直す前でも控えを捨てる(古いポートを別のデバイスの
    /// ブリッジが使い始めても、そのデバイスを指さない)
    func testSnapshotDropsTheCandidateOnceItsBundleIsGone() {
        let exists = LockedFlag(true)
        let sampler = BridgeLogRotationSampler(measure: { self.rawCandidate() },
                                               bundleExists: { _ in exists.value })
        sampler.scheduleIfDue()
        waitUntil { sampler.snapshot() != nil }
        exists.value = false
        XCTAssertNil(sampler.snapshot())
        exists.value = true
        XCTAssertNil(sampler.snapshot(), "一度捨てた控えは次の計測まで戻らない")
    }

    // MARK: - BridgeLogRotationCandidateMapping

    private func iosTarget(name: String) -> MonitorTarget {
        MonitorTarget(platform: "ios", spec: DeviceSpec(name: name))
    }

    private func connectedIOSState(name: String, port: UInt16) -> DeviceRuntimeState {
        DeviceRuntimeState(target: iosTarget(name: name), state: "connected", detail: "",
                           iosPort: port, androidSerial: nil)
    }

    func testMappingReturnsNilWhenThereIsNoRawCandidate() {
        XCTAssertNil(BridgeLogRotationCandidateMapping.candidate(raw: nil, states: []))
    }

    /// 対応が引けない候補(このマシンが観測していないポート)は nil
    func testMappingReturnsNilWhenThePortMatchesNoObservedDevice() {
        let states = [connectedIOSState(name: "iPhone 17", port: 8124)]
        XCTAssertNil(BridgeLogRotationCandidateMapping.candidate(raw: rawCandidate(port: 8123), states: states))
    }

    func testMappingResolvesTheDeviceByPort() {
        let states = [connectedIOSState(name: "iPhone 17", port: 8123)]
        let candidate = BridgeLogRotationCandidateMapping.candidate(raw: rawCandidate(port: 8123), states: states)
        XCTAssertEqual(candidate?.name, "iPhone 17")
        XCTAssertEqual(candidate?.port, 8123)
        XCTAssertEqual(candidate?.bundleBytes, 10)
        XCTAssertEqual(candidate?.usageBytes, 20)
        XCTAssertEqual(candidate?.limitBytes, 100)
        XCTAssertEqual(candidate?.deviceId, iosTarget(name: "iPhone 17").id)
    }

    /// Android の同じポート番号(iosPort は nil)には当たらない
    func testMappingIgnoresAndroidStatesEvenWithMatchingPortNumber() {
        let android = DeviceRuntimeState(
            target: MonitorTarget(platform: "android", spec: DeviceSpec(name: "Pixel")),
            state: "connected", detail: "", iosPort: nil, androidSerial: "emulator-5554")
        XCTAssertNil(BridgeLogRotationCandidateMapping.candidate(raw: rawCandidate(port: 8123), states: [android]))
    }

    // MARK: - NDJSON の形(vscode-fleetest/src/monitorBridgeLogRotation.ts と同期)

    func testEncodedLineWithNoCandidate() throws {
        let line = try encodedLine(ApiMonitorBridgeLogRotationEvent(candidate: nil))
        XCTAssertEqual(line, #"{"candidate":null,"kind":"monitorBridgeLogRotation"}"#)
    }

    func testEncodedLineWithACandidate() throws {
        let candidate = ApiMonitorBridgeLogRotationEvent.Candidate(
            deviceId: "ios:iPhone 17", name: "iPhone 17", port: 8123,
            bundleBytes: 10, usageBytes: 20, limitBytes: 100)
        let line = try encodedLine(ApiMonitorBridgeLogRotationEvent(candidate: candidate))
        XCTAssertEqual(line, #"{"candidate":{"bundleBytes":10,"deviceId":"ios:iPhone 17","limitBytes":100,"name":"iPhone 17","port":8123,"usageBytes":20},"kind":"monitorBridgeLogRotation"}"#)
    }

    private func encodedLine<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return date }
        set { lock.lock(); date = newValue; lock.unlock() }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ flag: Bool) { self.flag = flag }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}
