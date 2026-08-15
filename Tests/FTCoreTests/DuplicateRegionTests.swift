// 横スクロールの残骸(同じ領域が木に2回出る形)の共有判定(2026-08-15 に FTCore へ降ろした)。
//
// 守るのは3つ:
//   1. **MCP と DSL が同じ答えを出す** —— 実アプリの固定コーパスで発火する画面を等号で固定する
//   2. **誤検知0** —— witness 以外の画面では、どの要素を掴んでも DSL 側の注記が付かない。
//      ここが破れると全シナリオに注記が付いて意味を失う
//   3. **安価な門(`riskFor`)が答えを変えない** —— 門は DP を回さないための必要条件でしかない
//      ので、門を通した結果と `find` の結果が食い違ってはいけない

import XCTest
@testable import FTCore

final class DuplicateRegionTests: XCTestCase {

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
    }

    private func corpus() throws -> [(name: String, snapshot: SnapshotResponse)] {
        try FileManager.default.contentsOfDirectory(atPath: Self.fixtureDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { file in
                let url = Self.fixtureDirectory.appendingPathComponent(file)
                return (String(file.dropLast(".json".count)),
                        try JSONDecoder().decode(SnapshotResponse.self,
                                                 from: try Data(contentsOf: url)))
            }
    }

    /// **等号で固定**。`NoteCoverageTests` の duplicateRegionNote の baseline と一致していること
    private let witness = "ios-browser_jma_hscroll"

    func testFindFiresOnExactlyTheWitnessScreen() throws {
        let fired = Set(try corpus().filter { DuplicateRegion.find(in: $0.snapshot.elements) != nil }
            .map(\.name))
        XCTAssertEqual(fired, [witness],
                       "複製の検知が発火する画面が変わった。増分を1件ずつ検分すること")
    }

    /// **誤検知0**: witness 以外はどの要素を掴んでも DSL の注記が付かない
    func testNoOtherScreenPutsAnyElementAtRisk() throws {
        for (name, snapshot) in try corpus() where name != witness {
            let flagged = snapshot.elements.filter {
                DuplicateRegion.riskFor($0, in: snapshot.elements) != nil
            }
            XCTAssertTrue(flagged.isEmpty,
                          "\(name) で \(flagged.count) 件が複製扱いされた: \(flagged.map(\.ref))")
        }
    }

    /// witness では**複製区間の中の要素だけ**が危険と出る(門が黙り過ぎていないことの確認)
    func testTheWitnessFlagsExactlyTheDuplicatedRegion() throws {
        let snapshot = try XCTUnwrap(try corpus().first { $0.name == witness }?.snapshot)
        let match = try XCTUnwrap(DuplicateRegion.find(in: snapshot.elements))
        let flagged = Set(snapshot.elements.indices.filter {
            DuplicateRegion.riskFor(snapshot.elements[$0], in: snapshot.elements) != nil
        })
        let covered = Set(snapshot.elements.indices.filter { match.covers(index: $0) })
        XCTAssertFalse(flagged.isEmpty, "witness で1件も危険と出ないのは門が広すぎる")
        XCTAssertTrue(flagged.isSubset(of: covered),
                      "区間の外の要素まで危険と出た: \(flagged.subtracting(covered))")
    }

    /// **門は答えを変えない**: 複製が無い木では、どの要素を渡しても nil。
    /// (門が「相方が居る」だけで通してしまうと、正当なページ構造で発火する)
    func testTheCheapGateNeverContradictsFind() throws {
        for (name, snapshot) in try corpus() {
            let hasRegion = DuplicateRegion.find(in: snapshot.elements) != nil
            guard !hasRegion else { continue }
            for element in snapshot.elements {
                XCTAssertNil(DuplicateRegion.riskFor(element, in: snapshot.elements),
                             "\(name): 複製が無いのに門が通した(ref \(element.ref))")
            }
        }
    }

    // MARK: - 合成木で制約を撃つ

    /// 同じ行に x をずらして2回並ぶ、6要素の変化のある並び
    private func duplicatedRow(secondCopyY: Double = 100) -> [ElementInfo] {
        let labels = ["日付", "天気", "気温", "降水", "風", "波"]
        func copy(startRef: Int, x0: Double, y: Double) -> [ElementInfo] {
            labels.enumerated().map { index, label in
                ElementInfo(ref: startRef + index, type: "staticText", identifier: nil,
                            label: label, value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: x0 + Double(index) * 50, y: y,
                                          width: 40, height: 20), depth: 3)
            }
        }
        return copy(startRef: 1, x0: 0, y: 100) + copy(startRef: 100, x0: 200, y: secondCopyY)
    }

    func testASameRowShiftedCopyIsDetected() {
        let match = DuplicateRegion.find(in: duplicatedRow())
        XCTAssertEqual(match?.length, 6)
        XCTAssertEqual(match?.firstRef, 1)
        XCTAssertEqual(match?.secondRef, 100)
    }

    /// **y が違う一致は複製ではない**(2026-08-13 に実装して撤回した誤検知そのもの ——
    /// 別々の2つの表が同じ日付見出し行を共有している正当なページ構造)
    func testACopyOnADifferentRowIsNotADuplicate() {
        XCTAssertNil(DuplicateRegion.find(in: duplicatedRow(secondCopyY: 400)),
                     "別の行に出る同名の並びは正当なページ構造")
    }

    /// **一様な並びは複製ではない**: 同じキーのセルが 12 個並ぶだけで発火してはいけない
    /// (重なり禁止だけでは 6+6 に割れて通ってしまう)
    func testAUniformRunIsNotADuplicate() {
        let cells = (0..<12).map { index in
            ElementInfo(ref: index + 1, type: "cell", identifier: nil, label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: Double(index) * 50, y: 100, width: 40, height: 20),
                        depth: 3)
        }
        XCTAssertNil(DuplicateRegion.find(in: cells))
    }

    /// 下限未満は黙る(5要素の複製)
    func testARunShorterThanTheMinimumIsIgnored() {
        let short = Array(duplicatedRow().prefix(5)) + Array(duplicatedRow().suffix(6).prefix(5))
        XCTAssertNil(DuplicateRegion.find(in: short))
    }
}

/// 与えた木をそのまま返し、tap を記録するドライバ
private final class DuplicateRegionDriver: AppDriver {
    private let response: SnapshotResponse
    private(set) var tapped: [Int] = []

    init(_ response: SnapshotResponse) { self.response = response }

    func snapshot() async throws -> SnapshotResponse { response }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws { tapped.append(ref) }
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// DSL のタップが注記を運ぶこと。**操作は止めない**(どちらのコピーが生きているかは木から
/// 決められないので、撃たずに止めると正しい操作まで殺す)
final class DuplicateRegionStepNoteTests: XCTestCase {

    private func tree(secondCopyY: Double) -> SnapshotResponse {
        let labels = ["日付", "天気", "気温", "降水", "風", "波"]
        func copy(startRef: Int, x0: Double, y: Double) -> [ElementInfo] {
            labels.enumerated().map { index, label in
                ElementInfo(ref: startRef + index, type: "staticText", identifier: nil,
                            label: label, value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: x0 + Double(index) * 50, y: y,
                                          width: 40, height: 20), depth: 3)
            }
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 600, height: 800),
                                elements: copy(startRef: 1, x0: 0, y: 100)
                                    + copy(startRef: 100, x0: 200, y: secondCopyY),
                                truncatedCount: 0)
    }

    private func tapStep() -> FlowStep {
        FlowStep(action: "tap", locator: FlowLocator(label: "気温"), timeout: 0,
                 occlusionGuard: false)
    }

    func testTappingInsideADuplicatedRegionCarriesTheNote() async {
        let driver = DuplicateRegionDriver(tree(secondCopyY: 100))
        let outcome = await StepExecutor(driver: driver).execute(tapStep())
        XCTAssertTrue(outcome.notes.contains(.staleDuplicateRegion),
                      "複製区間のタップが黙った: \(outcome.notes) / \(outcome.status)")
        XCTAssertFalse(driver.tapped.isEmpty, "注記であって拒否ではない(撃つこと)")
    }

    /// **陰性対照**: 2つ目のコピーが別の行にある = 正当なページ構造では付かない
    func testAValidPageStructureCarriesNoNote() async {
        let driver = DuplicateRegionDriver(tree(secondCopyY: 400))
        let outcome = await StepExecutor(driver: driver).execute(tapStep())
        XCTAssertFalse(outcome.notes.contains(.staleDuplicateRegion), "\(outcome.notes)")
        XCTAssertFalse(driver.tapped.isEmpty)
    }
}
