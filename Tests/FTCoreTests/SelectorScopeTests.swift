import XCTest
@testable import FTCore

/// 階層スコープ(`#list >> .Cell[2]`)と近接アンカー(`:near(...)`)の解決規則。
/// スナップショットは pre-order + depth という 3 ブリッジ共通の規約を前提にする。
final class SelectorScopeTests: XCTestCase {

    private func node(_ ref: Int, _ type: String, depth: Int, id: String? = nil,
                      label: String? = nil, enabled: Bool = true,
                      x: Double = 0, y: Double = 0) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: x, y: y, width: 10, height: 10), depth: depth)
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
            node(0, "Other", depth: 0),
            node(1, "Other", depth: 1, id: "header"),
            node(2, "Cell", depth: 2, label: "先頭"),
            node(3, "Other", depth: 1, id: "list"),
            node(4, "Cell", depth: 2, label: "りんご"),
            node(5, "Cell", depth: 2, label: "みかん"),
            node(6, "Cell", depth: 2, label: "ぶどう"),
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
        let global = FlowLocator(type: "Cell", index: 1)
        XCTAssertEqual(StepExecutor.matchDetailed(global, elements: tree)?.0.label, "りんご")
        // スコープ付きは容器の中で数えるので "みかん"
        let scoped = FlowLocator(type: "Cell", index: 1, scope: [FlowLocator(id: "list")])
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
        let scoped = FlowLocator(type: "Cell", scope: [FlowLocator(id: "存在しない")])
        XCTAssertNil(StepExecutor.matchDetailed(scoped, elements: tree))
    }

    func testNearPicksClosestCandidate() {
        let elements = [
            node(1, "StaticText", depth: 1, label: "住所", x: 0, y: 0),
            node(2, "StaticText", depth: 1, label: "氏名", x: 0, y: 200),
            node(3, "Button", depth: 1, label: "編集", x: 100, y: 210),
            node(4, "Button", depth: 1, label: "編集", x: 100, y: 10),
        ]
        let nearName = FlowLocator(label: "編集", near: [FlowLocator(label: "氏名")])
        XCTAssertEqual(StepExecutor.matchDetailed(nearName, elements: elements)?.0.ref, 3)
        let nearAddress = FlowLocator(label: "編集", near: [FlowLocator(label: "住所")])
        XCTAssertEqual(StepExecutor.matchDetailed(nearAddress, elements: elements)?.0.ref, 4)
    }

    func testNearWithUnresolvableAnchorFails() {
        let locator = FlowLocator(type: "Cell", near: [FlowLocator(id: "居ない")])
        XCTAssertNil(StepExecutor.matchDetailed(locator, elements: tree))
    }

    func testCandidatesCountsWithinScope() {
        let all = StepExecutor.candidates(FlowLocator(type: "Cell"), elements: tree)
        XCTAssertEqual(all?.matches.count, 4)
        let scoped = StepExecutor.candidates(
            FlowLocator(type: "Cell", scope: [FlowLocator(id: "list")]), elements: tree)
        XCTAssertEqual(scoped?.matches.count, 3)
        // 条件が空(id/label/type すべて nil)のロケータは「数えられない」= nil
        XCTAssertNil(StepExecutor.candidates(FlowLocator(), elements: tree))
    }

    func testLabelCandidatesPreferExactOverSubstring() {
        let elements = [
            node(1, "StaticText", depth: 1, label: "通知を許可"),
            node(2, "StaticText", depth: 1, label: "許可"),
        ]
        let result = StepExecutor.candidates(FlowLocator(label: "許可"), elements: elements)
        XCTAssertEqual(result?.quality, .exact)
        XCTAssertEqual(result?.matches.map(\.ref), [2])
    }

    func testScopedTypeLocatorIsNotWeakForAssert() {
        XCTAssertTrue(FlowLocator(type: "Cell", index: 1).isWeakForAssert)
        XCTAssertFalse(FlowLocator(id: "a").isWeakForAssert)
        XCTAssertFalse(FlowLocator(label: "a").isWeakForAssert)
        // スコープ付きは容器に錨があるのでアサーションのフォールバックから除外しない
        XCTAssertFalse(FlowLocator(type: "Cell", index: 1,
                                   scope: [FlowLocator(id: "list")]).isWeakForAssert)
    }
}
