// AndroidLaneRecovery.plan/bootMissingDevices の規則(実機除外・avd未指定除外・起動中除外・
// 直列性・部分失敗の非致命性・再試行上限)を実デバイス無しで固定する。avd 名は極端に固有な
// 文字列にして、実行ホストの実際の AVD 名との偶然一致を避ける(canonicalAVDID は未一致なら
// 入力をそのまま返すため、一致しなければ決定的)。

import XCTest
@testable import FTAndroid
import FTCore
import FTTestSupport

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

    /// 進行は**台ごとに開始と結果の2行**を (i/N) 付きで出す。直列で1台に1分近くかかるため、
    /// 完了行だけだと待っている間ずっと無音になる(読み手は拡張の「テスト実行」タブ)。
    func testLogsPerDeviceProgressBeforeAndAfterEachBoot() async {
        let lines = LockedBox([String]())
        let devices = [device("d1"), device("d2"), device("d3")]
        _ = await AndroidLaneRecovery.bootMissingDevices(
            devices: devices, locale: "ja_JP",
            log: { line in lines.mutate { $0.append(line) } },
            boot: { _, _ in })
        // 冒頭の "Reviving N dead lane(s)" も starting を含むので、台ごとの2行だけを取る
        let progress = lines.value.filter { $0.hasPrefix("▶️") || $0.hasPrefix("✅") }
        XCTAssertEqual(progress.count, 6, "3台なら開始3行 + 結果3行")
        for (index, name) in ["d1", "d2", "d3"].enumerated() {
            let counter = "(\(index + 1)/3)"
            XCTAssertTrue(progress.contains { $0.contains(counter) && $0.contains(name)
                && $0.contains("starting") },
                          "\(name) の開始行に \(counter) が無い: \(progress)")
            XCTAssertTrue(progress.contains { $0.contains(counter) && $0.contains(name)
                && $0.contains("revived") },
                          "\(name) の結果行に \(counter) が無い: \(progress)")
        }
        // 開始行は必ずその台の結果行より前(待っている間に出るための順序)
        XCTAssertLessThan(progress.firstIndex { $0.contains("starting") && $0.contains("d2") } ?? -1,
                          progress.firstIndex { $0.contains("revived") && $0.contains("d2") } ?? -1)
    }

    /// 空配列は何もしない(ログも起動もしない)
    func testEmptyDevicesDoesNothing() async {
        let logged = LockedBox(false)
        let result = await AndroidLaneRecovery.bootMissingDevices(
            devices: [], locale: "ja_JP", log: { _ in logged.mutate { $0 = true } },
            boot: { _, _ in XCTFail("boot should not be called") })
        XCTAssertTrue(result.booted.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(logged.value)
    }

    // MARK: - decisive FATAL は再試行しない

    private struct MessageError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func testIsDecisiveFailureMatchesTheObservedMarker() {
        XCTAssertTrue(AndroidLaneRecovery.isDecisiveFailure(
            MessageError(message: "… its own log says: FATAL | Broken AVD system path")))
        XCTAssertFalse(AndroidLaneRecovery.isDecisiveFailure(MessageError(message: "boom")))
    }

    /// 決定的な FATAL(システムイメージが無い等)は1回で諦め、3回×N台の無駄な再試行をしない
    /// (M1Ultra の4台がこれで数分無駄にした)
    func testDoesNotRetryADecisiveFatalFailure() async {
        actor Counter {
            var count = 0
            func increment() { count += 1 }
        }
        let counter = Counter()
        let d1 = device("decisive-d1")
        let result = await AndroidLaneRecovery.bootMissingDevices(
            devices: [d1], locale: "ja_JP", log: { _ in },
            boot: { _, _ in
                await counter.increment()
                throw MessageError(message: "FATAL | Broken AVD system path")
            })
        let count = await counter.count
        XCTAssertEqual(count, 1, "決定的な FATAL は撃ち直しても同じ結果になるので1回で諦める")
        XCTAssertEqual(result.failed.map(\.name), ["decisive-d1"])
    }

    /// 決定的でない失敗は引き続き3回まで試す(退行させない対照)
    func testStillRetriesANonDecisiveFailure() async {
        actor Counter {
            var count = 0
            func increment() { count += 1 }
        }
        let counter = Counter()
        let d1 = device("nondecisive-d1")
        _ = await AndroidLaneRecovery.bootMissingDevices(
            devices: [d1], locale: "ja_JP", log: { _ in },
            boot: { _, _ in
                await counter.increment()
                throw MessageError(message: "transient adb hiccup")
            })
        let count = await counter.count
        XCTAssertEqual(count, AndroidLaneRecovery.maxBootAttempts)
    }

    // MARK: - 復活の失敗理由を RevivalOutcomeLedger へ残す

    /// 復活に失敗した AVD の理由は、後続の avdNotRunning がそのまま引用できるよう記録される
    /// (呼び出し側 ProfileRunner/ApiRunCommand を経由させず FTAndroid 内で完結させる受け渡し)
    func testRecordsRevivalFailureReasonForLaterLookup() async {
        let avdID = "ftlanerecoverytest-ledger-fail"
        let d1 = device("ledger-fail", avd: avdID)
        _ = await AndroidLaneRecovery.bootMissingDevices(
            devices: [d1], locale: "ja_JP", log: { _ in },
            boot: { _, _ in throw MessageError(message: "boom: Broken AVD system path") })
        XCTAssertEqual(RevivalOutcomeLedger.shared.failureReason(avdID: avdID),
                       "boom: Broken AVD system path")
    }

    /// 復活が成功したら、前回の失敗記録は消す(次の無関係な失敗が古い理由を引き継がない)
    func testClearsRevivalFailureReasonOnSuccess() async {
        let avdID = "ftlanerecoverytest-ledger-success"
        RevivalOutcomeLedger.shared.recordFailure(avdID: avdID, reason: "stale reason")
        let d1 = device("ledger-success", avd: avdID)
        _ = await AndroidLaneRecovery.bootMissingDevices(
            devices: [d1], locale: "ja_JP", log: { _ in },
            boot: { _, _ in })
        XCTAssertNil(RevivalOutcomeLedger.shared.failureReason(avdID: avdID))
    }
}
