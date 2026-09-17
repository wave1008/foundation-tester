// 失敗後のブリッジ生存判定(`BridgeLiveness.decide`)。
//
// 2026-09-18 の実測で2つの誤判定が出た:
// ①LAN の実機は Wi-Fi の瞬断でも接続不能(-1004)を返すのに、即「死亡」と確定して生きたランナーを止めていた。
// ②対象アプリが外部要因で背面に回ると XCUITest の 1 照会が 31 秒ブロックし、その間 /status もログも止まる。
//   ログ静止の近道(15 秒)で確定すると、**生きているランナー**を止めて建て直していた。

import XCTest
@testable import FTCore

final class BridgeLivenessTests: XCTestCase {
    private let threshold: TimeInterval = 15

    private func decide(_ probe: BridgeProbeOutcome, host: String? = nil, alive: Bool? = nil,
                        logSilent: TimeInterval? = nil, expired: Bool = false) -> BridgeLiveness.Verdict {
        BridgeLiveness.decide(probe: probe, host: host, runnerProcessAlive: alive,
                              logSilentSeconds: logSilent, logSilenceThreshold: threshold,
                              windowExpired: expired)
    }

    func testAnAnsweringBridgeIsReachableEvenWhenItsLogIsSilent() {
        XCTAssertEqual(decide(.ok, alive: true, logSilent: 120), .reachable)
    }

    func testAnotherDevicesBridgeIsUnreachableWithItsOwnDetail() {
        XCTAssertEqual(decide(.hijacked(detail: "udid mismatch"), alive: true),
                       .unreachable(detail: "udid mismatch"))
    }

    /// ループバック(シミュレータ・USB トンネル)の refused は LISTEN 不在の証拠
    func testRefusalOnLoopbackIsConclusive() {
        guard case .unreachable = decide(.refused, host: "127.0.0.1", alive: true) else {
            return XCTFail("ループバックの refused は即確定のはず")
        }
    }

    /// LAN の refused は確定させず、観察を続ける(ランナーは生きていることがある)
    func testRefusalOverLANKeepsObserving() {
        XCTAssertEqual(decide(.refused, host: "192.168.20.7", alive: true, logSilent: 30),
                       .keepObserving)
    }

    /// ランナープロセスが消えていれば、窓の残りを待たずに確定してよい(最も確かな死の証拠)
    func testAGoneRunnerProcessIsConclusiveEvenOverLAN() {
        XCTAssertEqual(decide(.refused, host: "192.168.20.7", alive: false, logSilent: 1),
                       .unreachable(detail: "its runner process is gone"))
    }

    /// **本命**: プロセスが生きている間はログ静止の近道を使わない(31 秒ブロックする照会がある)
    func testALiveRunnerProcessIsNotDeclaredDeadByTheLogSilenceShortcut() {
        XCTAssertEqual(decide(.silent, alive: true, logSilent: 31), .keepObserving)
    }

    /// 生死が分からない(in-app 等)ときは従来どおりログ静止で確定する
    func testTheLogSilenceShortcutStillAppliesWhenLivenessIsUnknown() {
        XCTAssertEqual(decide(.silent, alive: nil, logSilent: 31),
                       .unreachable(detail: "its runner log stopped growing"))
    }

    /// 窓を使い切ってもログが伸び続けていれば busy(健全)側に倒す(既存の規律)
    func testAGrowingLogAtTheEndOfTheWindowMeansBusy() {
        XCTAssertEqual(decide(.silent, alive: true, logSilent: 2, expired: true), .reachable)
    }

    /// 窓を使い切って無応答なら確定する。生きていたという事実は離脱理由に残す
    func testTheWindowExpiryNamesWhatWasObserved() {
        XCTAssertEqual(
            decide(.silent, alive: true, logSilent: 60, expired: true),
            .unreachable(detail: "its runner process was still alive but did not answer /status"
                + " during the observation window"))
        XCTAssertEqual(decide(.silent, alive: nil, logSilent: nil, expired: true),
                       .unreachable(detail: nil))
    }
}
