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
import FTTestSupport

final class DuplicateRegionTests: XCTestCase {

    private func corpus() throws -> [(name: String, snapshot: SnapshotResponse)] {
        try RealAppSnapshotCorpus.all()
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

    /// **同じ場所に重なったコピーは別の判定の担当**(`OcclusionGeometry.stackedRefs`)。
    /// x がずれていない = 横スクロールの残骸ではないので、ここでは黙る。
    /// この形が無いと x 制約を外す変異を1つも殺せない(2026-08-15 の変異チェックで生き残った)
    func testACopyStackedAtTheSameXIsNotADuplicate() {
        let labels = ["日付", "天気", "気温", "降水", "風", "波"]
        func copy(startRef: Int) -> [ElementInfo] {
            labels.enumerated().map { index, label in
                ElementInfo(ref: startRef + index, type: "staticText", identifier: nil,
                            label: label, value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: Double(index) * 50, y: 100, width: 40, height: 20),
                            depth: 3)
            }
        }
        XCTAssertNil(DuplicateRegion.find(in: copy(startRef: 1) + copy(startRef: 100)),
                     "同一 frame に重なったコピーは stacked の担当で、横スクロール残骸ではない")
    }

    /// **周期的な並びを「2回出ている」と読まない**: A,B,A,B… は自分自身の2要素ずれと
    /// 一致し続けるので、重なり禁止が無いと長い run が成立する。`spansTwoKinds` は
    /// A≠B なので通ってしまい、**重なり禁止だけがこの形を止めている**
    /// (2026-08-15 の変異チェックで生き残った形)
    func testAPeriodicRunDoesNotMatchItself() {
        let periodic = (0..<10).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: nil,
                        label: index.isMultiple(of: 2) ? "A" : "B", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: Double(index) * 50, y: 100, width: 40, height: 20),
                        depth: 3)
        }
        XCTAssertNil(DuplicateRegion.find(in: periodic),
                     "周期的な1行が自分自身と一致して複製扱いされた")
    }

    /// 上のテストは10要素(重なり禁止が偶然効くだけ = `j - i >= length` の算術で n<12 は
    /// そもそも届かない)。12要素で period=2 は j-i=6=length でちょうど重なり禁止を素通りする
    /// ので、周期性そのものを見るガードが要る(この形が周期ガードを直接撃つ)
    func testAPeriodicRunOfTwelveDoesNotMatchItself() {
        let periodic = (0..<12).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: nil,
                        label: index.isMultiple(of: 2) ? "A" : "B", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: Double(index) * 50, y: 100, width: 40, height: 20),
                        depth: 3)
        }
        XCTAssertNil(DuplicateRegion.find(in: periodic),
                     "周期2の12要素が自分自身と一致して複製扱いされた")
    }

    /// 14要素でも同じ(要素数を変えても周期ガードが効くことの確認)
    func testAPeriodicRunOfFourteenDoesNotMatchItself() {
        let periodic = (0..<14).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: nil,
                        label: index.isMultiple(of: 2) ? "A" : "B", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: Double(index) * 50, y: 100, width: 40, height: 20),
                        depth: 3)
        }
        XCTAssertNil(DuplicateRegion.find(in: periodic),
                     "周期2の14要素が自分自身と一致して複製扱いされた")
    }

    /// 周期2と同じ理由で period=3(A,B,C の繰り返し)も自分自身と一致してはいけない
    func testAPeriodicRunOfThreeDoesNotMatchItself() {
        let letters = ["A", "B", "C"]
        let periodic = (0..<12).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: nil,
                        label: letters[index % 3], value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: Double(index) * 50, y: 100, width: 40, height: 20),
                        depth: 3)
        }
        XCTAssertNil(DuplicateRegion.find(in: periodic),
                     "周期3の12要素が自分自身と一致して複製扱いされた")
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

    // MARK: - ゲート強化: 窓述語を直接撃つ

    /// ラベル無し同型要素が並ぶだけの行(写真グリッド・アイコン列・ページドット相当)。
    /// 全要素が互いの「相方」になるので、単純な「相方が1つ居るか」の門は毎回通ってしまう
    private func unlabeledIconRow(count: Int = 12) -> [ElementInfo] {
        (0..<count).map { index in
            ElementInfo(ref: index + 1, type: "cell", identifier: nil, label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: Double(index) * 50, y: 100, width: 40, height: 20),
                        depth: 3)
        }
    }

    /// 6要素中2つだけが実際の双子(index 0 と 3)で、残り4つ(1,2,4,5)は相方を持たない。
    /// n=minimumRun なので窓は array 全体の1つしか無く、①(窓内全要素が双子を持つ)で落ちる
    private func isolatedTwinPairAmongSingles() -> [ElementInfo] {
        var elements = (0..<6).map { index in
            ElementInfo(ref: index + 1, type: "staticText", identifier: nil,
                        label: "P\(index)", value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: Double(index) * 50, y: 100, width: 40, height: 20),
                        depth: 3)
        }
        elements[0] = ElementInfo(ref: 1, type: "staticText", identifier: nil, label: "X",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 100, width: 40, height: 20), depth: 3)
        elements[3] = ElementInfo(ref: 4, type: "staticText", identifier: nil, label: "X",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 150, y: 100, width: 40, height: 20), depth: 3)
        return elements
    }

    func testQualifyingWindowFiresInsideAGenuineDuplicatedRegion() {
        XCTAssertTrue(DuplicateRegion.hasQualifyingWindow(around: 0, in: duplicatedRow()),
                     "witness 形の複製領域の中で窓が作れなかった")
    }

    func testQualifyingWindowDoesNotFireOnAUniformUnlabeledRow() {
        let row = unlabeledIconRow()
        XCTAssertFalse(DuplicateRegion.hasQualifyingWindow(around: 5, in: row),
                       "1種類のキーしか無い行なのに窓が成立した(spansTwoKinds 相当が働いていない)")
    }

    func testQualifyingWindowDoesNotFireOnAnIsolatedTwinPair() {
        let elements = isolatedTwinPairAmongSingles()
        XCTAssertFalse(DuplicateRegion.hasQualifyingWindow(around: 0, in: elements),
                       "相方の無い要素が混ざる窓が成立した(①が働いていない)")
    }

    /// **ゲート強化の効き目**: 一様なラベル無し行の要素は、強化後の門で `findAll` の DP を
    /// 呼ぶ前に落ちる(門を強化する前から結果は nil だったが、`find` まで回してからの nil だった)
    func testRiskForIsNilOnAUniformUnlabeledRow() {
        let row = unlabeledIconRow()
        XCTAssertNil(DuplicateRegion.riskFor(row[5], in: row))
    }

    // MARK: - 2領域(指摘2): 最長一致だけでなく全件を拾う

    /// 要素ごとに一意なラベルを持つ複製領域(全区間で spansTwoKinds を満たす・非周期)。
    /// x を大きくずらして2回並べる。`prefix` で複数領域のラベル・ref を重複させない
    private func distinctRegionPair(prefix: String, length: Int, startRef: Int, secondStartRef: Int,
                                    y: Double) -> [ElementInfo] {
        func copy(startRefValue: Int, xOrigin: Double) -> [ElementInfo] {
            (0..<length).map { index in
                ElementInfo(ref: startRefValue + index, type: "staticText", identifier: nil,
                            label: "\(prefix)\(index)", value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: xOrigin + Double(index) * 50, y: y,
                                          width: 40, height: 20), depth: 3)
            }
        }
        return copy(startRefValue: startRef, xOrigin: 0) + copy(startRefValue: secondStartRef, xOrigin: 600)
    }

    func testFindAllCatchesBothARegionOfTenAndARegionOfSeven() throws {
        let regionA = distinctRegionPair(prefix: "A", length: 10, startRef: 1, secondStartRef: 100, y: 100)
        let regionB = distinctRegionPair(prefix: "B", length: 7, startRef: 200, secondStartRef: 300, y: 300)
        let tree = regionA + regionB

        let matches = DuplicateRegion.findAll(in: tree)
        XCTAssertEqual(matches.count, 2, "2領域あるのに \(matches.count) 件しか見つからなかった")

        let byLength = Dictionary(grouping: matches, by: \.length)
        let ten = try XCTUnwrap(byLength[10]?.first)
        let seven = try XCTUnwrap(byLength[7]?.first)
        XCTAssertEqual(ten.firstIndex, 0)
        XCTAssertEqual(ten.secondIndex, 10)
        XCTAssertEqual(ten.firstRef, 1)
        XCTAssertEqual(ten.secondRef, 100)
        // 元配列(regionA 20要素の後ろ)基準の添字であること —— セグメント相対添字のままだと 0/7 になる
        XCTAssertEqual(seven.firstIndex, 20)
        XCTAssertEqual(seven.secondIndex, 27)
        XCTAssertEqual(seven.firstRef, 200)
        XCTAssertEqual(seven.secondRef, 300)
    }

    /// `find` は最長(長さ10)しか返さないので、短い方(長さ7)の要素は `find` ベースの旧実装だと
    /// 見逃す。`riskFor` が `findAll` を使うようになったので両方とも非 nil になること
    func testRiskForFlagsBothTheLongAndTheShortDuplicatedRegion() {
        let regionA = distinctRegionPair(prefix: "A", length: 10, startRef: 1, secondStartRef: 100, y: 100)
        let regionB = distinctRegionPair(prefix: "B", length: 7, startRef: 200, secondStartRef: 300, y: 300)
        let tree = regionA + regionB

        XCTAssertNotNil(DuplicateRegion.riskFor(tree[0], in: tree), "長い方(A)の要素が見逃された")
        XCTAssertNotNil(DuplicateRegion.riskFor(tree[20], in: tree), "短い方(B)の要素が見逃された")
    }

    // MARK: - コーパス不変条件: riskFor と findAll は同じ答えを出す

    /// **等号で固定**: `riskFor` が非 nil を返す要素は、必ず `findAll` のどれかの Match が覆う
    /// (門の健全性の機械固定。全画面×全要素で照合する)
    func testRiskForAgreesWithFindAllAcrossTheCorpus() throws {
        for (name, snapshot) in try corpus() {
            let matches = DuplicateRegion.findAll(in: snapshot.elements)
            for (index, element) in snapshot.elements.enumerated() {
                let flagged = DuplicateRegion.riskFor(element, in: snapshot.elements) != nil
                let covered = matches.contains { $0.covers(index: index) }
                XCTAssertEqual(flagged, covered,
                               "\(name) ref \(element.ref): riskFor=\(flagged) / findAll の被覆=\(covered)")
            }
        }
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
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(tapStep())
        XCTAssertTrue(outcome.notes.contains(.staleDuplicateRegion),
                      "複製区間のタップが黙った: \(outcome.notes) / \(outcome.status)")
        XCTAssertFalse(driver.tapped.isEmpty, "注記であって拒否ではない(撃つこと)")
    }

    /// **doubleTap も指で触る操作**なので同じ注記が要る(この経路は tap と同じ advisory を
    /// 載せる規律が既にあり、片方だけ黙ると判断が食い違う)
    func testDoubleTapCarriesTheSameNote() async {
        let driver = DuplicateRegionDriver(tree(secondCopyY: 100))
        let step = FlowStep(action: "doubleTap", locator: FlowLocator(label: "気温"), timeout: 0,
                            occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(step)
        XCTAssertTrue(outcome.notes.contains(.staleDuplicateRegion),
                      "doubleTap が黙った: \(outcome.notes) / \(outcome.status)")
    }

    /// **陰性対照**: 2つ目のコピーが別の行にある = 正当なページ構造では付かない
    func testAValidPageStructureCarriesNoNote() async {
        let driver = DuplicateRegionDriver(tree(secondCopyY: 400))
        let outcome = await StepExecutor(driver: driver, isAndroid: false).execute(tapStep())
        XCTAssertFalse(outcome.notes.contains(.staleDuplicateRegion), "\(outcome.notes)")
        XCTAssertFalse(driver.tapped.isEmpty)
    }
}
