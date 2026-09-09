// run 開始前の「ブリッジが定着するまで待つ」段の並列性。
//
// **起こす側(AndroidLaneRecovery.bootMissingDevices)は1台ずつ**が正しい —— 複数台の同時ブート
// 描画が画面凍結の契機だから。**待つ側は違う**: `/status` を叩くだけで描画を伴わないのに直列で、
// 1台あたり最低 8 秒の dwell を台数ぶん積んでいた(実測 2026-09-09: 冷起動が ≈28 秒/台の
// 台数比例で、手元8台の run 開始まで 3分41秒。うち約半分がこの待ち)。
//
// ここが守るのは「台ごとの待ちが重なること」の1点。実デバイスは要らない(待ちを差し替える)。

import XCTest
@testable import FTAndroid
import FTCore
import FTTestSupport

final class DurableBridgeWaitConcurrencyTests: XCTestCase {

    private func device(_ name: String) -> ResolvedDevice {
        ResolvedDevice(platform: "android",
                       spec: DeviceSpec(name: name, kind: .virtual, avd: "avd-\(name)"))
    }

    /// **重なって走る**: 3台とも「開始したが終わっていない」瞬間があること。直列に戻すと
    /// 同時に走るのは常に1台なので、この検証は落ちる
    func testWaitsRunConcurrentlyAcrossDevices() async {
        actor Overlap {
            private var running = 0
            private(set) var peak = 0
            func enter() { running += 1; peak = max(peak, running) }
            func leave() { running -= 1 }
        }
        let overlap = Overlap()
        await ProfileWorkerFactory.awaitDurableAndroidBridges(
            devices: [device("a"), device("b"), device("c")], log: { _ in },
            wait: { _, _ in
                await overlap.enter()
                try? await Task.sleep(nanoseconds: 150_000_000)
                await overlap.leave()
            })
        let peak = await overlap.peak
        XCTAssertEqual(peak, 3, "台ごとの待ちは重ねる(直列なら peak は 1 になる)")
    }

    /// 実機は対象外(起動の概念が無く、ブリッジの定着待ちもしない)。**1台も居なければ何もしない**
    func testPhysicalDevicesAreNotWaitedFor() async {
        let physical = ResolvedDevice(
            platform: "android", spec: DeviceSpec(name: "p1", kind: .physical, serial: "SERIAL"))
        let called = LockedBox(0)
        await ProfileWorkerFactory.awaitDurableAndroidBridges(
            devices: [physical], log: { _ in },
            wait: { _, _ in called.mutate { $0 += 1 } })
        XCTAssertEqual(called.value, 0)
    }

    /// 全台の待ちが終わるまで戻らない(供給の次の段へ進んでよい合図)
    func testReturnsOnlyAfterEveryWaitFinished() async {
        let finished = LockedBox(0)
        await ProfileWorkerFactory.awaitDurableAndroidBridges(
            devices: [device("a"), device("b")], log: { _ in },
            wait: { _, _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                finished.mutate { $0 += 1 }
            })
        XCTAssertEqual(finished.value, 2)
    }
}
