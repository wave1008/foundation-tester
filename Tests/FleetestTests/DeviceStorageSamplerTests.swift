// api monitor のストレージ計測: 周期を止めないこと・測る契機は更新ボタン(requestRefresh)だけであること・
// 計測中の台を二重に積まないこと・前回値を残すこと。計測関数は差し替え口から偽物を渡す。

import FTCore
import XCTest

@testable import fleetest

final class DeviceStorageSamplerTests: XCTestCase {

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    private func countingSampler(_ calls: LockedCounter, delay: TimeInterval = 0,
                                 storeURL: URL? = nil) -> DeviceStorageSampler {
        let probe: DeviceStorageSampler.Probe = { _ in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            calls.increment()
            return storageInfo(calls.value)
        }
        return DeviceStorageSampler(probeIOS: probe, probeAndroid: probe, storeURL: storeURL, onMeasured: { _ in })
    }

    func testScheduleDoesNotWaitForTheProbe() {
        let calls = LockedCounter()
        let sampler = countingSampler(calls, delay: 1.0)
        sampler.requestRefresh()
        let started = Date()
        sampler.schedule(candidates: [("A", "ios"), ("B", "ios")])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "周期の中で計測を待ってはいけない")
        XCTAssertTrue(sampler.snapshot().isEmpty)
        waitUntil { sampler.snapshot().count == 2 }
        XCTAssertEqual(Set(sampler.snapshot().keys), ["A", "B"])
    }

    /// 更新ボタンが押されるまで1台も測らない(モニターの起動直後・周期を重ねても)
    func testNothingIsMeasuredWithoutARefresh() {
        let calls = LockedCounter()
        let sampler = countingSampler(calls)
        for _ in 0..<3 { sampler.schedule(candidates: [("sim", "ios"), ("emu", "android")]) }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 0)
    }

    /// 更新は1回きり: 押した周期に全台を積み、その後の周期では撃ち直さない
    func testRefreshMeasuresEveryCandidateOnce() {
        let calls = LockedCounter()
        let sampler = countingSampler(calls)
        sampler.requestRefresh()
        sampler.schedule(candidates: [("sim", "ios"), ("emu", "android")])
        waitUntil { calls.value == 2 }
        sampler.schedule(candidates: [("sim", "ios"), ("emu", "android")])
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 2)
        sampler.requestRefresh()
        sampler.schedule(candidates: [("sim", "ios"), ("emu", "android")])
        waitUntil { calls.value == 4 }
        XCTAssertEqual(calls.value, 4, "押すたびに全台を測る")
    }

    /// 計測中の台は積まない(同じ台を二重に歩かない)。計測中でない台は積む
    func testInFlightDeviceIsNotScheduledAgain() {
        let calls = LockedCounter()
        let sampler = countingSampler(calls, delay: 0.3)
        sampler.requestRefresh()
        sampler.schedule(candidates: [("emu", "android")])
        sampler.requestRefresh()
        sampler.schedule(candidates: [("emu", "android"), ("emu2", "android")])
        waitUntil { calls.value == 2 }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(calls.value, 2, "emu は計測中なので2本目を積まない・emu2 だけ積む")
        XCTAssertEqual(Set(sampler.snapshot().keys), ["emu", "emu2"])
    }

    /// 進捗: 積んだ台は終わるまで measuring に入り、終わったら値と同時に外れる(拡張の「測定中 n / m 台」)
    func testProgressSnapshotReportsMeasuringUntilTheProbeFinishes() {
        let calls = LockedCounter()
        let sampler = countingSampler(calls, delay: 0.3)
        XCTAssertEqual(sampler.progressSnapshot().measuring, [])
        sampler.requestRefresh()
        sampler.schedule(candidates: [("emu", "android")])
        XCTAssertEqual(sampler.progressSnapshot().measuring, ["emu"])
        waitUntil { sampler.progressSnapshot().measuring.isEmpty }
        let progress = sampler.progressSnapshot()
        XCTAssertEqual(progress.measuring, [])
        XCTAssertEqual(progress.values["emu"]?.usedBytes, 1, "測定中が外れた時点で値は入っている")
    }

    /// 1台終わるたびに onMeasured を呼ぶ(測れなかった回も)。呼ぶ時点で測定中から外れ、値は入っている
    /// = モニターはこの瞬間の progressSnapshot でその台の monitorStorage を出せる
    func testOnMeasuredFiresPerDeviceAfterItLeavesMeasuring() {
        let seen = LockedStrings()
        let box = SamplerBox()
        let sampler = DeviceStorageSampler(
            probeIOS: { key in key == "slow" ? { Thread.sleep(forTimeInterval: 0.4); return storageInfo(2) }() : nil },
            probeAndroid: { _ in storageInfo(1) },
            storeURL: nil,
            onMeasured: { key in
                guard let progress = box.sampler?.progressSnapshot() else { return }
                seen.append("\(key):\(progress.measuring.contains(key)):\(progress.values[key]?.usedBytes ?? -1)")
            })
        box.sampler = sampler
        sampler.requestRefresh()
        sampler.schedule(candidates: [("emu", "android"), ("slow", "ios"), ("failing", "ios")])
        waitUntil { seen.values.count == 3 }
        XCTAssertEqual(Set(seen.values), ["emu:false:1", "slow:false:2", "failing:false:-1"])
        XCTAssertEqual(seen.values.first, "emu:false:1", "速く終わった台は遅い台を待たずに知らせる")
    }

    func testFailedProbeKeepsThePreviousValue() {
        let calls = LockedCounter()
        let sampler = DeviceStorageSampler(
            probeIOS: { _ in nil },
            probeAndroid: { _ in calls.increment(); return calls.value == 1 ? storageInfo(5) : nil },
            storeURL: nil, onMeasured: { _ in })
        sampler.requestRefresh()
        sampler.schedule(candidates: [("emu", "android")])
        waitUntil { sampler.snapshot()["emu"] != nil }
        sampler.requestRefresh()
        sampler.schedule(candidates: [("emu", "android")])
        waitUntil { calls.value == 2 }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(sampler.snapshot()["emu"]?.usedBytes, 5, "測れなかった回は前回値を残す(0 で埋めない)")
    }

    func testForgetDropsDevicesThatLeft() {
        let calls = LockedCounter()
        let sampler = countingSampler(calls)
        sampler.requestRefresh()
        sampler.schedule(candidates: [("a", "android"), ("b", "android")])
        waitUntil { sampler.snapshot().count == 2 }
        sampler.forget(keysNotIn: ["a"])
        XCTAssertEqual(Set(sampler.snapshot().keys), ["a"])
    }

    // MARK: - 前回値の保存

    private func temporaryStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceStorageSamplerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // 途中のディレクトリが無くても書けること(~/.fleetest が無い機械)
        return dir.appendingPathComponent("nested/device-storage.json")
    }

    /// モニターが起動し直しても前回値が出る(測り直すまで carriedOver = 拡張は灰色)。起動しただけでは測らない
    func testMeasuredValuesSurviveARestartOfTheMonitorAsCarriedOver() throws {
        let store = try temporaryStoreURL()
        let first = DeviceStorageSampler(probeIOS: { _ in storageInfo(7, .hostVolume, at: "t1") },
                                         probeAndroid: { _ in nil }, storeURL: store, onMeasured: { _ in })
        first.requestRefresh()
        first.schedule(candidates: [("sim", "ios")])
        waitUntil { FileManager.default.fileExists(atPath: store.path) }
        XCTAssertEqual(first.snapshot()["sim"]?.carriedOver, false, "測った値は前回値ではない")

        let calls = LockedCounter()
        let restarted = countingSampler(calls, storeURL: store)
        XCTAssertEqual(restarted.snapshot()["sim"],
                       DeviceStorageInfo(usedBytes: 7, freeBytes: 1, freeScope: .hostVolume, measuredAt: "t1",
                                         carriedOver: true))
        restarted.schedule(candidates: [("sim", "ios")])
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 0, "起動しただけでは測らない")

        restarted.requestRefresh()
        restarted.schedule(candidates: [("sim", "ios")])
        waitUntil { calls.value == 1 }
        waitUntil { restarted.snapshot()["sim"]?.carriedOver == false }
        XCTAssertEqual(restarted.snapshot()["sim"]?.carriedOver, false, "測り直したら印が外れる")
    }

    func testUnreadableStoreStartsEmpty() throws {
        let store = try temporaryStoreURL()
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store)
        let sampler = DeviceStorageSampler(probeIOS: { _ in nil }, probeAndroid: { _ in nil }, storeURL: store, onMeasured: { _ in })
        XCTAssertTrue(sampler.snapshot().isEmpty)
    }

    func testFailedProbeDoesNotOverwriteTheStore() throws {
        let store = try temporaryStoreURL()
        let first = DeviceStorageSampler(probeIOS: { _ in nil }, probeAndroid: { _ in storageInfo(3) }, storeURL: store, onMeasured: { _ in })
        first.requestRefresh()
        first.schedule(candidates: [("emu", "android")])
        waitUntil { FileManager.default.fileExists(atPath: store.path) }
        let failing = DeviceStorageSampler(probeIOS: { _ in nil }, probeAndroid: { _ in nil }, storeURL: store, onMeasured: { _ in })
        failing.requestRefresh()
        failing.schedule(candidates: [("emu", "android")])
        Thread.sleep(forTimeInterval: 0.1)
        let reloaded = DeviceStorageSampler(probeIOS: { _ in nil }, probeAndroid: { _ in nil }, storeURL: store, onMeasured: { _ in })
        XCTAssertEqual(reloaded.snapshot()["emu"]?.usedBytes, 3)
    }
}

private func storageInfo(_ used: Int, _ scope: DeviceStorageFreeScope = .device, at: String = "t") -> DeviceStorageInfo {
    DeviceStorageInfo(usedBytes: used, freeBytes: 1, freeScope: scope, measuredAt: at)
}

private final class SamplerBox: @unchecked Sendable {
    var sampler: DeviceStorageSampler?
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
