// FleetSplit(--fleet --split の LPT ビンパッキング)の純粋ロジック。
// 期待値は手計算で固定する(「同じ入力を2回流して同じ結果になる」だけでは弱い —— 具体的な
// 割り当てそのものを固定し、破ったら落ちるようにする)。

import XCTest
@testable import FTCore

final class FleetSplitTests: XCTestCase {

    private func duration(_ id: String, _ ms: Double, _ platform: String = "ios") -> LPTScheduler.Duration {
        LPTScheduler.Duration(scenarioID: id, platform: platform, medianMs: ms)
    }

    // MARK: - LPT 貪欲割り当て(手計算で固定)

    func testGreedyAssignsLongestFirstToLightestFittingEntry() throws {
        // 見積り降順: A.one(5000) > C.three(4000) > B.two(3000) > D.four(1000) = E.five(1000)
        // (D/E は同着なので scenario ID 昇順で D が先)。
        // 貪欲な詰め方(手計算): A→entry0(0→5000) / C→entry1(0→4000) / B→entry1(4000→7000) /
        // D→entry0(5000→6000) / E→entry0(6000→7000)。最終負荷は両エントリとも 7000ms で並ぶ。
        let durations = [
            duration("A.one", 5_000), duration("B.two", 3_000), duration("C.three", 4_000, "android"),
        ]
        let scenarios: [(id: String, platform: String?)] = [
            ("A.one", nil), ("B.two", nil), ("C.three", nil), ("D.four", nil), ("E.five", nil),
        ]
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: durations,
            entryPlatforms: [["ios", "android"], ["ios", "android"]], unknownDurationMs: 1_000)

        XCTAssertEqual(buckets, [
            FleetSplit.Bucket(entryIndex: 0, scenarioIDs: ["A.one", "D.four", "E.five"], estimatedMs: 7_000),
            FleetSplit.Bucket(entryIndex: 1, scenarioIDs: ["C.three", "B.two"], estimatedMs: 7_000),
        ])
    }

    // MARK: - platform 適合

    func testRespectsPlatformAffinityAndFillsLightestFittingEntry() throws {
        // entry0 = ios のみ、entry1 = android のみ。実績は無い(全 unknownDurationMs=1000 で同着) ——
        // 見積り降順の同着は ID 昇順: AndroidOnly.one < Either.one < IosOnly.one。
        // AndroidOnly.one は entry1 にしか入らない → entry1(0→1000)。
        // Either.one はどちらでも良く、entry0 が軽い(0<1000)ので entry0(0→1000)。
        // IosOnly.one は entry0 にしか入らない → entry0(1000→2000)。
        let scenarios: [(id: String, platform: String?)] = [
            ("IosOnly.one", "ios"), ("AndroidOnly.one", "android"), ("Either.one", nil),
        ]
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: [],
            entryPlatforms: [["ios"], ["android"]], unknownDurationMs: 1_000)

        XCTAssertEqual(buckets, [
            FleetSplit.Bucket(entryIndex: 0, scenarioIDs: ["Either.one", "IosOnly.one"], estimatedMs: 2_000),
            FleetSplit.Bucket(entryIndex: 1, scenarioIDs: ["AndroidOnly.one"], estimatedMs: 1_000),
        ])
    }

    func testThrowsWhenNoEntryFitsTheScenariosPlatform() {
        XCTAssertThrowsError(try FleetSplit.partition(
            scenarios: [("X.one", "android")], durations: [],
            entryPlatforms: [["ios"]], unknownDurationMs: 1_000)
        ) { error in
            XCTAssertEqual(error as? FleetSplit.FleetSplitError,
                           .noFittingEntry(scenarioID: "X.one", platform: "android"))
        }
    }

    func testThrowsWhenNoEntriesExistAtAll() {
        XCTAssertThrowsError(try FleetSplit.partition(
            scenarios: [("X.one", nil)], durations: [],
            entryPlatforms: [], unknownDurationMs: 1_000)
        ) { error in
            XCTAssertEqual(error as? FleetSplit.FleetSplitError,
                           .noFittingEntry(scenarioID: "X.one", platform: "ios/android"))
        }
    }

    // MARK: - 空バケツ(正常系)

    func testEmptyScenarioListYieldsOneEmptyBucketPerEntry() throws {
        let buckets = try FleetSplit.partition(
            scenarios: [], durations: [],
            entryPlatforms: [["ios", "android"], ["ios"]], unknownDurationMs: 1_000)

        XCTAssertEqual(buckets, [
            FleetSplit.Bucket(entryIndex: 0, scenarioIDs: [], estimatedMs: 0),
            FleetSplit.Bucket(entryIndex: 1, scenarioIDs: [], estimatedMs: 0),
        ])
    }

    func testMoreEntriesThanScenariosLeavesSomeBucketsEmpty() throws {
        let buckets = try FleetSplit.partition(
            scenarios: [("A.one", nil)], durations: [],
            entryPlatforms: [["ios"], ["ios"], ["ios"]], unknownDurationMs: 1_000)

        XCTAssertEqual(buckets, [
            FleetSplit.Bucket(entryIndex: 0, scenarioIDs: ["A.one"], estimatedMs: 1_000),
            FleetSplit.Bucket(entryIndex: 1, scenarioIDs: [], estimatedMs: 0),
            FleetSplit.Bucket(entryIndex: 2, scenarioIDs: [], estimatedMs: 0),
        ])
    }

    // MARK: - 実績の platform 混在

    func testUsesTheLargerMedianAcrossPlatformsForAnUnspecifiedPlatformScenario() throws {
        // Mixed.one は ios/android 両方に実績があり、大きい方(android=9000)を安全側として採る。
        // 実測どおり動けば entry0(9000) 単独より entry1 の合計(4000+4000=8000)の方が軽いので、
        // 2本目の Filler.two は entry1 へ入る(手計算で固定)
        let durations = [
            duration("Mixed.one", 3_000, "ios"),
            duration("Mixed.one", 9_000, "android"),
            duration("Filler.one", 4_000, "ios"),
            duration("Filler.two", 4_000, "ios"),
        ]
        let scenarios: [(id: String, platform: String?)] = [
            ("Mixed.one", nil), ("Filler.one", nil), ("Filler.two", nil),
        ]
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: durations,
            entryPlatforms: [["ios", "android"], ["ios", "android"]], unknownDurationMs: 1_000)

        XCTAssertEqual(buckets, [
            FleetSplit.Bucket(entryIndex: 0, scenarioIDs: ["Mixed.one"], estimatedMs: 9_000),
            FleetSplit.Bucket(entryIndex: 1, scenarioIDs: ["Filler.one", "Filler.two"], estimatedMs: 8_000),
        ])
    }
}

extension FleetSplitTests {

    /// **実績が1件も無いときは重みの絶対値が割り当てに影響しない**(全員同じ値なら
    /// 順序も選択も変わらない = LPT は本数の均等割りに退化する)。この性質があるから、
    /// FleetRunner は「根拠のある秒数」を選ぶ必要が無い(unknownDurationUnitWeight の項)。
    /// 値を変えても同じ割り当てになることを固定する
    func testAllUnknownDurationsSplitByCountRegardlessOfWeight() throws {
        let scenarios: [(id: String, platform: String?)] = [
            ("A.S0010", nil), ("B.S0010", nil), ("C.S0010", nil), ("D.S0010", nil), ("E.S0010", nil),
        ]
        let platforms: [Set<String>] = [["ios"], ["ios"]]

        let withUnitWeight = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: platforms, unknownDurationMs: 1.0)
        let withSeconds = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: platforms, unknownDurationMs: 60_000.0)

        XCTAssertEqual(withUnitWeight.map(\.scenarioIDs), withSeconds.map(\.scenarioIDs))
        // 本数の均等割り(5本 → 3 + 2)
        XCTAssertEqual(withUnitWeight.map(\.scenarioIDs.count).sorted(), [2, 3])
    }
}
