// モニターの凍結検知の**配線**を固定する。
//
// 2026-08-11 の実害: 判定ロジック(`MonitorFrozenDebounce`)は変異 4/4 で守られていたのに、
// **呼び出し側が本番で一度も到達しなかった**ため `Frozen:` が恒久的に 0 だった。
// 原因は「配信を抑制中(タイルがストリーミング表示中)のデバイスはスクショ取得ごと飛ばす」
// ガードが観測より手前にあったこと。実運用では全デバイスが抑制対象なので、
// 検知は構造的に一度も走らない状態だった。
//
// ここで固定するのは2つ:
//   ① 抑制中でも**観測は続く**(cadence が落ちるだけ)= capturePlan
//   ② run が公表した凍結をモニターが**読む**(自前の観測だけを見ない)= frozenVerdict
// ②は陽性対照そのもの(注入 → 公表 → モニターが凍結と言う → 解除)。

import XCTest
@testable import ftester
@testable import FTCore

final class MonitorFrozenWiringTests: XCTestCase {

    // MARK: - ① 抑制は「配る」だけに効く

    /// 非抑制のデバイスは毎サイクル撮って配る
    func testUnsuppressedDeviceIsCapturedAndDelivered() {
        var lastProbeAt: [String: Date] = [:]
        let plan = ApiMonitorCommand.capturePlan(ids: ["a"], suppressed: { _ in false },
                                                 lastProbeAt: &lastProbeAt, now: Date())
        XCTAssertEqual(plan, [ApiMonitorCommand.CaptureDecision(id: "a", deliver: true)])
    }

    /// **これが本丸**: 抑制中でも撮る。配らないだけ
    func testSuppressedDeviceIsStillCaptured() {
        var lastProbeAt: [String: Date] = [:]
        let plan = ApiMonitorCommand.capturePlan(ids: ["a"], suppressed: { _ in true },
                                                 lastProbeAt: &lastProbeAt, now: Date())
        XCTAssertEqual(plan, [ApiMonitorCommand.CaptureDecision(id: "a", deliver: false)],
                       "抑制中に観測を止めると凍結検知が丸ごと死ぬ(2026-08-11 の実害)")
    }

    /// 全デバイスが抑制対象でも、観測対象は1台も減らない(実運用がまさにこの形)
    func testEveryDeviceSuppressedStillYieldsObservations() {
        var lastProbeAt: [String: Date] = [:]
        let ids = (1...18).map { "device-\($0)" }
        let plan = ApiMonitorCommand.capturePlan(ids: ids, suppressed: { _ in true },
                                                 lastProbeAt: &lastProbeAt, now: Date())
        XCTAssertEqual(plan.count, ids.count)
        XCTAssertTrue(plan.allSatisfy { !$0.deliver })
    }

    /// 抑制中は cadence を落とす(毎サイクル撮ると配信を止めた意味が無い)
    func testSuppressedDeviceRespectsProbeInterval() {
        var lastProbeAt: [String: Date] = [:]
        let start = Date()
        _ = ApiMonitorCommand.capturePlan(ids: ["a"], suppressed: { _ in true },
                                          lastProbeAt: &lastProbeAt, probeInterval: 6, now: start)
        let tooSoon = ApiMonitorCommand.capturePlan(
            ids: ["a"], suppressed: { _ in true },
            lastProbeAt: &lastProbeAt, probeInterval: 6, now: start.addingTimeInterval(2))
        XCTAssertTrue(tooSoon.isEmpty)
        let due = ApiMonitorCommand.capturePlan(
            ids: ["a"], suppressed: { _ in true },
            lastProbeAt: &lastProbeAt, probeInterval: 6, now: start.addingTimeInterval(6))
        XCTAssertEqual(due.count, 1)
    }

    /// 撮らなかった回で時計を進めない(進めると間隔が延び続けて事実上観測が止まる)
    func testSkippedCycleDoesNotAdvanceTheClock() {
        var lastProbeAt: [String: Date] = [:]
        let start = Date()
        _ = ApiMonitorCommand.capturePlan(ids: ["a"], suppressed: { _ in true },
                                          lastProbeAt: &lastProbeAt, probeInterval: 6, now: start)
        for offset in [1.0, 2.0, 3.0, 4.0, 5.0] {
            _ = ApiMonitorCommand.capturePlan(
                ids: ["a"], suppressed: { _ in true },
                lastProbeAt: &lastProbeAt, probeInterval: 6, now: start.addingTimeInterval(offset))
        }
        let due = ApiMonitorCommand.capturePlan(
            ids: ["a"], suppressed: { _ in true },
            lastProbeAt: &lastProbeAt, probeInterval: 6, now: start.addingTimeInterval(6))
        XCTAssertEqual(due.count, 1, "間引いた回で時計が進むと、いつまでも期限が来ない")
    }

    /// 抑制が解けたら次のサイクルで配信が戻る
    func testDeliveryResumesWhenSuppressionLifts() {
        var lastProbeAt: [String: Date] = [:]
        var suppressed = true
        let start = Date()
        _ = ApiMonitorCommand.capturePlan(ids: ["a"], suppressed: { _ in suppressed },
                                          lastProbeAt: &lastProbeAt, now: start)
        suppressed = false
        let plan = ApiMonitorCommand.capturePlan(ids: ["a"], suppressed: { _ in suppressed },
                                                 lastProbeAt: &lastProbeAt,
                                                 now: start.addingTimeInterval(2))
        XCTAssertEqual(plan, [ApiMonitorCommand.CaptureDecision(id: "a", deliver: true)])
    }

    // MARK: - ② 陽性対照: run が公表した凍結をモニターが読む

    private func makeStateDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-monitor-frozen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 観測も公表も注入も無ければ健全
    func testHealthyWhenNothingObserved() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-a", key: "udid-a", debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: dir, environment: [:])
        XCTAssertFalse(verdict.isFrozen)
    }

    /// **run が公表 → モニターが凍結と言う**。ここが切れていたのが今回の欠陥
    func testPublishedVerdictFromRunIsSurfaced() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        DeviceFrozenStore.publish(stateDir: dir, key: "udid-a",
                                  verdict: FrozenVerdict([.uniformBlank]))
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-a", key: "udid-a", debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: dir, environment: [:])
        XCTAssertTrue(verdict.isFrozen, "run が知っている凍結をモニターが知らない状態を作らない")
        XCTAssertEqual(verdict.evidence, [.uniformBlank])
    }

    /// 回復して公表が消えたらモニターの表示も戻る
    func testVerdictClearsWhenPublicationIsRemoved() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        DeviceFrozenStore.publish(stateDir: dir, key: "udid-a",
                                  verdict: FrozenVerdict([.uniformBlank]))
        DeviceFrozenStore.clear(stateDir: dir, key: "udid-a")
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-a", key: "udid-a", debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: dir, environment: [:])
        XCTAssertFalse(verdict.isFrozen)
    }

    /// 注入(陽性対照の口)でモニターが凍結と言う。実デバイスを凍らせずに経路を通せる
    func testInjectionSurfacesWithoutAnyObservation() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-a", key: "udid-a", debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: dir, environment: [FrozenInjection.environmentKey: "udid-a"])
        XCTAssertTrue(verdict.isFrozen)
        XCTAssertEqual(verdict.evidence, [.injected])
    }

    /// 注入は**名指しした機だけ**(対照実験が成立するために必須)
    func testInjectionDoesNotLeakToOtherDevices() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-b", key: "udid-b", debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: dir, environment: [FrozenInjection.environmentKey: "udid-a"])
        XCTAssertFalse(verdict.isFrozen)
    }

    /// 自前の観測(一様フレーム2連続)も従来どおり効く
    func testOwnObservationStillCounts() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        _ = debounce.record(uniformBlank: true, id: "tile-a")
        _ = debounce.record(uniformBlank: true, id: "tile-a")
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-a", key: "udid-a", debounce: debounce, stateDir: dir, environment: [:])
        XCTAssertTrue(verdict.isFrozen)
    }

    /// キーの無いデバイス(未登録シミュレータ等)でも公表の読み取りで落ちない
    func testMissingKeyIsHandled() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-a", key: nil, debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: dir, environment: [FrozenInjection.environmentKey: "udid-a"])
        XCTAssertFalse(verdict.isFrozen)
    }

    // MARK: - ③ run 中は自前の受動観測を確定に使わない

    /// **run 中の一様フレームで ❄️ を出さない**: run はアプリを terminate→relaunch し続けるので
    /// 合間の真っ黒は正常に出る。黒画面の2種(描画要求なし/本物の wedge)は受動観測では分けられない
    func testOwnUniformBlankIsSuppressedWhileInRun() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var debounce = MonitorFrozenDebounce(confirmThreshold: 2)
        _ = debounce.record(uniformBlank: true, id: "tile-a")
        _ = debounce.record(uniformBlank: true, id: "tile-a")
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-a", key: "udid-a", debounce: debounce, stateDir: dir,
            inRun: true, environment: [:])
        XCTAssertFalse(verdict.isFrozen, "run がステップを進められている機は凍結していない")
    }

    /// run 中でも **run が公表した凍結**は表示する(run 側の能動プローブが本物を見分ける)
    func testPublishedVerdictStillSurfacesWhileInRun() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        DeviceFrozenStore.publish(stateDir: dir, key: "udid-a",
                                  verdict: FrozenVerdict([.uniformBlank]))
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-a", key: "udid-a", debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: dir, inRun: true, environment: [:])
        XCTAssertTrue(verdict.isFrozen, "run 自身が見つけた凍結までモニターが黙ると回復が見えない")
    }

    /// run 中でも**注入**は表示する(陽性対照は run の有無に関わらず経路を通せること)
    func testInjectionStillSurfacesWhileInRun() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ApiMonitorCommand.frozenVerdict(
            id: "tile-a", key: "udid-a", debounce: MonitorFrozenDebounce(confirmThreshold: 2),
            stateDir: dir, inRun: true,
            environment: [FrozenInjection.environmentKey: "udid-a"])
        XCTAssertTrue(verdict.isFrozen)
        XCTAssertEqual(verdict.evidence, [.injected])
    }
}
