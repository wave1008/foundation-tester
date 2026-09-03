// FMLivenessProbe.refresh の門①「実仕事が台帳を養っている間は撃たない」。
// 実測(2026-09-04): run が vision しか呼ばないと text の控えだけが古くなり、経路ごとの鮮度で
// 見ていたプローブが 60 秒ごとに text を撃っていた(1回 0.7〜4.7s。fmConcurrency=1 の機械では
// FMLock も取る)。判定は純粋関数 realWorkIsFeedingTheLedger に置き、refresh がそれを最初に通る
// ことをソース走査で固定する(実呼び出しを伴う refresh 自体は単体では回せない)。

import XCTest
import FTCore
@testable import FTFoundationModels

final class FMLivenessProbeInUseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func verdict(_ source: FMLiveness.Source, ageSeconds: Double) -> FMLiveness.Verdict {
        FMLiveness.Verdict(state: .alive, checkedAt: now.timeIntervalSince1970 - ageSeconds,
                           source: source, ms: 10)
    }

    /// vision だけが呼ばれている run(occlusion-guard だけの run)= 使用中。text が古くても撃たない
    func testFreshCallOnOnePathCountsAsInUse() {
        let record = FMLiveness.Record(text: verdict(.probe, ageSeconds: 300),
                                       vision: verdict(.call, ageSeconds: 5))
        XCTAssertTrue(FMLivenessProbe.realWorkIsFeedingTheLedger(record, now: now, maxAge: 60))
    }

    /// プローブ由来の新しさは使用中の根拠にしない(自分の控えを根拠にすると二度と撃たなくなる)
    func testFreshProbeDoesNotCountAsInUse() {
        let record = FMLiveness.Record(text: verdict(.probe, ageSeconds: 5),
                                       vision: verdict(.probe, ageSeconds: 5))
        XCTAssertFalse(FMLivenessProbe.realWorkIsFeedingTheLedger(record, now: now, maxAge: 60))
    }

    /// 古い実呼び出しは使用中ではない(run が終われば撃ってよい)
    func testStaleCallDoesNotCountAsInUse() {
        let record = FMLiveness.Record(text: verdict(.call, ageSeconds: 61),
                                       vision: verdict(.call, ageSeconds: 120))
        XCTAssertFalse(FMLivenessProbe.realWorkIsFeedingTheLedger(record, now: now, maxAge: 60))
        XCTAssertNil(nil as FMLiveness.Record?)
        XCTAssertFalse(FMLivenessProbe.realWorkIsFeedingTheLedger(nil, now: now, maxAge: 60))
    }

    /// 記録なし(unknown)は撃ち直す対象
    func testNilVerdictIsStale() {
        XCTAssertTrue(FMLivenessProbe.isStaleDespiteFreshness(nil, breakerIsOpen: true))
        XCTAssertTrue(FMLivenessProbe.isStaleDespiteFreshness(nil, breakerIsOpen: false))
    }

    /// 実観測(source=.call)は breakerIsOpen に関わらず無効化しない
    func testRealCallVerdictIsNeverStaleDueToBreaker() {
        let real = FMLiveness.Verdict(state: .alive, checkedAt: now.timeIntervalSince1970,
                                      source: .call, ms: 10)
        XCTAssertFalse(FMLivenessProbe.isStaleDespiteFreshness(real, breakerIsOpen: true))
        XCTAssertFalse(FMLivenessProbe.isStaleDespiteFreshness(real, breakerIsOpen: false))
    }

    /// ブレーカ由来の dead は、ブレーカがまだ開いている間は代理の値として有効
    func testBreakerSourcedDeadIsValidWhileBreakerOpen() {
        let breakerDead = FMLiveness.Verdict(state: .dead, checkedAt: now.timeIntervalSince1970,
                                             source: .breaker)
        XCTAssertFalse(FMLivenessProbe.isStaleDespiteFreshness(breakerDead, breakerIsOpen: true))
    }

    /// ブレーカが閉じた瞬間、直前に書いたブレーカ由来の dead は無効(再確認させる)
    func testBreakerSourcedDeadIsStaleOnceBreakerCloses() {
        let breakerDead = FMLiveness.Verdict(state: .dead, checkedAt: now.timeIntervalSince1970,
                                             source: .breaker)
        XCTAssertTrue(FMLivenessProbe.isStaleDespiteFreshness(breakerDead, breakerIsOpen: false))
    }

    /// 実プローブ由来(source=.probe)の dead はブレーカの開閉と無関係に有効なまま
    func testProbeSourcedDeadIsNeverStaleDueToBreaker() {
        let probeDead = FMLiveness.Verdict(state: .dead, checkedAt: now.timeIntervalSince1970,
                                           source: .probe)
        XCTAssertFalse(FMLivenessProbe.isStaleDespiteFreshness(probeDead, breakerIsOpen: false))
    }

    /// refresh が**最初に**この判定を通ること(消えると経路ごとの鮮度だけで撃つ形へ戻る)
    func testRefreshConsultsTheInUseGateBeforeProbing() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent(
            "Sources/FTFoundationModels/FMLivenessProbe.swift"), encoding: .utf8)
        let gate = code.range(of: "if realWorkIsFeedingTheLedger(FMLiveness.read(), now: now, maxAge: maxAge) {")
        let stale = code.range(of: "var stale: [FMLiveness.Path] = []")
        XCTAssertNotNil(gate, "refresh が使用中判定を通っていない")
        if let gate, let stale {
            XCTAssertLessThan(gate.lowerBound, stale.lowerBound, "使用中判定が経路ごとの鮮度判定より後ろにある")
        }
    }
}
