// api monitor のストレージ計測が配信周期を止めないこと・run 中は Simulator を測らないこと・前回値を残すこと。
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
            probeAndroid: { _ in nil }, isRunActive: { false }, storeURL: nil)
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
            isRunActive: { true }, storeURL: nil)
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
            isRunActive: { false }, storeURL: nil)
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
            isRunActive: { false }, storeURL: nil)
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
            isRunActive: { false }, storeURL: nil)
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

    private func temporaryStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceStorageSamplerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // 途中のディレクトリが無くても書けること(~/.fleetest が無い機械)
        return dir.appendingPathComponent("nested/device-storage.json")
    }

    /// モニターが起動し直しても、run 中で測れない iOS の台に前回値が出ること
    func testMeasuredValuesSurviveARestartOfTheMonitor() throws {
        let store = try temporaryStoreURL()
        let first = DeviceStorageSampler(
            probeIOS: { _ in DeviceStorageInfo(usedBytes: 7, freeBytes: 8, freeScope: .hostVolume, measuredAt: "t1") },
            probeAndroid: { _ in nil }, isRunActive: { false }, storeURL: store)
        first.schedule(candidates: [("sim", "ios")], now: Date())
        waitUntil { FileManager.default.fileExists(atPath: store.path) }

        let iosCalls = LockedCounter()
        let restarted = DeviceStorageSampler(
            probeIOS: { _ in iosCalls.increment(); return nil },
            probeAndroid: { _ in nil }, isRunActive: { true }, storeURL: store)
        XCTAssertEqual(restarted.snapshot()["sim"],
                       DeviceStorageInfo(usedBytes: 7, freeBytes: 8, freeScope: .hostVolume, measuredAt: "t1"))
        restarted.schedule(candidates: [("sim", "ios")], now: Date())
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(iosCalls.value, 0, "run 中は測らない方針は保存があっても同じ")
    }

    func testUnreadableStoreStartsEmpty() throws {
        let store = try temporaryStoreURL()
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store)
        let sampler = DeviceStorageSampler(probeIOS: { _ in nil }, probeAndroid: { _ in nil },
                                           isRunActive: { false }, storeURL: store)
        XCTAssertTrue(sampler.snapshot().isEmpty)
    }

    func testFailedProbeDoesNotOverwriteTheStore() throws {
        let store = try temporaryStoreURL()
        let first = DeviceStorageSampler(
            probeIOS: { _ in nil },
            probeAndroid: { _ in DeviceStorageInfo(usedBytes: 3, freeBytes: 4, freeScope: .device, measuredAt: "t") },
            isRunActive: { false }, storeURL: store)
        first.schedule(candidates: [("emu", "android")], now: Date())
        waitUntil { FileManager.default.fileExists(atPath: store.path) }
        let failing = DeviceStorageSampler(probeIOS: { _ in nil }, probeAndroid: { _ in nil },
                                           isRunActive: { false }, storeURL: store)
        failing.schedule(candidates: [("emu", "android")], now: Date())
        Thread.sleep(forTimeInterval: 0.1)
        let reloaded = DeviceStorageSampler(probeIOS: { _ in nil }, probeAndroid: { _ in nil },
                                            isRunActive: { false }, storeURL: store)
        XCTAssertEqual(reloaded.snapshot()["emu"]?.usedBytes, 3)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
