// ワーカーを一斉に起こさないための間隔(WorkerStagger)。
//
// 各シナリオは `condition { launchApp() }` から始まるので、N 台を同時に起こすと
// 最初の launch が N 本同時に走る。ブリッジ供給は「同時2台」に絞ってあるのに本番の
// launch は無制限、という非対称を埋めるための値。**効果は未検証**(凍結の観測は n=1)なので、
// 対照実験のために環境変数で差し替えられることまでを固定する。

import XCTest
@testable import FTCore

final class WorkerStaggerTests: XCTestCase {

    private func withEnv(_ value: String?, _ body: () -> Void) {
        let key = "FT_WORKER_STAGGER_SEC"
        let saved = ProcessInfo.processInfo.environment[key]
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        defer {
            if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
        }
        body()
    }

    func testDefaultIsAppliedWhenUnset() {
        withEnv(nil) {
            XCTAssertEqual(WorkerStagger.seconds, WorkerStagger.defaultSeconds)
        }
    }

    /// A/B のために差し替えられること(**0 で従来どおりの一斉起動**へ戻せる)
    func testEnvironmentOverridesIncludingZero() {
        withEnv("0") { XCTAssertEqual(WorkerStagger.seconds, 0) }
        withEnv("3.5") { XCTAssertEqual(WorkerStagger.seconds, 3.5) }
    }

    /// **不正値は既定へ倒す**。黙って 0(= 無効)にすると、実験のつもりが
    /// 「対策を外した run」になり、結果を取り違える
    func testInvalidValuesFallBackToTheDefault() {
        for bad in ["", "abc", "-1", "nan", "inf"] {
            withEnv(bad) {
                XCTAssertEqual(WorkerStagger.seconds, WorkerStagger.defaultSeconds,
                               "\(bad.debugDescription) が既定へ倒れていない")
            }
        }
    }

    /// **先頭2本は同時に起こす**(ユーザー決定)。待つのは3本目から
    func testFirstTwoWorkersStartTogether() {
        XCTAssertEqual(WorkerStagger.simultaneousHead, 2,
                       "BridgeProvisioner の「in-app の新規起動は同時2台」と揃える")
        // 10 台なら待つのは 8 本ぶん(先頭2本は待たない)
        let waits = max(0, 10 - WorkerStagger.simultaneousHead)
        XCTAssertEqual(waits, 8)
    }

    /// 既定値は「立ち上がりだけ伸びる」範囲に収まること(恒常的な遅さにしない)
    func testDefaultStaysSmallEnoughToOnlyAffectStartup() {
        XCTAssertGreaterThan(WorkerStagger.defaultSeconds, 0)
        let worstCase = WorkerStagger.defaultSeconds * Double(max(0, 10 - WorkerStagger.simultaneousHead))
        XCTAssertLessThanOrEqual(worstCase, 20,
                                 "10 レーンで 20 秒を超えると立ち上がりの遅延として無視できない")
    }
}

/// **配線を守る**(ソース走査)。値だけを検査するテストは、`RunOrchestrator` から
/// スタガーを丸ごと外す変更を素通しする —— 実際 2026-08-09 の変異テストで素通しした。
///
/// `RunOrchestrator` はドライバ・キュー・リースを要求するため単体で組めず、
/// 実行してタイミングを測る形のテストが置けない。この repo には同じ事情で
/// ソース走査に頼っている前例がある(SwipeForScrollForwardingTests)ので、それに倣う。
/// **ここが落ちたら、まず「スタガーを意図的に外したのか」を確かめること**。
final class WorkerStaggerWiringTests: XCTestCase {

    private var source: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/FTCore/RunOrchestrator.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// ワーカーを積む口は**1箇所だけ**(admit を迂回する経路を作らない)
    func testWorkersAreAdmittedThroughASinglePath() throws {
        // **コメントは数えない**(言及だけで落ちると、直し方が「コメントを消す」になってしまう)
        let code = try source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let sites = code.components(separatedBy: "group.addTask { await self.superviseWorker").count - 1
        XCTAssertEqual(sites, 1,
                       "ワーカーを積む口が \(sites) 箇所ある —"
                       + " admit を迂回する経路が生えていないか確かめること")
    }

    /// その1箇所が**門を通る**こと。判定そのものは `WorkerStartGate` にあり
    /// (`WorkerStartGateTests` が全分岐を実行する)、ここが守るのは**呼ばれていること**だけ
    func testTheAdmissionPathGoesThroughTheStartGate() throws {
        let text = try source
        XCTAssertTrue(text.contains("await startGate.waitForTurn("),
                      "ワーカー参加が門を通っていない(一斉起動へ戻っている)")
        XCTAssertTrue(text.contains("WorkerStartGate("),
                      "門を作っていない")
        // **実サンプラを渡していること** —— ここを固定値や nil にすると CPU の門が常に素通しになり、
        // WorkerStartGateTests は緑のまま(あちらは注入した台本しか見ない)
        XCTAssertTrue(text.contains("CPUSampler(") && text.contains("sampleCPU: { cpuSampler.sample() }"),
                      "CPU の門に実サンプラを渡していない(門が常に素通しになる)")
    }

    /// 門の既定は `WorkerStagger` の値から採る(呼び出し側で握り潰さない)
    func testTheGateUsesTheStaggerDefaults() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/WorkerStartGate.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        for defaulted in ["= WorkerStagger.seconds", "= WorkerStagger.simultaneousHead",
                          "= WorkerStagger.cpuCeiling", "= WorkerStagger.cpuWaitCap",
                          "= WorkerStagger.cpuPollInterval"] {
            XCTAssertTrue(text.contains(defaulted), "門の既定 \(defaulted) が外れている")
        }
    }
}
