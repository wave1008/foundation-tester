import XCTest

import FTCore
@testable import fleetest

/// ブリッジを持たない iOS シミュレータの「1サイクル1台の順繰り」を固定する。
/// この経路は**配信が張れない台にとって唯一の絵の出所**なので、選ばれなくなる退行は
/// タイルが黙って真っ黒になる形で出る(2026-08-28 の実害と同じ見え方)。
final class MonitorSimctlCaptureTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testPicksNothingWhenThereAreNoCandidates() {
        var last: [String: Date] = [:]
        XCTAssertNil(ApiMonitorCommand.simctlCapturePick(ids: [], lastCapturedAt: &last, now: t0))
        XCTAssertTrue(last.isEmpty)
    }

    /// 1サイクルに撮るのは1台だけ(戻り値が1つ・時計が進むのもその台だけ)
    func testPicksOneDevicePerCycle() {
        var last: [String: Date] = [:]
        let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a", "b", "c"],
                                                       lastCapturedAt: &last, now: t0)
        XCTAssertEqual(pick, "a")
        XCTAssertEqual(last, ["a": t0])
    }

    /// 順繰り: 3台なら3サイクルで一巡し、4サイクル目は最初の台へ戻る
    func testCyclesThroughEveryDevice() {
        var last: [String: Date] = [:]
        var picks: [String] = []
        for i in 0..<4 {
            let now = t0.addingTimeInterval(Double(i) * 2)
            if let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a", "b", "c"],
                                                              lastCapturedAt: &last, now: now) {
                picks.append(pick)
            }
        }
        XCTAssertEqual(picks, ["a", "b", "c", "a"])
    }

    /// 途中で増えた台は「一度も撮っていない」= 最優先で拾う(新しいタイルが一巡待ちで
    /// 真っ黒のまま残らない)
    func testANewlyAppearedDeviceIsPickedFirst() {
        var last: [String: Date] = ["a": t0, "b": t0.addingTimeInterval(2)]
        let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a", "b", "fresh"],
                                                       lastCapturedAt: &last,
                                                       now: t0.addingTimeInterval(4))
        XCTAssertEqual(pick, "fresh")
    }

    /// 候補から消えた台の時計は残っていても選択を歪めない(消えた台を選ばない)
    func testDoesNotPickADeviceThatLeftTheCandidateSet() {
        var last: [String: Date] = ["gone": .distantPast, "a": t0]
        let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a"], lastCapturedAt: &last,
                                                       now: t0.addingTimeInterval(2))
        XCTAssertEqual(pick, "a")
    }
}

// ---- 撮る対象かの判定(isSimctlCaptureTarget)----
// **ブリッジの無い台の state は登録の有無で割れる** —— 未登録の合成デバイスは "connected"、
// 台帳に載っている台は "booted"。connected だけを見ていた頃は、台帳に載っていてブリッジを
// 持たない台の絵の出所がゼロになり、タイルが「接続中」のまま永久に埋まらなかった(2026-08-29)。

extension MonitorSimctlCaptureTests {

    private func state(_ state: String, port: UInt16? = nil, udid: String? = "UDID",
                       platform: String = "ios", kind: DeviceKind? = nil) -> DeviceRuntimeState {
        DeviceRuntimeState(
            target: MonitorTarget(platform: platform,
                                  spec: DeviceSpec(name: "sim", kind: kind)),
            state: state, detail: "", iosPort: port, androidSerial: nil, iosUdid: udid)
    }

    func testBridgelessSimulatorIsCapturedWhateverItsStateIsCalled() {
        // 台帳に載っている台(booted)も、未登録の合成デバイス(connected)も同じ扱い
        XCTAssertTrue(ApiMonitorCommand.isSimctlCaptureTarget(state: state("booted")))
        XCTAssertTrue(ApiMonitorCommand.isSimctlCaptureTarget(state: state("connected")))
    }

    func testStoppedOrUnobservedDevicesAreNotCaptured() {
        XCTAssertFalse(ApiMonitorCommand.isSimctlCaptureTarget(state: state("offline")))
        XCTAssertFalse(ApiMonitorCommand.isSimctlCaptureTarget(state: state("unknown")))
    }

    func testDevicesWithABridgeGoThroughTheBridgeInstead() {
        // ポートがあるなら /screenshot で撮れる(重い simctl を撃つ理由が無い)
        XCTAssertFalse(ApiMonitorCommand.isSimctlCaptureTarget(state: state("booted", port: 8127)))
    }

    func testWithoutAUdidOrOnAnotherPlatformThereIsNothingToShoot() {
        XCTAssertFalse(ApiMonitorCommand.isSimctlCaptureTarget(state: state("booted", udid: nil)))
        XCTAssertFalse(ApiMonitorCommand.isSimctlCaptureTarget(state: state("booted", platform: "android")))
    }

    func testPhysicalDevicesCannotBeShotWithSimctl() {
        XCTAssertFalse(ApiMonitorCommand.isSimctlCaptureTarget(state: state("booted", kind: .physical)))
    }

    /// **順繰りの時計を毎サイクル捨てると回らない**: 撮り続ける対象(booted)の時計を
    /// 捨てる実装だと、全台が「未撮影」に戻って常に同じ1台が選ばれる
    func testKeepingTheClockIsWhatMakesTheRotationWork() {
        var kept: [String: Date] = [:]
        var wiped: [String: Date] = [:]
        var keptPicks: [String] = []
        var wipedPicks: [String] = []
        for i in 0..<4 {
            let now = t0.addingTimeInterval(Double(i) * 2)
            if let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a", "b"],
                                                              lastCapturedAt: &kept, now: now) {
                keptPicks.append(pick)
            }
            if let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a", "b"],
                                                              lastCapturedAt: &wiped, now: now) {
                wipedPicks.append(pick)
            }
            wiped.removeAll()  // 「毎サイクル捨てる」実装の再現
        }
        XCTAssertEqual(keptPicks, ["a", "b", "a", "b"])
        XCTAssertEqual(wipedPicks, ["a", "a", "a", "a"], "捨てると2台目が永久に撮られない")
    }
}
