// api monitor のストレージ計測が配信周期を止めないこと・run 中は Simulator の du を撃たないこと。
// 計測関数は差し替え口から遅い偽物を渡し、schedule() の所要を直接測る(戻り値でなく時間で守る)。

import FTAndroid
import FTCore
import XCTest

@testable import fleetest

final class DeviceStorageSamplerTests: XCTestCase {

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    func testScheduleDoesNotWaitForTheProbe() {
        let sampler = DeviceStorageSampler(
            probeIOS: { _ in Thread.sleep(forTimeInterval: 1.0); return DeviceStorageInfo(
                usedBytes: 1, freeBytes: nil, freeScope: .hostVolume, measuredAt: "t") },
            probeAndroid: { _ in nil }, isRunActive: { false })
        let started = Date()
        sampler.schedule(candidates: [("A", "ios"), ("B", "ios")], now: Date())
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "周期の中で計測を待ってはいけない")
        XCTAssertTrue(sampler.snapshot().isEmpty)
        waitUntil { sampler.snapshot().count == 2 }
        XCTAssertEqual(Set(sampler.snapshot().keys), ["A", "B"])
    }

    func testIOSDuIsNotScheduledWhileARunIsActiveButAndroidIs() {
        let iosCalls = LockedCounter()
        let sampler = DeviceStorageSampler(
            probeIOS: { _ in iosCalls.increment(); return nil },
            probeAndroid: { _ in DeviceStorageInfo(usedBytes: 2, freeBytes: 3, freeScope: .device, measuredAt: "t") },
            isRunActive: { true })
        sampler.schedule(candidates: [("sim", "ios"), ("emu", "android")], now: Date())
        waitUntil { sampler.snapshot()["emu"] != nil }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(iosCalls.value, 0)
        XCTAssertNotNil(sampler.snapshot()["emu"])
    }

    func testFailedProbeKeepsThePreviousValueAndIsNotRetriedBeforeTheInterval() {
        let calls = LockedCounter()
        let sampler = DeviceStorageSampler(
            probeIOS: { _ in nil },
            probeAndroid: { _ in calls.increment()
                return calls.value == 1
                    ? DeviceStorageInfo(usedBytes: 5, freeBytes: 6, freeScope: .device, measuredAt: "t") : nil },
            isRunActive: { false })
        let t0 = Date()
        sampler.schedule(candidates: [("emu", "android")], now: t0)
        waitUntil { sampler.snapshot()["emu"] != nil }
        sampler.schedule(candidates: [("emu", "android")], now: t0.addingTimeInterval(1))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 1, "間隔の内側では撃ち直さない")
        sampler.schedule(candidates: [("emu", "android")],
                         now: Date().addingTimeInterval(AndroidStorageProbe.probeIntervalSeconds + 1))
        waitUntil { calls.value == 2 }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(sampler.snapshot()["emu"]?.usedBytes, 5, "測れなかった回は前回値を残す")
    }

    func testForgetDropsDevicesThatLeft() {
        let sampler = DeviceStorageSampler(
            probeIOS: { _ in nil },
            probeAndroid: { _ in DeviceStorageInfo(usedBytes: 1, freeBytes: 1, freeScope: .device, measuredAt: "t") },
            isRunActive: { false })
        sampler.schedule(candidates: [("a", "android"), ("b", "android")], now: Date())
        waitUntil { sampler.snapshot().count == 2 }
        sampler.forget(keysNotIn: ["a"])
        XCTAssertEqual(Set(sampler.snapshot().keys), ["a"])
    }

    private func countingAndroidSampler(_ calls: LockedCounter, delay: TimeInterval = 0) -> DeviceStorageSampler {
        DeviceStorageSampler(
            probeIOS: { _ in nil },
            probeAndroid: { _ in
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                calls.increment()
                return DeviceStorageInfo(usedBytes: calls.value, freeBytes: 1, freeScope: .device, measuredAt: "t")
            },
            isRunActive: { false })
    }

    func testRebootedDeviceIsRemeasuredBeforeTheInterval() {
        let calls = LockedCounter()
        let sampler = countingAndroidSampler(calls)
        sampler.noteConnected(keys: ["emu"])
        sampler.schedule(candidates: [("emu", "android")], now: Date())
        waitUntil { calls.value == 1 }
        Thread.sleep(forTimeInterval: 0.05)

        // つながったままなら間隔の内側では測らない
        sampler.noteConnected(keys: ["emu"])
        sampler.schedule(candidates: [("emu", "android")], now: Date())
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 1)

        // 再起動(connected 以外を挟んで connected へ戻る)したら測り直す
        sampler.noteConnected(keys: [])
        sampler.noteConnected(keys: ["emu"])
        sampler.schedule(candidates: [("emu", "android")], now: Date())
        waitUntil { calls.value == 2 }
        XCTAssertEqual(calls.value, 2)
    }

    func testRebootDuringAMeasurementIsRemeasuredAfterItFinishes() {
        let calls = LockedCounter()
        let sampler = countingAndroidSampler(calls, delay: 0.3)
        sampler.noteConnected(keys: ["emu"])
        sampler.schedule(candidates: [("emu", "android")], now: Date())
        // 計測中に再起動が観測された
        sampler.noteConnected(keys: [])
        sampler.noteConnected(keys: ["emu"])
        waitUntil { calls.value == 1 }
        Thread.sleep(forTimeInterval: 0.05)
        sampler.schedule(candidates: [("emu", "android")], now: Date())
        waitUntil { calls.value == 2 }
        XCTAssertEqual(calls.value, 2, "起動前の中身かもしれない計測で期限を進めない")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
