// StepExecutor.isChromePinnedOutside の固定(2026-08-31・and-sutec_home)。
//
// Android Compose Scaffold の NavigationBar は無ラベルで間引かれ(SnapshotBuilder.shouldInclude)、
// preorder+depth の復元がタブを scroll 容器の子として再配線する。タブは容器と交差しないので
// isOutsideContainer / outsideDeclaredScroller の両方が ghost/scrolledOut と誤判定していた ——
// しかしタブは画面下端に固定された chrome であって、スクロールの残骸ではない。
//
// 各テストは isChromePinnedOutside / chromeBarMember の条件のうち、**どれか1つだけを反転させたら落ちる**ように
// 具体的な数値で組んである(全条件が真になって初めて chrome-pinned = ghost から除外される)。

import XCTest
@testable import FTCore

final class ChromePinnedOutsideTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ depth: Int, _ x: Double, _ y: Double,
                    _ w: Double, _ h: Double, id: String? = nil, label: String? = nil,
                    scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: x, y: y, width: w, height: h),
                    depth: depth, scrollable: scrollable)
    }

    // MARK: - (a) 実機の木そのもの(and-sutec_home。screen 1080x2340)

    /// witness: `#screen_home`(scrollView・d9・scrollable)の中に見出し2件(d10)、
    /// 下端 y=2054・高さ220 に5本のタブ(d10)。タブは容器の下端にちょうど接し、非交差になる
    func testWitnessBottomTabBarIsNotAGhost() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2340)
        let container = el(1, "scrollView", 9, 0, 136, 1080, 1918, id: "screen_home", scrollable: true)
        let headingA = el(2, "staticText", 10, 44, 180, 269, 71, label: "SUT Store")
        let headingB = el(7, "staticText", 10, 44, 867, 176, 64, label: "カテゴリ")
        let tabHome = el(46, "other", 10, 0, 2054, 199, 220, id: "tab_home")
        let tabSearch = el(48, "clickable", 10, 221, 2054, 199, 220, id: "tab_search")
        let tabCart = el(50, "clickable", 10, 442, 2054, 198, 220, id: "tab_cart")
        let tabWishlist = el(52, "clickable", 10, 662, 2054, 198, 220, id: "tab_wishlist")
        let tabAccount = el(54, "clickable", 10, 882, 2054, 198, 220, id: "tab_account")
        let elements = [container, headingA, headingB, tabHome, tabSearch, tabCart,
                         tabWishlist, tabAccount]

        XCTAssertEqual(StepExecutor.clippingContainer(of: tabHome, in: elements), container.frame,
                       "容器は screen_home のはず(タブは間引きで子に再配線される)")
        XCTAssertFalse(StepExecutor.isOutsideContainer(tabHome, in: elements, screen: screen),
                       "下端に固定された chrome は ghost 扱いしないこと")
        let kind = TapTargetGeometry.advisoryKind(for: tabHome, in: elements, screen: screen)
        if case .scrolledOut = kind {
            XCTFail("chrome-pinned なタブに scrolledOut 助言が出ている: \(String(describing: kind))")
        }
    }

    // MARK: - (b) 容器の上端に固定された chrome(top app bar)

    /// 進行軸の**上側**の帯でも同じ規律が働くこと(条件2の topBand 分岐)
    func testTopAppBarAboveTheScrollerIsNotAGhost() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2340)
        let scroller = el(1, "scrollView", 4, 0, 150, 1080, 2000, id: "screen_x", scrollable: true)
        let row1 = el(2, "cell", 5, 0, 160, 1080, 100, id: "row_1")
        let row2 = el(3, "cell", 5, 0, 260, 1080, 100, id: "row_2")
        let btnBack = el(4, "clickable", 5, 0, 0, 150, 150, id: "btn_back")
        let btnTitle = el(5, "other", 5, 150, 0, 780, 150, id: "btn_title")
        let elements = [scroller, row1, row2, btnBack, btnTitle]

        XCTAssertEqual(StepExecutor.clippingContainer(of: btnBack, in: elements), scroller.frame)
        XCTAssertFalse(StepExecutor.isOutsideContainer(btnBack, in: elements, screen: screen),
                       "容器の上端に固定された app bar は ghost 扱いしないこと")
    }

    // MARK: - (c) 本物の ghost: 容器の下 60pt・画面はまだ400pt残る(条件4で弾かれる)

    /// 中の行と同じ幅の単独行が容器のすぐ下に居るが、**画面端まで隙間が大きい**(400 > 56)ので
    /// 「固定された chrome」ではなく本物の ghost のまま
    func testRowJustBelowTheContainerWithRoomToSpareStaysAGhost() {
        let screen = FTRect(x: 0, y: 0, width: 390, height: 1208)
        // scrollable を付けて条件(5)を通す = ここで落ちるのは条件(4)だけ
        let container = el(100, "scrollView", 1, 0, 230, 390, 462, id: "list_rows", scrollable: true)
        let row1 = el(1, "cell", 2, 0, 240, 370, 56, id: "row_01")
        let row2 = el(2, "cell", 2, 0, 300, 370, 56, id: "row_02")
        // 容器の下端(692)から60pt: y=752、画面下端(1208)まではまだ400pt残る(808+400)
        let ghost = el(3, "cell", 2, 0, 752, 370, 56, id: "row_30")
        let elements = [container, row1, row2, ghost]

        XCTAssertEqual(StepExecutor.clippingContainer(of: ghost, in: elements), container.frame)
        XCTAssertTrue(StepExecutor.isOutsideContainer(ghost, in: elements, screen: screen),
                      "隙間(400)が高さ(56)を大きく超えるので、chrome ではなく ghost のまま")
    }

    // MARK: - (d) and-browser_weather_weekly の形: 小さな非 scrollable な推測容器(条件5で弾かれる)

    /// 容器が本物の viewport でない(scrollable でも画面の50%以上でもない)ときは、
    /// 他の条件(帯・画面内・固定)を満たしていても chrome とは認めない ——
    /// 認めると `and-browser_weather_weekly` の「洗濯指数10」(実際の ghost)まで免除してしまう
    func testTinyNonViewportContainerStaysAGhostEvenWhenPinned() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 400)
        // 517x97 の偶発的な祖先(実測: `Link "8月14日(金)" (540,2184 517x97)`。ここでは
        // 座標を単純化しつつ同じ寸法比を保つ)
        let container = el(1, "link", 3, 540, 184, 517, 97, id: "link_period")
        let child1 = el(2, "staticText", 4, 703, 207, 142, 45)
        let child2 = el(3, "staticText", 4, 842, 207, 37, 45)
        let target = el(4, "staticText", 4, 233, 320, 383, 43, label: "洗濯指数10")
        // 条件6(バーの形)は満たせるように置く —— それでも条件5だけで ghost のままなことを示す
        let sibling = el(5, "staticText", 4, 650, 320, 383, 43, label: "他の帯")
        let elements = [container, child1, child2, target, sibling]

        XCTAssertEqual(StepExecutor.clippingContainer(of: target, in: elements), container.frame,
                       "容器は小さな link(517x97)に取り違えられるはず(実測と同じ形)")
        XCTAssertTrue(StepExecutor.isOutsideContainer(target, in: elements, screen: screen),
                      "容器が viewport でない(scrollable でも画面の50%以上でもない)ので ghost のまま")
    }

    // MARK: - (e) 単独の固定 chrome(条件6で弾かれる。保守的に ghost のまま)

    /// タブが1本しか無ければ「バーの形」を確認できないので、chrome とは認めない
    /// (FAB や単独タブのような孤立した chrome を誤って免除しないための保守的な設計)
    func testLonePinnedElementWithNoSiblingStaysAGhost() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2340)
        let container = el(1, "scrollView", 9, 0, 136, 1080, 1918, id: "screen_home", scrollable: true)
        let headingA = el(2, "staticText", 10, 44, 180, 269, 71, label: "SUT Store")
        let headingB = el(7, "staticText", 10, 44, 867, 176, 64, label: "カテゴリ")
        let loneTab = el(46, "other", 10, 0, 2054, 199, 220, id: "tab_home")
        let elements = [container, headingA, headingB, loneTab]

        XCTAssertTrue(StepExecutor.isOutsideContainer(loneTab, in: elements, screen: screen),
                      "同じ帯に他のタブが1本も無いので、バーの形と確認できず ghost のまま")
    }

    // MARK: - (f) 2列グリッドの最終行(容器の内側に同じ高さの兄弟が居る = 条件7で弾かれる)

    /// 2列グリッドの最終行が容器の下端を越えると、2セルは「同じ depth・同じ y/高さ・横に重ならない・
    /// 画面端まで自分の高さ以下」で帯の形(2)(3)(4)(6)を満たしてしまう。区別できるのは
    /// **容器の内側に同じ高さの行があること**(chrome は内側の何とも高さが揃わない)
    func testGridLastRowScrolledPastTheContainerStaysAGhost() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2340)
        let grid = el(1, "scrollView", 4, 0, 100, 1080, 1800, id: "grid", scrollable: true)
        let cellA = el(2, "cell", 5, 0, 1500, 540, 300, id: "cell_a")
        let cellB = el(3, "cell", 5, 540, 1500, 540, 300, id: "cell_b")
        let ghostA = el(4, "cell", 5, 0, 1950, 540, 300, id: "cell_c")
        let ghostB = el(5, "cell", 5, 540, 1950, 540, 300, id: "cell_d")
        let tree = [grid, cellA, cellB, ghostA, ghostB]
        XCTAssertEqual(StepExecutor.clippingContainer(of: ghostA, in: tree, inferring: true),
                       FTRect(x: 0, y: 100, width: 1080, height: 1800))
        XCTAssertTrue(StepExecutor.isOutsideContainer(ghostA, in: tree, screen: screen),
                      "内側に同じ高さ(300)のセルがあるので chrome ではなく ghost のまま")
        XCTAssertTrue(StepExecutor.isOutsideContainer(ghostB, in: tree, screen: screen))
    }

    // MARK: - (g) status bar のぶん下がって始まる上部バー(条件4の上帯倍率)

    /// iOS の nav bar は safe-area 上端(≤59pt)の下から始まる。隙間 59 > 高さ 44 だが、
    /// `chromeTopBandGapFactor`(2 倍)の内側なので chrome
    func testTopBarBelowTheStatusBarIsNotAGhost() {
        let screen = FTRect(x: 0, y: 0, width: 390, height: 844)
        let scroller = el(1, "scrollView", 4, 0, 103, 390, 741, id: "screen_x", scrollable: true)
        let row1 = el(2, "cell", 5, 0, 110, 390, 56, id: "row_1")
        let row2 = el(3, "cell", 5, 0, 166, 390, 56, id: "row_2")
        let btnBack = el(4, "button", 5, 0, 59, 48, 44, id: "btn_back")
        let btnAction = el(5, "button", 5, 342, 59, 48, 44, id: "btn_action")
        let tree = [scroller, row1, row2, btnBack, btnAction]
        XCTAssertFalse(StepExecutor.isOutsideContainer(btnBack, in: tree, screen: screen),
                       "隙間 59 は高さ 44 の 2 倍(88)以内 = 上端に固定された chrome")
        // 倍率を超えて下がっていれば chrome ではない(隙間 100 > 88)
        let lowBack = el(4, "button", 5, 0, 100, 48, 44, id: "btn_back")
        let lowAction = el(5, "button", 5, 342, 100, 48, 44, id: "btn_action")
        let scroller2 = el(1, "scrollView", 4, 0, 150, 390, 694, id: "screen_x", scrollable: true)
        let row1b = el(2, "cell", 5, 0, 160, 390, 56, id: "row_1")
        let row2b = el(3, "cell", 5, 0, 216, 390, 56, id: "row_2")
        XCTAssertTrue(StepExecutor.isOutsideContainer(lowBack, in: [scroller2, row1b, row2b, lowBack, lowAction],
                                                      screen: screen))
    }

    // MARK: - (h) host は祖先に限る(幾何的に含むだけの無関係なパネルでは免除しない)

    /// ラベル(d12)を含む 2 枚のパネル(d10・帯の形)が preorder で**後ろ**に居る = 祖先ではない。
    /// 旧実装(含む要素なら何でも host)では免除されていた
    func testContainingPanelThatIsNotAnAncestorDoesNotExempt() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2340)
        let container = el(1, "scrollView", 9, 0, 136, 1080, 1918, id: "screen_home", scrollable: true)
        let headingA = el(2, "staticText", 10, 44, 180, 269, 71, label: "SUT Store")
        let headingB = el(3, "staticText", 10, 44, 867, 176, 64, label: "カテゴリ")
        // 容器の内側にも d12 の要素を置く(容器推定が成立する形。高さは迷子と違えて条件7を素通し
        // させ、host 規則だけで結果が決まるようにする)
        let insideA = el(7, "staticText", 12, 44, 300, 200, 60, label: "商品A")
        let insideB = el(8, "staticText", 12, 44, 400, 200, 60, label: "商品B")
        let stray = el(4, "staticText", 12, 100, 2100, 100, 40, label: "迷子")
        let panelA = el(5, "other", 10, 0, 2054, 540, 220, id: "panel_a")
        let panelB = el(6, "other", 10, 540, 2054, 540, 220, id: "panel_b")
        let tree = [container, headingA, headingB, insideA, insideB, stray, panelA, panelB]
        XCTAssertEqual(StepExecutor.clippingContainer(of: stray, in: tree, inferring: true),
                       FTRect(x: 0, y: 136, width: 1080, height: 1918))
        XCTAssertTrue(StepExecutor.isOutsideContainer(stray, in: tree, screen: screen),
                      "含んでいる panel_a は祖先ではないので host にならず、迷子は ghost のまま")
    }
}
