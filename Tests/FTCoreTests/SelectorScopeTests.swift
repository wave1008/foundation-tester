import XCTest
@testable import FTCore

/// 階層スコープ(`#list >> .Cell[2]`)と方向アンカー(`:right(...)` 等)の解決規則。
/// スナップショットは pre-order + depth という 3 ブリッジ共通の規約を前提にする。
final class SelectorScopeTests: XCTestCase {

    private func node(_ ref: Int, _ type: String, depth: Int, id: String? = nil,
                      label: String? = nil, enabled: Bool = true,
                      x: Double = 0, y: Double = 0,
                      width: Double = 10, height: Double = 10) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: x, y: y, width: width, height: height), depth: depth)
    }

    /// 画面: [0] ルート
    ///        ├ [1] #header
    ///        │   └ [2] Cell "先頭"
    ///        └ [3] #list
    ///            ├ [4] Cell "りんご"
    ///            ├ [5] Cell "みかん"
    ///            └ [6] Cell "ぶどう"
    private var tree: [ElementInfo] {
        [
            node(0, "other", depth: 0),
            node(1, "other", depth: 1, id: "header"),
            node(2, "cell", depth: 2, label: "先頭"),
            node(3, "other", depth: 1, id: "list"),
            node(4, "cell", depth: 2, label: "りんご"),
            node(5, "cell", depth: 2, label: "みかん"),
            node(6, "cell", depth: 2, label: "ぶどう"),
        ]
    }

    func testDescendantsUsesPreOrderAndDepth() {
        let elements = tree
        let list = elements[3]
        XCTAssertEqual(StepExecutor.descendants(of: list, in: elements).map(\.ref), [4, 5, 6])
        let header = elements[1]
        XCTAssertEqual(StepExecutor.descendants(of: header, in: elements).map(\.ref), [2])
        // 葉には子孫がいない
        XCTAssertTrue(StepExecutor.descendants(of: elements[6], in: elements).isEmpty)
    }

    func testScopeMakesOrdinalRelativeToContainer() {
        // スコープ無しの .Cell[2] は画面全体の 2 番目(= ヘッダ配下を含むので "りんご")
        let global = FlowLocator(type: "cell", index: 1)
        XCTAssertEqual(StepExecutor.matchDetailed(global, elements: tree)?.0.label, "りんご")
        // スコープ付きは容器の中で数えるので "みかん"
        let scoped = FlowLocator(type: "cell", index: 1, scope: [FlowLocator(id: "list")])
        XCTAssertEqual(StepExecutor.matchDetailed(scoped, elements: tree)?.0.label, "みかん")
    }

    func testScopeExcludesElementsOutsideContainer() {
        let scoped = FlowLocator(label: "先頭", scope: [FlowLocator(id: "list")])
        XCTAssertNil(StepExecutor.matchDetailed(scoped, elements: tree))
        let inHeader = FlowLocator(label: "先頭", scope: [FlowLocator(id: "header")])
        XCTAssertEqual(inHeader.summary, "id=header >> label=先頭")
        XCTAssertEqual(StepExecutor.matchDetailed(inHeader, elements: tree)?.0.ref, 2)
    }

    func testUnresolvableScopeYieldsNoMatch() {
        let scoped = FlowLocator(type: "cell", scope: [FlowLocator(id: "存在しない")])
        XCTAssertNil(StepExecutor.matchDetailed(scoped, elements: tree))
    }

    /// 設定画面のような「ラベル(左)+ 無ラベルのスイッチ(右)」が縦に 2 行。
    /// 行の高さは 40、行1 は y=0..40、行2 は y=100..140。
    private var rows: [ElementInfo] {
        [
            node(1, "staticText", depth: 1, label: "通知", x: 0, y: 0, width: 100, height: 40),
            node(2, "switch", depth: 1, id: "sw_notify", x: 300, y: 0, width: 40, height: 40),
            node(3, "staticText", depth: 1, label: "位置情報", x: 0, y: 100, width: 100, height: 40),
            node(4, "switch", depth: 1, id: "sw_location", x: 300, y: 100, width: 40, height: 40),
        ]
    }

    func testDirectionPicksCandidateInAnchorBand() {
        let notify = FlowLocator(type: "switch", anchor: [FlowLocator(label: "通知")], direction: .right)
        XCTAssertEqual(StepExecutor.matchDetailed(notify, elements: rows)?.0.identifier, "sw_notify")
        let location = FlowLocator(type: "switch", anchor: [FlowLocator(label: "位置情報")],
                                   direction: .right)
        XCTAssertEqual(StepExecutor.matchDetailed(location, elements: rows)?.0.identifier,
                       "sw_location")
    }

    /// 方向が合わない/帯から外れる候補しか無ければ **解決失敗**(最も近いものを返さない)。
    /// これが `:near` を廃した理由そのもの — レイアウト変更時に黙って別要素を掴ませない
    func testDirectionFailsInsteadOfPickingNearest() {
        let toLeft = FlowLocator(type: "switch", anchor: [FlowLocator(label: "通知")], direction: .left)
        XCTAssertNil(StepExecutor.matchDetailed(toLeft, elements: rows))
        // 帯の外(別の行)にしか候補が無い場合も同様
        let outOfBand = [rows[0], rows[3]]
        let right = FlowLocator(type: "switch", anchor: [FlowLocator(label: "通知")], direction: .right)
        XCTAssertNil(StepExecutor.matchDetailed(right, elements: outOfBand))
    }

    func testDirectionAboveAndBelowUseHorizontalBand() {
        let elements = [
            node(1, "staticText", depth: 1, label: "見出し", x: 0, y: 0, width: 100, height: 20),
            node(2, "button", depth: 1, id: "under", x: 10, y: 40, width: 60, height: 20),
            node(3, "button", depth: 1, id: "far_right", x: 300, y: 40, width: 60, height: 20),
        ]
        let below = FlowLocator(type: "button", anchor: [FlowLocator(label: "見出し")],
                                direction: .below)
        XCTAssertEqual(StepExecutor.matchDetailed(below, elements: elements)?.0.identifier, "under")
        let above = FlowLocator(type: "button", anchor: [FlowLocator(label: "見出し")],
                                direction: .above)
        XCTAssertNil(StepExecutor.matchDetailed(above, elements: elements))
    }

    func testDirectionPicksNearestThenTreeOrder() {
        let elements = [
            node(1, "staticText", depth: 1, label: "数量", x: 0, y: 0, width: 40, height: 40),
            node(2, "button", depth: 1, id: "far", x: 200, y: 0, width: 40, height: 40),
            node(3, "button", depth: 1, id: "near", x: 100, y: 0, width: 40, height: 40),
            // near と中心 x が同じ = 同距離。ツリー順が先の near が残る
            node(4, "button", depth: 1, id: "tie", x: 100, y: 10, width: 40, height: 20),
        ]
        let locator = FlowLocator(type: "button", anchor: [FlowLocator(label: "数量")],
                                  direction: .right)
        XCTAssertEqual(StepExecutor.matchDetailed(locator, elements: elements)?.0.identifier, "near")
    }

    func testDirectionExcludesAnchorItself() {
        let elements = [
            node(1, "staticText", depth: 1, label: "合計", x: 0, y: 0, width: 40, height: 40),
            node(2, "staticText", depth: 1, label: "合計", x: 100, y: 0, width: 40, height: 40),
        ]
        // 同一ラベルが並ぶ場合でも、アンカーとして解決した要素自身は候補にしない
        let locator = FlowLocator(label: "合計", anchor: [FlowLocator(label: "合計")], direction: .right)
        XCTAssertEqual(StepExecutor.matchDetailed(locator, elements: elements)?.0.ref, 2)
    }

    func testDirectionWithUnresolvableAnchorFails() {
        let locator = FlowLocator(type: "cell", anchor: [FlowLocator(id: "居ない")], direction: .right)
        XCTAssertNil(StepExecutor.matchDetailed(locator, elements: tree))
    }

    func testCandidatesCountsWithinScope() {
        let all = StepExecutor.candidates(FlowLocator(type: "cell"), elements: tree)
        XCTAssertEqual(all?.matches.count, 4)
        let scoped = StepExecutor.candidates(
            FlowLocator(type: "cell", scope: [FlowLocator(id: "list")]), elements: tree)
        XCTAssertEqual(scoped?.matches.count, 3)
        // 条件が空(id/label/type すべて nil)のロケータは「数えられない」= nil
        XCTAssertNil(StepExecutor.candidates(FlowLocator(), elements: tree))
    }

    func testLabelCandidatesPreferExactOverSubstring() {
        let elements = [
            node(1, "staticText", depth: 1, label: "通知を許可"),
            node(2, "staticText", depth: 1, label: "許可"),
        ]
        let result = StepExecutor.candidates(FlowLocator(label: "許可"), elements: elements)
        XCTAssertEqual(result?.quality, .exact)
        XCTAssertEqual(result?.matches.map(\.ref), [2])
    }

    func testScopedTypeLocatorIsNotWeakForAssert() {
        XCTAssertTrue(FlowLocator(type: "cell", index: 1).isWeakForAssert)
        XCTAssertFalse(FlowLocator(id: "a").isWeakForAssert)
        XCTAssertFalse(FlowLocator(label: "a").isWeakForAssert)
        // スコープ付き・方向アンカー付きは錨があるのでアサーションのフォールバックから除外しない
        XCTAssertFalse(FlowLocator(type: "cell", index: 1,
                                   scope: [FlowLocator(id: "list")]).isWeakForAssert)
        XCTAssertFalse(FlowLocator(type: "cell", anchor: [FlowLocator(label: "合計")],
                                   direction: .right).isWeakForAssert)
    }
}
