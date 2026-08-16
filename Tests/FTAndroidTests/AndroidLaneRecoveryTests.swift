// AndroidLaneRecovery.plan/bootMissingDevices の規則(実機除外・avd未指定除外・起動中除外・
// 直列性・部分失敗の非致命性・再試行上限)を実デバイス無しで固定する。avd 名は極端に固有な
// 文字列にして、実行ホストの実際の AVD 名との偶然一致を避ける(canonicalAVDID は未一致なら
// 入力をそのまま返すため、一致しなければ決定的)。

import XCTest
@testable import FTAndroid
import FTCore

final class AndroidLaneRecoveryTests: XCTestCase {

    private func device(_ name: String, avd: String? = "auto",
                        physical: Bool = false) -> ResolvedDevice {
        let avdName = avd == "auto" ? "ftlanerecoverytest-\(name)" : avd
        return ResolvedDevice(
            platform: "android",
            spec: DeviceSpec(name: name, kind: physical ? .physical : .virtual, avd: avdName))
    }

    // MARK: - plan

    func testPlanExcludesPhysicalDevices() {
        let physical = device("p1", physical: true)
        XCTAssertTrue(AndroidLaneRecovery.plan(devices: [physical], runningAVDIDs: []).isEmpty)
    }

    func testPlanExcludesDevicesWithoutAvd() {
        let noAvd = device("d1", avd: nil)
        XCTAssertTrue(AndroidLaneRecovery.plan(devices: [noAvd], runningAVDIDs: []).isEmpty)
    }

    func testPlanExcludesRunningDevices() {
        let running = device("d1")
        let plan = AndroidLaneRecovery.plan(
            devices: [running], runningAVDIDs: ["ftlanerecoverytest-d1"])
        XCTAssertTrue(plan.isEmpty)
    }

    /// 起動していないものだけを返し、入力順を保つ
    func testPlanReturnsOnlyNotRunningDevicesPreservingOrder() {
        let d1 = device("d1")
        let d2 = device("d2")
        let d3 = device("d3")
        let plan = AndroidLaneRecovery.plan(
            devices: [d1, d2, d3], runningAVDIDs: ["ftlanerecoverytest-d2"])
        XCTAssertEqual(plan.map(\.device.name), ["d1", "d3"])
        XCTAssertEqual(plan.map(\.avdID), ["ftlanerecoverytest-d1", "ftlanerecoverytest-d3"])
    }

    // MARK: - bootMissingDevices

    /// **直列であることの検証**: d1 のブートだけ人為的に遅らせる。直列なら d1 が完全に終わって
    /// から d2 が始まるので記録順は必ず [d1, d2]。実装を並列(TaskGroup 等)へ変える変異が入ると、
    /// 遅延の無い d2 が先に記録され得るためこのテストは落ちる
    func testBootsSerialInInputOrder() async {
        actor Recorder {
            var order: [String] = []
            func record(_ name: String) { order.append(name) }
        }
        let recorder = Recorder()
        let d1 = device("d1")
        let d2 = device("d2")
        let result = await AndroidLaneRecovery.bootMissingDevices(
            devices: [d1, d2], locale: "ja_JP", log: { _ in },
            boot: { _, name in
                if name == "d1" {
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                await recorder.record(name)
            })
        let order = await recorder.order
        XCTAssertEqual(order, ["d1", "d2"], "d1 が終わってから d2 が始まっていない(直列でない)")
        XCTAssertEqual(Set(result.booted), Set(["d1", "d2"]))
        XCTAssertTrue(result.failed.isEmpty)
    }

    /// 1台の失敗が他を巻き込まない
    func testOneFailureDoesNotBlockOthers() async {
        struct BootError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let d1 = device("d1")
        let d2 = device("d2")
        let result = await AndroidLaneRecovery.bootMissingDevices(
            devices: [d1, d2], locale: "ja_JP", log: { _ in },
            boot: { _, name in
                if name == "d1" { throw BootError() }
            })
        XCTAssertEqual(result.booted, ["d2"])
        XCTAssertEqual(result.failed.map(\.name), ["d1"])
    }

    /// 失敗した台は3回まで試す。**期待値に production の定数を書かない** ——
    /// `count == AndroidLaneRecovery.maxBootAttempts` だと定数を変えたとき両辺が一緒に動き、
    /// 回数の変異を1つも殺せない(2026-08-16 の変異チェックで実際に生き残った)
    func testRetriesUpToMaxBootAttemptsForAFailingDevice() async {
        actor Counter {
            var count = 0
            func increment() { count += 1 }
        }
        struct BootError: Error {}
        let counter = Counter()
        let d1 = device("d1")
        let result = await AndroidLaneRecovery.bootMissingDevices(
            devices: [d1], locale: "ja_JP", log: { _ in },
            boot: { _, _ in
                await counter.increment()
                throw BootError()
            })
        let count = await counter.count
        XCTAssertEqual(count, 3, "失敗した台は3回まで試す")
        XCTAssertEqual(AndroidLaneRecovery.maxBootAttempts, 3,
                       "予算を動かすなら AndroidLaneRecovery.maxBootAttempts の doc の根拠も更新すること")
        XCTAssertTrue(result.booted.isEmpty)
        XCTAssertEqual(result.failed.map(\.name), ["d1"])
    }

    /// 空配列は何もしない(ログも起動もしない)
    func testEmptyDevicesDoesNothing() async {
        var logged = false
        let result = await AndroidLaneRecovery.bootMissingDevices(
            devices: [], locale: "ja_JP", log: { _ in logged = true },
            boot: { _, _ in XCTFail("boot should not be called") })
        XCTAssertTrue(result.booted.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(logged)
    }
}
