import XCTest
@testable import FTCore

/// 階層スコープ(`#list >> .clickable[2]`)・属性フィルタの AND 合成・相対セレクタ(`通知:rightSwitch`)
/// の解決規則。スナップショットは pre-order + depth という 3 ブリッジ共通の規約を前提にする。
final class SelectorScopeTests: XCTestCase {

    private func node(_ ref: Int, _ type: String, depth: Int, id: String? = nil,
                      label: String? = nil, value: String? = nil, placeholder: String? = nil,
                      enabled: Bool = true, checked: Bool? = nil,
                      x: Double = 0, y: Double = 0,
                      width: Double = 10, height: Double = 10) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value,
                    placeholder: placeholder, enabled: enabled,
                    frame: FTRect(x: x, y: y, width: width, height: height), depth: depth,
                    checked: checked)
    }

    /// 相対1ステップのロケータ(`基準:方向(型)`)
    private func relative(_ base: FlowLocator, _ direction: FlowDirection,
                          type: String? = nil, ordinal: Int? = nil) -> FlowLocator {
        var locator = base
        locator.relative = [FlowRelativeStep(direction: direction,
                                             filter: type.map { [FlowLocator(type: $0)] },
                                             ordinal: ordinal)]
        return locator
    }

    /// 画面: [0] ルート
    ///        ├ [1] #header
    ///        │   └ [2] clickable "先頭"
    ///        └ [3] #list
    ///            ├ [4] clickable "りんご"
    ///            ├ [5] clickable "みかん"
    ///            └ [6] clickable "ぶどう"
    private var tree: [ElementInfo] {
        [
            node(0, "other", depth: 0),
            node(1, "other", depth: 1, id: "header"),
            node(2, "clickable", depth: 2, label: "先頭"),
            node(3, "other", depth: 1, id: "list"),
            node(4, "clickable", depth: 2, label: "りんご"),
            node(5, "clickable", depth: 2, label: "みかん"),
            node(6, "clickable", depth: 2, label: "ぶどう"),
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
        // スコープ無しの .clickable[2] は画面全体の 2 番目(= ヘッダ配下を含むので "りんご")
        let global = FlowLocator(type: "clickable", index: 1)
        XCTAssertEqual(StepExecutor.matchDetailed(global, elements: tree)?.0.label, "りんご")
        // スコープ付きは容器の中で数えるので "みかん"
        let scoped = FlowLocator(type: "clickable", index: 1, scope: [FlowLocator(id: "list")])
        XCTAssertEqual(StepExecutor.matchDetailed(scoped, elements: tree)?.0.label, "みかん")
    }

    /// 序数は型に限らずどのフィルタの組み合わせにも効く(`#list >> [2]` も書ける)
    func testOrdinalAppliesWithoutTypeFilter() {
        let scoped = FlowLocator(index: 1, scope: [FlowLocator(id: "list")])
        XCTAssertEqual(StepExecutor.matchDetailed(scoped, elements: tree)?.0.label, "みかん")
    }

    func testScopeExcludesElementsOutsideContainer() {
        let scoped = FlowLocator(label: "先頭", scope: [FlowLocator(id: "list")])
        XCTAssertNil(StepExecutor.matchDetailed(scoped, elements: tree))
        let inHeader = FlowLocator(label: "先頭", scope: [FlowLocator(id: "header")])
        XCTAssertEqual(inHeader.summary, "id=header >> text=先頭")
        XCTAssertEqual(StepExecutor.matchDetailed(inHeader, elements: tree)?.0.ref, 2)
    }

    func testUnresolvableScopeYieldsNoMatch() {
        let scoped = FlowLocator(type: "clickable", scope: [FlowLocator(id: "存在しない")])
        XCTAssertNil(StepExecutor.matchDetailed(scoped, elements: tree))
    }

    // MARK: - 部分一致は明示したときだけ

    func testBareTextIsExactOnly() {
        let elements = [
            node(1, "staticText", depth: 1, label: "通知を許可"),
            node(2, "staticText", depth: 1, label: "許可"),
        ]
        XCTAssertEqual(StepExecutor.candidates(FlowLocator(label: "許可"), elements: elements)?
            .map(\.ref), [2])
        // 完全一致が無ければ「部分一致で拾う」ことはもうしない(暗黙フォールバックの廃止)
        XCTAssertEqual(StepExecutor.candidates(FlowLocator(label: "を許"), elements: elements)?
            .count, 0)
    }

    func testExplicitPartialMatchModes() {
        let elements = [
            node(1, "staticText", depth: 1, label: "通知を許可"),
            node(2, "staticText", depth: 1, label: "許可"),
        ]
        func refs(_ locator: FlowLocator) -> [Int] {
            StepExecutor.candidates(locator, elements: elements)?.map(\.ref) ?? []
        }
        XCTAssertEqual(refs(FlowLocator(label: "許可", labelMatch: .contains)), [1, 2])
        XCTAssertEqual(refs(FlowLocator(label: "通知", labelMatch: .startsWith)), [1])
        XCTAssertEqual(refs(FlowLocator(label: "許可", labelMatch: .endsWith)), [1, 2])
        XCTAssertEqual(refs(FlowLocator(label: "^許.$", labelMatch: .matches)), [2])
    }

    /// 一致品質は記法ではなく**掴んだ要素**で決まる(ハイブリッドの fallback 優先判定の入力)
    func testQualityIsJudgedByMatchedElement() {
        let partial = FlowLocator(label: "許可", labelMatch: .contains)
        let long = node(1, "staticText", depth: 1, label: "通知を許可")
        let short = node(2, "staticText", depth: 1, label: "許可")
        XCTAssertEqual(StepExecutor.quality(of: long, for: partial), .substring)
        XCTAssertEqual(StepExecutor.quality(of: short, for: partial), .exact)
        XCTAssertEqual(StepExecutor.quality(of: long, for: FlowLocator(type: "staticText")), .exact)
    }

    // MARK: - 属性フィルタの AND 合成

    func testAttributeFiltersAreAnded() {
        let elements = [
            node(1, "textField", depth: 1, id: "name", value: "太郎", placeholder: "氏名"),
            node(2, "textField", depth: 1, id: "kana", value: "タロウ", placeholder: "フリガナ"),
            node(3, "switch", depth: 1, id: "sw", checked: true),
            node(4, "switch", depth: 1, id: "sw2", enabled: false),
        ]
        func refs(_ locator: FlowLocator) -> [Int] {
            StepExecutor.candidates(locator, elements: elements)?.map(\.ref) ?? []
        }
        XCTAssertEqual(refs(FlowLocator(value: "太郎")), [1])
        XCTAssertEqual(refs(FlowLocator(placeholder: "フリガナ")), [2])
        XCTAssertEqual(refs(FlowLocator(type: "textField", checked: false)), [1, 2])
        XCTAssertEqual(refs(FlowLocator(type: "switch", checked: true)), [3])
        XCTAssertEqual(refs(FlowLocator(type: "switch", enabled: false)), [4])
        // 条件が競合すれば 0 件(AND なので絞り込みが積み重なる)
        XCTAssertEqual(refs(FlowLocator(id: "name", value: "タロウ")), [])
    }

    func testTypeAliasExpandsToRoleSet() {
        let elements = [
            node(1, "textField", depth: 1, id: "a"),
            node(2, "secureTextField", depth: 1, id: "b"),
            node(3, "clickable", depth: 1, id: "c"),
            node(4, "button", depth: 1, id: "d"),
        ]
        func refs(_ type: String) -> [Int] {
            StepExecutor.candidates(FlowLocator(type: type), elements: elements)?.map(\.ref) ?? []
        }
        XCTAssertEqual(refs("input"), [1, 2])
        // widget は役割が確定した型だけ(役割不明の clickable は入れない)
        XCTAssertEqual(refs("widget"), [1, 2, 4])
        XCTAssertEqual(refs("button"), [4])
    }

    // MARK: - 相対セレクタ(基準が先・対象が後)

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
        let notify = relative(FlowLocator(label: "通知"), .right, type: "switch")
        XCTAssertEqual(StepExecutor.matchDetailed(notify, elements: rows)?.0.identifier, "sw_notify")
        let location = relative(FlowLocator(label: "位置情報"), .right, type: "switch")
        XCTAssertEqual(StepExecutor.matchDetailed(location, elements: rows)?.0.identifier,
                       "sw_location")
    }

    /// 方向が合わない/帯から外れる候補しか無ければ **解決失敗**(最も近いものを返さない)。
    /// これが `:near` を廃した理由そのもの — レイアウト変更時に黙って別要素を掴ませない
    func testDirectionFailsInsteadOfPickingNearest() {
        let toLeft = relative(FlowLocator(label: "通知"), .left, type: "switch")
        XCTAssertNil(StepExecutor.matchDetailed(toLeft, elements: rows))
        // 帯の外(別の行)にしか候補が無い場合も同様
        let outOfBand = [rows[0], rows[3]]
        let right = relative(FlowLocator(label: "通知"), .right, type: "switch")
        XCTAssertNil(StepExecutor.matchDetailed(right, elements: outOfBand))
    }

    func testDirectionAboveAndBelowUseHorizontalBand() {
        let elements = [
            node(1, "staticText", depth: 1, label: "見出し", x: 0, y: 0, width: 100, height: 20),
            node(2, "button", depth: 1, id: "under", x: 10, y: 40, width: 60, height: 20),
            node(3, "button", depth: 1, id: "far_right", x: 300, y: 40, width: 60, height: 20),
        ]
        let below = relative(FlowLocator(label: "見出し"), .below, type: "button")
        XCTAssertEqual(StepExecutor.matchDetailed(below, elements: elements)?.0.identifier, "under")
        let above = relative(FlowLocator(label: "見出し"), .above, type: "button")
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
        let locator = relative(FlowLocator(label: "数量"), .right, type: "button")
        XCTAssertEqual(StepExecutor.matchDetailed(locator, elements: elements)?.0.identifier, "near")
    }

    /// 序数(`数量:rightButton(2)`)は「近い順」の n 番目。同距離はツリー順
    func testDirectionOrdinalWalksNearestFirst() {
        let elements = [
            node(1, "staticText", depth: 1, label: "数量", x: 0, y: 0, width: 40, height: 40),
            node(2, "button", depth: 1, id: "far", x: 200, y: 0, width: 40, height: 40),
            node(3, "button", depth: 1, id: "near", x: 100, y: 0, width: 40, height: 40),
        ]
        for (ordinal, expected) in [(1, "near"), (2, "far")] {
            let locator = relative(FlowLocator(label: "数量"), .right, type: "button", ordinal: ordinal)
            XCTAssertEqual(StepExecutor.matchDetailed(locator, elements: elements)?.0.identifier,
                           expected, "ordinal=\(ordinal)")
        }
        // 足りなければ解決失敗(手前の要素を返さない)
        let tooFar = relative(FlowLocator(label: "数量"), .right, type: "button", ordinal: 3)
        XCTAssertNil(StepExecutor.matchDetailed(tooFar, elements: elements))
    }

    /// フィルタ省略時の既定は `.widget` = 役割が確定した型だけ(容器を掴まない)
    func testDirectionDefaultFilterIsWidget() {
        let elements = [
            node(1, "staticText", depth: 1, label: "数量", x: 0, y: 0, width: 40, height: 40),
            node(2, "other", depth: 1, id: "container", x: 60, y: 0, width: 40, height: 40),
            node(3, "button", depth: 1, id: "plus", x: 100, y: 0, width: 40, height: 40),
        ]
        var locator = FlowLocator(label: "数量")
        locator.relative = [FlowRelativeStep(direction: .right)]
        XCTAssertEqual(StepExecutor.matchDetailed(locator, elements: elements)?.0.identifier, "plus")
    }

    func testRelativeStepsChain() {
        let elements = [
            node(1, "staticText", depth: 1, label: "見出し", x: 0, y: 0, width: 40, height: 20),
            node(2, "staticText", depth: 1, label: "右", x: 100, y: 0, width: 40, height: 20),
            node(3, "button", depth: 1, id: "goal", x: 100, y: 60, width: 40, height: 20),
        ]
        var locator = FlowLocator(label: "見出し")
        locator.relative = [
            FlowRelativeStep(direction: .right),
            FlowRelativeStep(direction: .below, filter: [FlowLocator(type: "button")]),
        ]
        XCTAssertEqual(StepExecutor.matchDetailed(locator, elements: elements)?.0.identifier, "goal")
    }

    func testDirectionExcludesAnchorItself() {
        let elements = [
            node(1, "staticText", depth: 1, label: "合計", x: 0, y: 0, width: 40, height: 40),
            node(2, "staticText", depth: 1, label: "合計", x: 100, y: 0, width: 40, height: 40),
        ]
        // 同一ラベルが並ぶ場合でも、基準として解決した要素自身は候補にしない
        var locator = FlowLocator(label: "合計")
        locator.relative = [FlowRelativeStep(direction: .right, filter: [FlowLocator(label: "合計")])]
        XCTAssertEqual(StepExecutor.matchDetailed(locator, elements: elements)?.0.ref, 2)
    }

    func testDirectionWithUnresolvableAnchorFails() {
        let locator = relative(FlowLocator(id: "居ない"), .right, type: "clickable")
        XCTAssertNil(StepExecutor.matchDetailed(locator, elements: tree))
    }

    /// スコープは節の中の**基準にも対象にも**効く(容器の外の同名ラベルを基準にしない)
    func testRelativeResolvesInsideScope() {
        let elements = [
            node(1, "other", depth: 0, id: "page"),
            node(2, "staticText", depth: 1, label: "数量", x: 0, y: 0, width: 40, height: 40),
            node(3, "button", depth: 1, id: "outside", x: 100, y: 0, width: 40, height: 40),
            node(4, "other", depth: 1, id: "row"),
            node(5, "staticText", depth: 2, label: "数量", x: 0, y: 100, width: 40, height: 40),
            node(6, "button", depth: 2, id: "inside", x: 100, y: 100, width: 40, height: 40),
        ]
        var locator = relative(FlowLocator(label: "数量"), .right, type: "button")
        locator.scope = [FlowLocator(id: "row")]
        XCTAssertEqual(StepExecutor.matchDetailed(locator, elements: elements)?.0.identifier, "inside")
    }

    /// countIs 等の「集合を数える」経路は相対ステップを解決してから数える
    /// (基準の個数で数えてしまうと `通知:rightSwitch` が常に 1 以上になる)
    func testResolvedCandidatesCountsRelativeResult() {
        let locator = relative(FlowLocator(label: "通知"), .right, type: "switch")
        XCTAssertEqual(StepExecutor.resolvedCandidates(locator, elements: rows)?.map(\.identifier),
                       ["sw_notify"])
        // 属性フィルタだけを見る candidates は基準(staticText 1件)しか知らない
        XCTAssertEqual(StepExecutor.candidates(locator, elements: rows)?.count, 1)
        // 解決できなければ 0 件(「数えられない」nil ではない = notExist/countIs(x,0) が働く)
        let toLeft = relative(FlowLocator(label: "通知"), .left, type: "switch")
        XCTAssertEqual(StepExecutor.resolvedCandidates(toLeft, elements: rows)?.count, 0)
    }

    /// `||` は候補集合の和(Shirates 準拠)。順序は「節の順 → 節内のツリー順」で、重複は先勝ち
    func testUnionCandidatesKeepsClauseOrderAndDeduplicates() {
        let elements = [
            node(1, "button", depth: 1, id: "save", label: "保存"),
            node(2, "switch", depth: 1, id: "sw"),
            node(3, "button", depth: 1, id: "cancel"),
        ]
        let union = StepExecutor.unionCandidates(
            [FlowLocator(type: "switch"), FlowLocator(type: "button")], elements: elements)
        XCTAssertEqual(union.map(\.identifier), ["sw", "save", "cancel"])
        // 同じ要素を指す節が並んでも1度だけ
        let overlapping = StepExecutor.unionCandidates(
            [FlowLocator(id: "save"), FlowLocator(label: "保存")], elements: elements)
        XCTAssertEqual(overlapping.map(\.identifier), ["save"])
    }

    /// 相対セレクタの `||` も和集合。節ごとに方向解決せず、**合わせてから最も近い1つ**を採る
    func testRelativeUnionPicksNearestAcrossClauses() {
        let elements = [
            node(1, "staticText", depth: 1, label: "通知", x: 0, y: 0, width: 40, height: 40),
            node(2, "switch", depth: 1, id: "near_switch", x: 50, y: 0, width: 40, height: 40),
            node(3, "button", depth: 1, id: "far_button", x: 200, y: 0, width: 40, height: 40),
        ]
        var locator = FlowLocator(label: "通知")
        locator.relative = [FlowRelativeStep(
            direction: .right,
            filter: [FlowLocator(type: "button"), FlowLocator(type: "switch")], ordinal: nil)]
        XCTAssertEqual(StepExecutor.matchDetailed(locator, elements: elements)?.0.identifier,
                       "near_switch", "節の順ではなく距離で決まる")
        // 序数は和集合に対して数える
        var second = locator
        second.relative?[0].ordinal = 2
        XCTAssertEqual(StepExecutor.matchDetailed(second, elements: elements)?.0.identifier,
                       "far_button")
    }

    func testCandidatesCountsWithinScope() {
        let all = StepExecutor.candidates(FlowLocator(type: "clickable"), elements: tree)
        XCTAssertEqual(all?.count, 4)
        let scoped = StepExecutor.candidates(
            FlowLocator(type: "clickable", scope: [FlowLocator(id: "list")]), elements: tree)
        XCTAssertEqual(scoped?.count, 3)
        // 絞り込み条件が1つも無いロケータは「数えられない」= nil
        XCTAssertNil(StepExecutor.candidates(FlowLocator(), elements: tree))
    }

    func testScopedTypeLocatorIsNotWeakForAssert() {
        XCTAssertTrue(FlowLocator(type: "clickable", index: 1).isWeakForAssert)
        XCTAssertFalse(FlowLocator(id: "a").isWeakForAssert)
        XCTAssertFalse(FlowLocator(label: "a").isWeakForAssert)
        XCTAssertFalse(FlowLocator(value: "a").isWeakForAssert)
        // スコープ付き・相対セレクタ付きは錨があるのでアサーションのフォールバックから除外しない
        XCTAssertFalse(FlowLocator(type: "clickable", index: 1,
                                   scope: [FlowLocator(id: "list")]).isWeakForAssert)
        XCTAssertFalse(relative(FlowLocator(type: "clickable"), .right).isWeakForAssert)
    }

    /// 完全一致で外したが部分一致なら在るときは、書き換え方を失敗メッセージに出す
    func testPartialMatchHintSuggestsWildcard() {
        let elements = [node(1, "staticText", depth: 1, label: "通知を許可")]
        let hint = StepExecutor.partialMatchHint(for: FlowLocator(label: "許可"), in: elements)
        XCTAssertEqual(hint, "部分一致なら在る: \"*許可*\" と書くと拾える")
        XCTAssertNil(StepExecutor.partialMatchHint(for: FlowLocator(label: "通知を許可"),
                                                   in: elements))
        XCTAssertNil(StepExecutor.partialMatchHint(for: FlowLocator(label: "許可",
                                                                    labelMatch: .contains),
                                                   in: elements))
    }

    // MARK: - 否定フィルタ(`text!=`)

    func testNegationExcludesMatchingElements() {
        let elements = [
            node(1, "button", depth: 1, id: "save", label: "保存"),
            node(2, "button", depth: 1, id: "cancel", label: "キャンセル"),
            node(3, "staticText", depth: 1, label: "キャンセル"),
        ]
        let locator = FlowLocator(type: "button", not: [FlowLocator(label: "キャンセル")])
        XCTAssertEqual(StepExecutor.candidates(locator, elements: elements)?.map(\.identifier),
                       ["save"])
    }

    func testNegationAppliesAfterPositiveFiltersAndStacks() {
        let elements = [
            node(1, "button", depth: 1, id: "a", label: "追加"),
            node(2, "button", depth: 1, id: "b", label: "削除"),
            node(3, "button", depth: 1, id: "c", label: "編集"),
        ]
        let locator = FlowLocator(type: "button",
                                  not: [FlowLocator(label: "削除"), FlowLocator(label: "編集")])
        XCTAssertEqual(StepExecutor.candidates(locator, elements: elements)?.map(\.identifier),
                       ["a"])
    }

    func testNegationHonoursMatchMode() {
        let elements = [
            node(1, "cell", depth: 1, id: "r1", label: "注文 済"),
            node(2, "cell", depth: 1, id: "r2", label: "注文 未"),
        ]
        let locator = FlowLocator(type: "cell",
                                  not: [FlowLocator(label: "済", labelMatch: .contains)])
        XCTAssertEqual(StepExecutor.candidates(locator, elements: elements)?.map(\.identifier),
                       ["r2"])
    }

    /// 失敗メッセージに出る summary も `属性!=値` で見せる(セレクタ式と同じ読み方にする)
    func testNegationAppearsInSummary() {
        let locator = FlowLocator(type: "button", not: [FlowLocator(label: "キャンセル")])
        XCTAssertEqual(locator.summary, "button&&text!=キャンセル")
        let typed = FlowLocator(id: "row", not: [FlowLocator(type: "image")])
        XCTAssertEqual(typed.summary, "id=row&&type!=image")
    }
}
