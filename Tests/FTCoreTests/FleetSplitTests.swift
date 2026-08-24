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

    // MARK: - 対象外(宣言 platform の台が fleet に無い)

    func testApplicabilitySkipsDeclaredPlatformsTheFleetCannotRun() {
        let split = FleetSplit.applicability(
            scenarios: [("X.android", "android"), ("X.ios", "ios"), ("X.any", nil)],
            entryPlatforms: [["ios"], ["ios"]])
        XCTAssertEqual(split.runnable.map(\.id), ["X.ios", "X.any"],
                       "platform 未宣言は常に runnable・fleet が持つ platform の宣言も runnable")
        XCTAssertEqual(split.notApplicable.map(\.id), ["X.android"],
                       "iOS だけの fleet に Android 宣言 = 単機の run と同じく対象外(throw しない)")
        XCTAssertNoThrow(try FleetSplit.partition(
            scenarios: split.runnable, durations: [], entryPlatforms: [["ios"], ["ios"]],
            unknownDurationMs: 1_000))
    }

    func testApplicabilityKeepsEverythingWhenNoEntryHasAnyPlatform() {
        // 全エントリ空 = runPlatforms 空 → 全件 runnable のまま partition が設定ミスとして throw する
        let split = FleetSplit.applicability(scenarios: [("X.one", "android")], entryPlatforms: [[], []])
        XCTAssertEqual(split.runnable.map(\.id), ["X.one"])
        XCTAssertTrue(split.notApplicable.isEmpty)
        XCTAssertThrowsError(try FleetSplit.partition(
            scenarios: split.runnable, durations: [], entryPlatforms: [[], []], unknownDurationMs: 1_000))
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

// MARK: - entryCapacities(デバイス単位 host の分散。台数で重み付ける)

extension FleetSplitTests {

    /// 既定(省略)は全員 1 = 従来の「負荷合計が最小のエントリへ」。ここが変わると
    /// --fleet --split の割り当てが黙って変わるので、明示の 1 と省略が一致することを固定する
    func testOmittedCapacitiesBehaveExactlyLikeAllOnes() throws {
        let scenarios: [(id: String, platform: String?)] =
            [("A.one", nil), ("B.two", nil), ("C.three", nil)]
        let platforms: [Set<String>] = [["ios"], ["ios"]]
        let omitted = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: platforms, unknownDurationMs: 1_000)
        let explicit = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: platforms,
            unknownDurationMs: 1_000, entryCapacities: [1, 1])
        XCTAssertEqual(omitted, explicit)
    }

    /// 台数が3倍のホストには3倍のシナリオが行く。総量で均すと、台数の少ない側だけが
    /// 最後まで走り続けて壁時計が縮まない(混在プロファイルの分散はこれが目的)
    func testCapacitySendsMoreScenariosToTheMachineWithMoreDevices() throws {
        let scenarios: [(id: String, platform: String?)] = (1...8).map { ("S.\($0)", nil) }
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["ios"]],
            unknownDurationMs: 1_000, entryCapacities: [3, 1])
        XCTAssertEqual(buckets.map(\.scenarioIDs.count), [6, 2])
    }

    /// 台数で重み付けても platform 適合は曲げない(走らせられない機械へ配ると
    /// 「走ったつもりで走っていない」になる)
    func testCapacityNeverOverridesPlatformAffinity() throws {
        let scenarios: [(id: String, platform: String?)] =
            [("A.ios", "ios"), ("B.ios", "ios"), ("C.android", "android")]
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["android"]],
            unknownDurationMs: 1_000, entryCapacities: [1, 10])
        XCTAssertEqual(buckets[0].scenarioIDs.sorted(), ["A.ios", "B.ios"])
        XCTAssertEqual(buckets[1].scenarioIDs, ["C.android"])
    }
}

// MARK: - machineContext(機械ごとの速度差・ディスパッチ固定費。リモート実行)

extension FleetSplitTests {

    private func machineDuration(_ id: String, _ ms: Double, machine: String,
                                 platform: String = "ios") -> LPTScheduler.MachineDuration {
        LPTScheduler.MachineDuration(scenarioID: id, platform: platform, machine: machine, medianMs: ms)
    }

    /// machineContext: nil(省略・明示 nil どちらも)は既存呼び出しと同一の Bucket 列を返す
    func testMachineContextNilMatchesExistingBuckets() throws {
        let durations = [
            duration("A.one", 5_000), duration("B.two", 3_000), duration("C.three", 4_000, "android"),
        ]
        let scenarios: [(id: String, platform: String?)] = [
            ("A.one", nil), ("B.two", nil), ("C.three", nil), ("D.four", nil), ("E.five", nil),
        ]
        let entryPlatforms: [Set<String>] = [["ios", "android"], ["ios", "android"]]

        let omitted = try FleetSplit.partition(
            scenarios: scenarios, durations: durations,
            entryPlatforms: entryPlatforms, unknownDurationMs: 1_000)
        let explicitNil = try FleetSplit.partition(
            scenarios: scenarios, durations: durations,
            entryPlatforms: entryPlatforms, unknownDurationMs: 1_000, machineContext: nil)

        XCTAssertEqual(omitted, explicitNil)
        XCTAssertEqual(omitted, [
            FleetSplit.Bucket(entryIndex: 0, scenarioIDs: ["A.one", "D.four", "E.five"], estimatedMs: 7_000),
            FleetSplit.Bucket(entryIndex: 1, scenarioIDs: ["C.three", "B.two"], estimatedMs: 7_000),
        ])
    }

    /// sameMs がある machine のエントリはその値で積まれる(混合中央値 10,000 ではない)
    func testSameMachineDurationOverridesMixedEstimate() throws {
        let durations = [duration("S", 10_000, "ios")]
        let machineDurations = [machineDuration("S", 2_000, machine: "fast")]
        let context = FleetSplit.MachineContext(
            entryMachines: ["fast", nil], entryFixedOffsetsMs: [0, 0], machineDurations: machineDurations)

        let buckets = try FleetSplit.partition(
            scenarios: [("S", nil)], durations: durations,
            entryPlatforms: [["ios"], ["ios"]], unknownDurationMs: 1_000, machineContext: context)

        // entry0(同一機の実測 2,000ms)が entry1(混合中央値 10,000ms)より軽く見積もられて S を引き受ける
        XCTAssertEqual(buckets[0], FleetSplit.Bucket(entryIndex: 0, scenarioIDs: ["S"], estimatedMs: 2_000))
        XCTAssertEqual(buckets[1], FleetSplit.Bucket(entryIndex: 1, scenarioIDs: [], estimatedMs: 0))
    }

    /// 同一機の実績が無いシナリオは mixed × factor で見積もる(factor は他シナリオの共通観測から)
    func testSpeedFactorAppliesToScenarioWithoutSameMachineHistory() throws {
        // 共通観測: "Common" は mixed 10,000ms・機械 "slow" では 20,000ms → factor(slow) = 2.0
        // "NoHistory" は mixed だけ 5,000ms(slow の実測なし)→ est = 5,000 × 2.0 = 10,000
        let durations = [duration("Common", 10_000, "ios"), duration("NoHistory", 5_000, "ios")]
        let machineDurations = [machineDuration("Common", 20_000, machine: "slow")]
        let context = FleetSplit.MachineContext(
            entryMachines: ["slow"], entryFixedOffsetsMs: [0], machineDurations: machineDurations)

        let buckets = try FleetSplit.partition(
            scenarios: [("NoHistory", nil)], durations: durations,
            entryPlatforms: [["ios"]], unknownDurationMs: 1_000, machineContext: context)

        XCTAssertEqual(buckets, [
            FleetSplit.Bucket(entryIndex: 0, scenarioIDs: ["NoHistory"], estimatedMs: 10_000),
        ])
    }

    /// 固定費が大きいエントリは避けられる。オフセットは台数で割られない
    /// (割ってしまうと台数の多いエントリの固定費が過小評価される)
    func testFixedOffsetAvoidsAssignmentAndIsNotDividedByCapacity() throws {
        // entry0: 固定費 50,000ms・台数3 → 50,000 + 10,000/3 ≈ 53,333
        // entry1: 固定費 0・台数1 → 0 + 10,000/1 = 10,000(軽いのでこちらへ)
        let context = FleetSplit.MachineContext(
            entryMachines: [nil, nil], entryFixedOffsetsMs: [50_000, 0], machineDurations: [])
        let buckets = try FleetSplit.partition(
            scenarios: [("S", nil)], durations: [duration("S", 10_000)],
            entryPlatforms: [["ios"], ["ios"]], unknownDurationMs: 1_000,
            entryCapacities: [3, 1], machineContext: context)

        XCTAssertEqual(buckets[0].scenarioIDs, [])
        XCTAssertEqual(buckets[1].scenarioIDs, ["S"])
    }

    func testMachineContextProducesDeterministicOutput() throws {
        let durations = [duration("A", 5_000), duration("B", 3_000)]
        let machineDurations = [machineDuration("A", 10_000, machine: "M")]
        let context = FleetSplit.MachineContext(
            entryMachines: ["M", nil], entryFixedOffsetsMs: [1_000, 0], machineDurations: machineDurations)
        let scenarios: [(id: String, platform: String?)] = [("A", nil), ("B", nil), ("C", nil)]

        let first = try FleetSplit.partition(
            scenarios: scenarios, durations: durations, entryPlatforms: [["ios"], ["ios"]],
            unknownDurationMs: 1_000, machineContext: context)
        let second = try FleetSplit.partition(
            scenarios: scenarios, durations: durations, entryPlatforms: [["ios"], ["ios"]],
            unknownDurationMs: 1_000, machineContext: context)

        XCTAssertEqual(first, second)
    }
}

// MARK: - speedFactors 単体

extension FleetSplitTests {

    func testSpeedFactorsIsMedianOfCommonScenarioRatios() {
        // 2つの共通観測: 20,000/10,000=2.0 と 8,000/4,000=2.0 → 中央値 2.0
        let durations = [duration("A", 10_000, "ios"), duration("B", 4_000, "ios")]
        let machineDurations = [
            machineDuration("A", 20_000, machine: "M"), machineDuration("B", 8_000, machine: "M"),
        ]
        let factors = FleetSplit.speedFactors(machineDurations: machineDurations, durations: durations)
        XCTAssertEqual(factors, ["M": 2.0])
    }

    func testSpeedFactorsExcludesMachinesWithNoCommonObservation() {
        // "M" の実績シナリオ("B")は durations 側("A"のみ)に対応する記録が無い
        let durations = [duration("A", 10_000, "ios")]
        let machineDurations = [machineDuration("B", 5_000, machine: "M")]
        let factors = FleetSplit.speedFactors(machineDurations: machineDurations, durations: durations)
        XCTAssertTrue(factors.isEmpty, "共通観測が無い machine は係数なし")
    }

    /// 実績ゼロのガード: 単位重み(1.0)と ms の offset を同じ比較に載せない
    /// (FleetSplit.machineContext の宣言)。**旧仕様は context ごと nil に落としていたが、
    /// 現仕様は entryFixedOffsetsMs だけ 0 化した MachineContext を返す**
    /// (無次元の entryFallbackFactors は単位重みと安全に混ざるので保持したまま渡せる)。
    /// ガードなしの偏り(offset が重みを支配する事故)は陽性対照として維持する
    func testOffsetsAreZeroedWhenThereIsNoHistory() throws {
        let context = FleetSplit.MachineContext(
            entryMachines: [nil, "M"], entryFixedOffsetsMs: [0, 2_500], machineDurations: [])
        let dropped = FleetSplit.machineContext(context, ifHistoryExists: [])
        XCTAssertEqual(dropped.entryMachines, [nil, "M"])
        XCTAssertEqual(dropped.entryFixedOffsetsMs, [0, 0], "実績ゼロなら offsets は全 0 化される")

        let kept = FleetSplit.machineContext(context, ifHistoryExists: [duration("A.one", 5_000)])
        XCTAssertEqual(kept.entryMachines, [nil, "M"])
        XCTAssertEqual(kept.entryFixedOffsetsMs, [0, 2_500], "実績があれば offsets はそのまま")

        let scenarios: [(id: String, platform: String?)] = [
            ("A.S0010", nil), ("B.S0010", nil), ("C.S0010", nil), ("D.S0010", nil),
        ]
        let skewed = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["ios"]],
            unknownDurationMs: 1.0, machineContext: context)
        XCTAssertEqual(skewed.map(\.scenarioIDs.count), [4, 0],
                       "ガードを通さない実績ゼロ + ms offset は全シナリオが片側へ寄る(これが守っている事故)")
        let guarded = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["ios"]],
            unknownDurationMs: 1.0,
            machineContext: FleetSplit.machineContext(context, ifHistoryExists: []))
        XCTAssertEqual(guarded.map(\.scenarioIDs.count), [2, 2], "ガードを通せば本数の均等割りが保たれる")
    }
}

// MARK: - entryFallbackFactors(実績が無い機械の事前係数。ハードウェアのコア数比等)

extension FleetSplitTests {

    /// 実績ゼロ + fallback 係数([1.0, 2.0])で、係数の大きい(遅い想定の)エントリへ行く本数が減る
    func testFallbackFactorSendsFewerScenariosToTheSlowerEntry() throws {
        let context = FleetSplit.MachineContext(
            entryMachines: ["fast", "slow"], entryFixedOffsetsMs: [0, 0], machineDurations: [],
            entryFallbackFactors: [1.0, 2.0])
        let scenarios: [(id: String, platform: String?)] = (1...8).map { ("S.\($0)", nil) }
        let guardedContext = FleetSplit.machineContext(context, ifHistoryExists: [])

        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: [["ios"], ["ios"]],
            unknownDurationMs: 1_000, machineContext: guardedContext)

        XCTAssertGreaterThan(buckets[0].scenarioIDs.count, buckets[1].scenarioIDs.count,
                             "\(buckets)")
    }

    /// 実測係数(speedFactors が立つ入力)があるときは fallback より優先される
    func testMeasuredSpeedFactorTakesPriorityOverFallback() throws {
        // "Common" の実測比較から machine "M" の speedFactor = 0.5(速い)が立つ。
        // fallback は 4.0(遅い想定)だが、同一機の速度係数があるシナリオではそちらを使うので
        // "NoHistory"(mixed 10,000ms)の見積りは 10,000 × 0.5 = 5,000 になるはず
        let durations = [duration("Common", 10_000, "ios"), duration("NoHistory", 10_000, "ios")]
        let machineDurations = [machineDuration("Common", 5_000, machine: "M")]
        let context = FleetSplit.MachineContext(
            entryMachines: ["M"], entryFixedOffsetsMs: [0], machineDurations: machineDurations,
            entryFallbackFactors: [4.0])

        let buckets = try FleetSplit.partition(
            scenarios: [("NoHistory", nil)], durations: durations,
            entryPlatforms: [["ios"]], unknownDurationMs: 1_000, machineContext: context)

        XCTAssertEqual(buckets, [
            FleetSplit.Bucket(entryIndex: 0, scenarioIDs: ["NoHistory"], estimatedMs: 5_000),
        ])
    }

    /// fallback 省略(nil)は従来挙動と同一(全員 1.0 = 混合見積りそのまま)
    func testOmittedFallbackFactorsMatchAllOnes() throws {
        let scenarios: [(id: String, platform: String?)] = (1...6).map { ("S.\($0)", nil) }
        let entryPlatforms: [Set<String>] = [["ios"], ["ios"]]

        let omitted = FleetSplit.MachineContext(
            entryMachines: [nil, nil], entryFixedOffsetsMs: [0, 0], machineDurations: [])
        let explicitOnes = FleetSplit.MachineContext(
            entryMachines: [nil, nil], entryFixedOffsetsMs: [0, 0], machineDurations: [],
            entryFallbackFactors: [1.0, 1.0])
        XCTAssertEqual(omitted.entryFallbackFactors, [1.0, 1.0])

        let a = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: entryPlatforms,
            unknownDurationMs: 1_000, machineContext: omitted)
        let b = try FleetSplit.partition(
            scenarios: scenarios, durations: [], entryPlatforms: entryPlatforms,
            unknownDurationMs: 1_000, machineContext: explicitOnes)
        XCTAssertEqual(a, b)
    }
}

// MARK: - platform スコープ(機械別実績が別 platform から来る事故)

extension FleetSplitTests {

    /// **witness**: 機械 M は直近 android でしか回しておらず、同じシナリオの android 実績(30秒)しか
    /// 持たない。ios だけを回すエントリでこれを「同一機の実績」として使うと、実際は 120 秒かかる
    /// ios のシナリオを 30 秒と見積もって M へ積み続ける —— 受け手の 98 本 iOS run で M1Ultra だけが
    /// 最後まで走る極になった形(ファイル冒頭の項)。ios スコープなら混合の ios 実績 120 秒を使う。
    func testMachineHistoryFromAnotherPlatformDoesNotFeedASinglePlatformEntry() throws {
        let durations = [duration("Long.one", 120_000, "ios"), duration("Long.one", 30_000, "android")]
        let machineDurations = [machineDuration("Long.one", 30_000, machine: "M", platform: "android")]
        let context = FleetSplit.MachineContext(
            entryMachines: ["M"], entryFixedOffsetsMs: [0], machineDurations: machineDurations)

        let iosOnly = try FleetSplit.partition(
            scenarios: [("Long.one", nil)], durations: durations,
            entryPlatforms: [["ios"]], unknownDurationMs: 1_000, machineContext: context)
        XCTAssertEqual(iosOnly[0].estimatedMs, 120_000,
                       "ios しか回せないエントリに android の中央値を使ってはいけない")

        // 両方回すエントリでは scope が両 platform = 従来どおり max(安全側)。ここが変わると
        // 既存の --fleet --split の割り当てが黙って動く
        let both = try FleetSplit.partition(
            scenarios: [("Long.one", nil)], durations: durations,
            entryPlatforms: [["ios", "android"]], unknownDurationMs: 1_000, machineContext: context)
        XCTAssertEqual(both[0].estimatedMs, 30_000,
                       "両 platform を回すエントリは同一機の実績をそのまま使う(従来と同一)")
    }

    /// 宣言 platform はエントリの platform 集合より強い(その platform でしか走らないので)
    func testDeclaredPlatformNarrowsTheScopeEvenOnAMixedEntry() throws {
        let durations = [duration("S.one", 90_000, "ios"), duration("S.one", 20_000, "android")]
        let machineDurations = [
            machineDuration("S.one", 20_000, machine: "M", platform: "android"),
            machineDuration("S.one", 90_000, machine: "M", platform: "ios"),
        ]
        let context = FleetSplit.MachineContext(
            entryMachines: ["M"], entryFixedOffsetsMs: [0], machineDurations: machineDurations)
        let buckets = try FleetSplit.partition(
            scenarios: [("S.one", "android")], durations: durations,
            entryPlatforms: [["ios", "android"]], unknownDurationMs: 1_000, machineContext: context)
        XCTAssertEqual(buckets[0].estimatedMs, 20_000)
    }

    /// scope 内に実績が1件も無いときは全 platform へ退化する(その platform を1度も回していない
    /// プロジェクトで実績を捨てない)。**退化してよいのは混合側だけ** —— 同一機側で退化すると
    /// 上の witness が復活する
    func testMixedEstimateFallsBackAcrossPlatformsWhenTheScopeHasNoHistory() throws {
        let durations = [duration("S.one", 45_000, "android")]
        let buckets = try FleetSplit.partition(
            scenarios: [("S.one", nil)], durations: durations,
            entryPlatforms: [["ios"]], unknownDurationMs: 1_000)
        XCTAssertEqual(buckets[0].estimatedMs, 45_000,
                       "ios の実績が無ければ android の実績を使う(unknown へ落とさない)")
    }

    /// 投入順(降順ソート)も scope を通す。ios だけを回す fleet で、android でだけ長いシナリオが
    /// 先頭に来ると LPT の狙いが外れる
    func testOrderingUsesTheScopedEstimate() throws {
        let durations = [
            duration("A.short", 10_000, "ios"), duration("A.short", 99_000, "android"),
            duration("B.long", 50_000, "ios"), duration("B.long", 1_000, "android"),
        ]
        let buckets = try FleetSplit.partition(
            scenarios: [("A.short", nil), ("B.long", nil)], durations: durations,
            entryPlatforms: [["ios"], ["ios"]], unknownDurationMs: 1_000)
        XCTAssertEqual(buckets[0].scenarioIDs, ["B.long"], "ios の実績で長い方が先に配られる")
        XCTAssertEqual(buckets[1].scenarioIDs, ["A.short"])
    }
}

// MARK: - EstimateBasis(見積りの根拠。ディスパッチのログ1行)

extension FleetSplitTests {

    func testPlanCountsWhereEachEstimateCameFrom() throws {
        // "Own" は M の ios 実績あり / "Scaled" は混合実績のみ / "Unknown" は実績なし。
        // M の係数は "Own" の共通観測から 6,000/12,000 = 0.5
        let durations = [duration("Own", 12_000), duration("Scaled", 20_000)]
        let machineDurations = [machineDuration("Own", 6_000, machine: "M")]
        let context = FleetSplit.MachineContext(
            entryMachines: ["M"], entryFixedOffsetsMs: [0], machineDurations: machineDurations)

        let plan = try FleetSplit.plan(
            scenarios: [("Own", nil), ("Scaled", nil), ("Unknown", nil)], durations: durations,
            entryPlatforms: [["ios"]], unknownDurationMs: 1_000, machineContext: context)

        XCTAssertEqual(plan.basis, [FleetSplit.EstimateBasis(
            entryIndex: 0, machine: "M", ownHistory: 1, scaled: 1, unknown: 1,
            coefficient: 0.5, coefficientSource: .measured)])
        XCTAssertEqual(plan.basis[0].summary, "1 from M history, 2 scaled x0.50 (measured)")
        // 見積り: 6,000(同一機) + 20,000×0.5 + 1,000×0.5
        XCTAssertEqual(plan.buckets[0].estimatedMs, 16_500)
    }

    /// 実測比が無い機械は事前係数(コア数比)を使い、由来も hardware と名乗る
    func testBasisNamesTheHardwareFallbackWhenThereIsNoMeasuredRatio() throws {
        let context = FleetSplit.MachineContext(
            entryMachines: ["M"], entryFixedOffsetsMs: [0], machineDurations: [],
            entryFallbackFactors: [2.5])
        let plan = try FleetSplit.plan(
            scenarios: [("S.one", nil)], durations: [duration("S.one", 4_000)],
            entryPlatforms: [["ios"]], unknownDurationMs: 1_000, machineContext: context)
        XCTAssertEqual(plan.basis[0].coefficientSource, .hardware)
        XCTAssertEqual(plan.basis[0].coefficient, 2.5)
        XCTAssertEqual(plan.basis[0].summary, "1 scaled x2.50 (hardware)")
    }

    /// machineContext 無し = 補正なし。summary も係数を主張しない
    func testBasisSaysNoneWithoutAMachineContext() throws {
        let plan = try FleetSplit.plan(
            scenarios: [("S.one", nil)], durations: [duration("S.one", 4_000)],
            entryPlatforms: [["ios"]], unknownDurationMs: 1_000)
        XCTAssertEqual(plan.basis[0].coefficientSource, .none)
        XCTAssertEqual(plan.basis[0].summary, "1 scaled x1.00 (none)")
        XCTAssertNil(plan.basis[0].machine)
    }

    /// partition は plan の buckets そのもの(2つの割り当て実装を持たない)
    func testPartitionReturnsThePlansBuckets() throws {
        let durations = [duration("A", 5_000), duration("B", 3_000)]
        let scenarios: [(id: String, platform: String?)] = [("A", nil), ("B", nil), ("C", nil)]
        let platforms: [Set<String>] = [["ios"], ["ios"]]
        let buckets = try FleetSplit.partition(
            scenarios: scenarios, durations: durations, entryPlatforms: platforms,
            unknownDurationMs: 1_000)
        let plan = try FleetSplit.plan(
            scenarios: scenarios, durations: durations, entryPlatforms: platforms,
            unknownDurationMs: 1_000)
        XCTAssertEqual(buckets, plan.buckets)
    }
}

// MARK: - speedFactors の platform 対応

extension FleetSplitTests {

    /// **分子と分母は同じ platform で取る**。機械 M の android 実績を全 platform max の混合
    /// (= ios の 100,000)で割ると 0.2 になり、機械が5倍速いという誤った係数が立つ
    func testSpeedFactorsMatchesPlatformsBetweenNumeratorAndDenominator() {
        let durations = [
            duration("S.one", 100_000, "ios"), duration("S.one", 20_000, "android"),
        ]
        let machineDurations = [machineDuration("S.one", 20_000, machine: "M", platform: "android")]
        let factors = FleetSplit.speedFactors(machineDurations: machineDurations, durations: durations)
        XCTAssertEqual(factors, ["M": 1.0], "android 同士の比 = 1.0(platform 差を係数にしない)")
    }

    /// scope 内に比があればそれだけを使う(今回の run が回す platform の速度差を優先)
    func testSpeedFactorsPrefersRatiosInsideTheScope() {
        let durations = [
            duration("A", 10_000, "ios"), duration("B", 10_000, "android"),
        ]
        let machineDurations = [
            machineDuration("A", 20_000, machine: "M", platform: "ios"),
            machineDuration("B", 5_000, machine: "M", platform: "android"),
        ]
        XCTAssertEqual(FleetSplit.speedFactors(machineDurations: machineDurations,
                                               durations: durations, scope: ["ios"]), ["M": 2.0])
        XCTAssertEqual(FleetSplit.speedFactors(machineDurations: machineDurations,
                                               durations: durations, scope: ["android"]), ["M": 0.5])
    }

    /// scope 内に比が1本も無い機械は全 platform の比へ退化する(係数を捨てない)
    func testSpeedFactorsFallsBackToEveryPlatformWhenTheScopeIsEmptyForThatMachine() {
        let durations = [duration("B", 10_000, "android")]
        let machineDurations = [machineDuration("B", 5_000, machine: "M", platform: "android")]
        XCTAssertEqual(FleetSplit.speedFactors(machineDurations: machineDurations,
                                               durations: durations, scope: ["ios"]), ["M": 0.5])
    }
}
