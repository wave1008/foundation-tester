// DeviceFoldabilitySampler: 周期を止めないこと・確定した答えだけ控えること・unknown は間隔を空けて撃ち直すこと・
// 控えの識別子(iOS = udid / Android = id + serial)。ApiMonitorCommand.foldable は実機を測らず false にすること。

import FTCore
import XCTest

@testable import fleetest

final class DeviceFoldabilitySamplerTests: XCTestCase {

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    private let ios = DeviceFoldabilitySampler.Device(key: "ios:U1", probe: .iosSimulator(udid: "U1"))

    func testForegroundCallDoesNotWaitForTheProbe() {
        let sampler = DeviceFoldabilitySampler(probe: { _ in
            Thread.sleep(forTimeInterval: 1.0)
            return .state(.folded)
        })
        let started = Date()
        XCTAssertNil(sampler.foldable(for: ios), "最初の呼び出しは答えを待たず nil")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }

    func testStateAndNotFoldableAreCachedAsTrueAndFalse() {
        let observation = Box<FoldObservation>(.state(.unfolded))
        let calls = Box(0)
        let sampler = DeviceFoldabilitySampler(probe: { _ in calls.value += 1; return observation.value })
        _ = sampler.foldable(for: ios)
        waitUntil { sampler.foldable(for: self.ios) != nil }
        XCTAssertEqual(sampler.foldable(for: ios), true)

        let other = DeviceFoldabilitySampler.Device(key: "ios:U2", probe: .iosSimulator(udid: "U2"))
        observation.value = .notFoldable
        _ = sampler.foldable(for: other)
        waitUntil { sampler.foldable(for: other) != nil }
        XCTAssertEqual(sampler.foldable(for: other), false)

        let before = calls.value
        _ = sampler.foldable(for: ios)
        _ = sampler.foldable(for: other)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, before, "確定した答えは測り直さない")
    }

    func testUnknownIsNotCachedAndRetriesOnlyAfterTheInterval() {
        let calls = Box(0)
        let clock = Box(Date(timeIntervalSince1970: 1000))
        let observation = Box<FoldObservation>(.unknown("x"))
        let sampler = DeviceFoldabilitySampler(probe: { _ in calls.value += 1; return observation.value },
                                               now: { clock.value })
        XCTAssertNil(sampler.foldable(for: ios))
        waitUntil { calls.value == 1 }
        Thread.sleep(forTimeInterval: 0.1)

        clock.value = Date(timeIntervalSince1970: 1059)
        XCTAssertNil(sampler.foldable(for: ios))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 1, "59秒後はまだ撃ち直さない")

        clock.value = Date(timeIntervalSince1970: 1060)
        observation.value = .state(.folded)
        XCTAssertNil(sampler.foldable(for: ios))
        waitUntil { calls.value == 2 }
        waitUntil { sampler.foldable(for: self.ios) != nil }
        XCTAssertEqual(sampler.foldable(for: ios), true, "unknown は控えず、撃ち直しで確定する")
    }

    func testDoesNotEnqueueASecondProbeWhileOneIsInFlight() {
        let calls = Box(0)
        let release = DispatchSemaphore(value: 0)
        let clock = Box(Date(timeIntervalSince1970: 0))
        let sampler = DeviceFoldabilitySampler(probe: { _ in
            calls.value += 1
            release.wait()
            return .state(.folded)
        }, now: { clock.value })
        _ = sampler.foldable(for: ios)
        waitUntil { calls.value == 1 }
        clock.value = Date(timeIntervalSince1970: 10_000)
        _ = sampler.foldable(for: ios)
        _ = sampler.foldable(for: ios)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 1, "計測中は間隔が経っていても積まない")
        release.signal()
    }

    func testDeviceKeyIdentity() {
        let a = DeviceFoldabilitySampler.device(platform: "android", id: "android:Pixel Fold", udid: nil, serial: "emulator-5554")
        let b = DeviceFoldabilitySampler.device(platform: "android", id: "android:Pixel 9", udid: nil, serial: "emulator-5554")
        XCTAssertNotEqual(a?.key, b?.key, "同じ serial を別の AVD が再利用しても答えを引き継がない")
        XCTAssertEqual(a?.probe, .androidEmulator(serial: "emulator-5554"))
        let i = DeviceFoldabilitySampler.device(platform: "ios", id: "ios:iPhone", udid: "U1", serial: nil)
        XCTAssertEqual(i?.probe, .iosSimulator(udid: "U1"))
        XCTAssertNil(DeviceFoldabilitySampler.device(platform: "ios", id: "ios:x", udid: nil, serial: nil))
        XCTAssertNil(DeviceFoldabilitySampler.device(platform: "android", id: "android:x", udid: nil, serial: nil))
    }

    func testForgetDropsAnswersOfGoneDevices() {
        let calls = Box(0)
        let sampler = DeviceFoldabilitySampler(probe: { _ in calls.value += 1; return .state(.folded) })
        _ = sampler.foldable(for: ios)
        waitUntil { sampler.foldable(for: self.ios) != nil }
        sampler.forget(keysNotIn: [])
        let before = calls.value
        XCTAssertNil(sampler.foldable(for: ios))
        waitUntil { calls.value > before }
        XCTAssertGreaterThan(calls.value, before)
    }

    // MARK: - ApiMonitorCommand.foldable

    private func state(platform: String, kind: DeviceKind?, state: String, udid: String? = nil,
                       serial: String? = nil) -> DeviceRuntimeState {
        DeviceRuntimeState(target: MonitorTarget(platform: platform, spec: DeviceSpec(name: "d", kind: kind)),
                           state: state, detail: "", iosPort: nil, androidSerial: serial, iosUdid: udid)
    }

    func testPhysicalDevicesAreFalseWithoutProbing() {
        let calls = Box(0)
        let sampler = DeviceFoldabilitySampler(probe: { _ in calls.value += 1; return .state(.folded) })
        let physical = state(platform: "ios", kind: .physical, state: "connected", udid: "P1")
        XCTAssertEqual(ApiMonitorCommand.foldable(state: physical, sampler: sampler), false)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 0)
    }

    func testNotBootedVirtualDeviceIsNilAndNotProbed() {
        let calls = Box(0)
        let sampler = DeviceFoldabilitySampler(probe: { _ in calls.value += 1; return .state(.folded) })
        let off = state(platform: "ios", kind: .virtual, state: "shutdown", udid: "U1")
        XCTAssertNil(ApiMonitorCommand.foldable(state: off, sampler: sampler))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 0)
    }

    func testBootedVirtualDeviceIsProbedAndAnswered() {
        let sampler = DeviceFoldabilitySampler(probe: { _ in .state(.folded) })
        let booted = state(platform: "ios", kind: .virtual, state: "booted", udid: "U1")
        XCTAssertNil(ApiMonitorCommand.foldable(state: booted, sampler: sampler))
        waitUntil { ApiMonitorCommand.foldable(state: booted, sampler: sampler) != nil }
        XCTAssertEqual(ApiMonitorCommand.foldable(state: booted, sampler: sampler), true)
    }
}
