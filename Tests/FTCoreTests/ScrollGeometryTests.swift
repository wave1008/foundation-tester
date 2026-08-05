import XCTest
@testable import FTCore

/// ScrollGeometry(shirates-core ScrollingInfo の移植)の境界を固定する。
/// 実機を必要としない層なので、ここで落とせない誤りは E2E まで見つからない。
final class ScrollGeometryTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    func testVerticalDownUsesBottomToTopWithMargins() {
        // 指は上へ動く(コンテンツは下へ進む)。始点は下の縁から startMargin ぶん内側
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .down,
                                       startMarginRatio: 0.2, endMarginRatio: 0.2)
        XCTAssertEqual(path?.fromY ?? 0, 874 * 0.8, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 874 * 0.2, accuracy: 0.001)
        XCTAssertEqual(path?.fromX ?? 0, 201, accuracy: 0.001)
        XCTAssertEqual(path?.toX ?? 0, 201, accuracy: 0.001)
    }

    func testVerticalUpIsMirrored() {
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .up,
                                       startMarginRatio: 0.2, endMarginRatio: 0.2)
        XCTAssertEqual(path?.fromY ?? 0, 874 * 0.2, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 874 * 0.8, accuracy: 0.001)
    }

    func testAsymmetricMarginsApplyToTheCorrectEdges() {
        // start=0.1(指を置く側 = 下)/ end=0.4(離す側 = 上)
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .down,
                                       startMarginRatio: 0.1, endMarginRatio: 0.4)
        XCTAssertEqual(path?.fromY ?? 0, 874 * 0.9, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 874 * 0.4, accuracy: 0.001)
    }

    func testHorizontalUsesCenterYAndWidth() {
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .right,
                                       startMarginRatio: 0.2, endMarginRatio: 0.2)
        XCTAssertEqual(path?.fromX ?? 0, 402 * 0.8, accuracy: 0.001)
        XCTAssertEqual(path?.toX ?? 0, 402 * 0.2, accuracy: 0.001)
        XCTAssertEqual(path?.fromY ?? 0, 437, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 437, accuracy: 0.001)
    }

    /// **容器は画面と交差させる**。E2E-iOS のリストは (16,270 370x492) で画面の一部しか占めない。
    /// 交差を取らずに容器そのものを使うと、画面外へはみ出す容器で座標が画面外に出る
    func testContainerIsClippedToViewport() {
        let container = FTRect(x: 16, y: 270, width: 370, height: 900)   // 画面下端を超える高さ
        let path = ScrollGeometry.path(container: container, viewport: screen, direction: .down,
                                       startMarginRatio: 0.2, endMarginRatio: 0.2)
        // 交差は y 270..874(高さ 604)
        XCTAssertEqual(path?.fromY ?? 0, 270 + 604 * 0.8, accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 270 + 604 * 0.2, accuracy: 0.001)
        XCTAssertEqual(path?.fromX ?? 0, 201, accuracy: 0.001)   // 16 + 370/2
    }

    func testNoIntersectionReturnsNil() {
        let offscreen = FTRect(x: 0, y: 900, width: 402, height: 100)
        XCTAssertNil(ScrollGeometry.path(container: offscreen, viewport: screen, direction: .down,
                                         startMarginRatio: 0.2, endMarginRatio: 0.2))
    }

    /// 接しているだけ(高さ 0 の交差)は操作できないので nil
    func testTouchingEdgeReturnsNil() {
        let touching = FTRect(x: 0, y: 874, width: 402, height: 100)
        XCTAssertNil(ScrollGeometry.path(container: touching, viewport: screen, direction: .down,
                                         startMarginRatio: 0.2, endMarginRatio: 0.2))
    }

    /// マージンの合計が 1 に達すると始点と終点が重なる = 1ミリも動かない。
    /// 上限で頭打ちにして「動くスワイプ」を返す
    func testMarginsAreClampedSoTheSwipeStillMoves() {
        let path = ScrollGeometry.path(container: screen, viewport: screen, direction: .down,
                                       startMarginRatio: 0.9, endMarginRatio: 0.9)
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.fromY ?? 0, 874 * (1 - ScrollGeometry.maxMarginRatio), accuracy: 0.001)
        XCTAssertEqual(path?.toY ?? 0, 874 * ScrollGeometry.maxMarginRatio, accuracy: 0.001)
        XCTAssertGreaterThan((path?.fromY ?? 0) - (path?.toY ?? 0), ScrollGeometry.minUsableDistance)
    }

    func testNegativeAndNonFiniteMarginsAreTreatedAsZero() {
        let negative = ScrollGeometry.path(container: screen, viewport: screen, direction: .down,
                                           startMarginRatio: -1, endMarginRatio: .nan)
        XCTAssertEqual(negative?.fromY ?? 0, 874, accuracy: 0.001)
        XCTAssertEqual(negative?.toY ?? 0, 0, accuracy: 0.001)
    }

    /// 小さすぎる容器では座標を作らず、呼び出し側を従来経路へ落とす
    func testTinyContainerReturnsNil() {
        let tiny = FTRect(x: 0, y: 400, width: 402, height: 10)
        XCTAssertNil(ScrollGeometry.path(container: tiny, viewport: screen, direction: .down,
                                         startMarginRatio: 0.2, endMarginRatio: 0.2))
    }

    /// 用途ごとの既定。**探索だけ保守側**(行き過ぎると戻らずシナリオ全体が中断するため)。
    /// 慣性を消して刻みを大きく取る案は 2026-08-02 に実装して実測で撤回した
    /// (iOS は velocity で消せるが Android に同じノブが無く、収束しなかった)
    func testSearchMarginIsMoreConservativeThanEdge() {
        let search = FTScrollDefaults.startMarginRatio(intent: .search, vertical: true)
        let edge = FTScrollDefaults.startMarginRatio(intent: .edge, vertical: true)
        XCTAssertGreaterThan(search, edge)
        XCTAssertEqual(search, 0.25, accuracy: 0.0001)
        XCTAssertEqual(edge, 0.2, accuracy: 0.0001)
    }

    /// 自己補正: 実移動量がビューポートの上限を超えたら刻みを詰める。
    /// **飛び越しは探索の失敗に直結する**(行き過ぎた要素は拾い直さない)
    func testScaledMarginsShrinkTheSpanSymmetrically() {
        let full = StepExecutor.scaledMargins(start: 0.1, end: 0.1, scale: 1)
        XCTAssertEqual(full.start, 0.1, accuracy: 0.0001)
        let half = StepExecutor.scaledMargins(start: 0.1, end: 0.1, scale: 0.5)
        // スパン 0.8 → 0.4 なので両端は 0.3 ずつ
        XCTAssertEqual(half.start, 0.3, accuracy: 0.0001)
        XCTAssertEqual(half.end, 0.3, accuracy: 0.0001)
        // 詰めすぎても動くスワイプを残す
        let tiny = StepExecutor.scaledMargins(start: 0.1, end: 0.1, scale: 0.01)
        XCTAssertLessThan(tiny.start, 0.5)
    }

    // `implicitScrollTarget`(面積最大のスクロール容器を暗黙の対象にする規則)のテストは
    // 2026-08-05 に**関数ごと削除**した。暗黙の座標化は2度撤回されており production から
    // 呼ばれていなかった = 生きているように見えるだけの死んだ規則だった。
    // 規則と再検討条件は docs/performance-tuning.md §3.19 に残っている(必要になったら書き直す)

    /// 横は現行の 0.2↔0.8(スパン 0.6)と同じ = 用途で分けない
    func testHorizontalMarginIsUniform() {
        for intent in FTSwipeIntent.allCases {
            XCTAssertEqual(FTScrollDefaults.startMarginRatio(intent: intent, vertical: false),
                           0.2, accuracy: 0.0001)
        }
    }

    // MARK: - scrollFrame の空振り検出

    private func el(_ ref: Int, id: String, y: Double, h: Double,
                    scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 402, height: h), depth: 1,
                    scrollable: scrollable)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }

    /// スクロールできない領域を指すと、座標は正しく作られてスワイプは 200 を返すのに何も動かない。
    /// 端に達したのと区別できないので**申告しないと気付けない**
    func testNoteWhenTheSpecifiedFrameCannotScroll() {
        let header = el(1, id: "header", y: 100, h: 40)
        let list = el(2, id: "list", y: 200, h: 500, scrollable: true)
        XCTAssertNotNil(StepExecutor.scrollFrameNote(header, in: snapshot([header, list])))
        XCTAssertNil(StepExecutor.scrollFrameNote(list, in: snapshot([header, list])))
    }

    /// 「リストを包む枠」を指定するのは自然な書き方。中のスクロール可能な要素が動けば意図は満たされる
    func testNoNoteWhenAScrollableElementIsInsideTheFrame() {
        let wrapper = el(1, id: "wrapper", y: 180, h: 560)
        let list = el(2, id: "list", y: 200, h: 500, scrollable: true)
        XCTAssertNil(StepExecutor.scrollFrameNote(wrapper, in: snapshot([wrapper, list])))
    }

    /// **申告できないエンジン(Compose/Flutter の in-app)では黙る**。全要素 nil のときに
    /// 警告すると誤報になる —— 使ってよいのは true を見つけたときだけ
    func testStaysSilentWhenTheEngineCannotReportScrollable() {
        let header = el(1, id: "header", y: 100, h: 40)
        let list = el(2, id: "list", y: 200, h: 500)
        XCTAssertNil(StepExecutor.scrollFrameNote(header, in: snapshot([header, list])))
    }

    // MARK: - flick(Shirates flickXxx 8種の幾何)

    /// centerTo系: 中心→各端。startMarginRatio は無関係(渡しても無視される式)
    func testFlickCenterToEachEdge() {
        let top = ScrollGeometry.flickPath(container: screen, viewport: screen,
                                           kind: .centerToTop, startMarginRatio: 0.2)
        XCTAssertEqual(top?.fromX ?? 0, 201, accuracy: 0.001)
        XCTAssertEqual(top?.fromY ?? 0, 437, accuracy: 0.001)
        XCTAssertEqual(top?.toX ?? 0, 201, accuracy: 0.001)
        XCTAssertEqual(top?.toY ?? 0, 0, accuracy: 0.001)

        let bottom = ScrollGeometry.flickPath(container: screen, viewport: screen,
                                              kind: .centerToBottom, startMarginRatio: 0.2)
        XCTAssertEqual(bottom?.toY ?? 0, 874, accuracy: 0.001)

        let left = ScrollGeometry.flickPath(container: screen, viewport: screen,
                                            kind: .centerToLeft, startMarginRatio: 0.2)
        XCTAssertEqual(left?.toX ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(left?.toY ?? 0, 437, accuracy: 0.001)

        let right = ScrollGeometry.flickPath(container: screen, viewport: screen,
                                             kind: .centerToRight, startMarginRatio: 0.2)
        XCTAssertEqual(right?.toX ?? 0, 402, accuracy: 0.001)
    }

    /// leftToRight: 始点は**右端×startMarginRatio**(Shirates の式をそのまま移植。左オフセットは
    /// 考慮しない)、終点は右端
    func testFlickLeftToRightUsesRightEdgeTimesRatio() {
        let path = ScrollGeometry.flickPath(container: screen, viewport: screen,
                                            kind: .leftToRight, startMarginRatio: 0.2)
        XCTAssertEqual(path?.fromX ?? 0, 402 * 0.2, accuracy: 0.001)
        XCTAssertEqual(path?.toX ?? 0, 402, accuracy: 0.001)
        XCTAssertEqual(path?.fromY ?? 0, 437, accuracy: 0.001)
    }

    func testFlickRightToLeftUsesOneMinusRatio() {
        let path = ScrollGeometry.flickPath(container: screen, viewport: screen,
                                            kind: .rightToLeft, startMarginRatio: 0.2)
        XCTAssertEqual(path?.fromX ?? 0, 402 * 0.8, accuracy: 0.001)
        XCTAssertEqual(path?.toX ?? 0, 0, accuracy: 0.001)
    }

    func testFlickBottomToTopAndTopToBottom() {
        let bottomToTop = ScrollGeometry.flickPath(container: screen, viewport: screen,
                                                    kind: .bottomToTop, startMarginRatio: 0.2)
        XCTAssertEqual(bottomToTop?.fromY ?? 0, 874 * 0.8, accuracy: 0.001)
        XCTAssertEqual(bottomToTop?.toY ?? 0, 0, accuracy: 0.001)

        let topToBottom = ScrollGeometry.flickPath(container: screen, viewport: screen,
                                                    kind: .topToBottom, startMarginRatio: 0.2)
        XCTAssertEqual(topToBottom?.fromY ?? 0, 874 * 0.2, accuracy: 0.001)
        XCTAssertEqual(topToBottom?.toY ?? 0, 874, accuracy: 0.001)
    }

    /// **safeMode 相当のクランプ**: 容器が左オフセットを持つと生の式(右端×ratio)は容器の外を指しうる。
    /// クランプ後は `container ∩ viewport` の内側に収まること
    func testFlickLeftToRightClampsRawFormulaIntoContainerIntersection() {
        // 画面右半分(x=200..402)を対象。生の式は fromX = 402*0.2 = 80.4(容器の外)になるが、
        // クランプ後は容器の左端(200)に寄る
        let rightHalf = FTRect(x: 200, y: 0, width: 202, height: 874)
        let path = ScrollGeometry.flickPath(container: rightHalf, viewport: screen,
                                            kind: .leftToRight, startMarginRatio: 0.2)
        XCTAssertEqual(path?.fromX ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(path?.toX ?? -1, 402, accuracy: 0.001)
    }

    /// 交差なし(容器が画面外)は nil
    func testFlickReturnsNilWhenContainerDoesNotIntersectViewport() {
        let offscreen = FTRect(x: 0, y: 900, width: 402, height: 100)
        XCTAssertNil(ScrollGeometry.flickPath(container: offscreen, viewport: screen,
                                              kind: .centerToTop, startMarginRatio: 0.2))
    }

    /// 開始比率が 1 近くに寄ると生の移動距離が縮むが、既定(0.2)は十分な距離を残す
    func testFlickKindAxisAndFingerDirectionMapping() {
        XCTAssertTrue(FlickKind.centerToTop.isVertical)
        XCTAssertTrue(FlickKind.bottomToTop.isVertical)
        XCTAssertFalse(FlickKind.leftToRight.isVertical)
        XCTAssertFalse(FlickKind.centerToRight.isVertical)

        XCTAssertEqual(FlickKind.centerToTop.fingerDirection, .up)
        XCTAssertEqual(FlickKind.bottomToTop.fingerDirection, .up)
        XCTAssertEqual(FlickKind.centerToBottom.fingerDirection, .down)
        XCTAssertEqual(FlickKind.topToBottom.fingerDirection, .down)
        XCTAssertEqual(FlickKind.centerToLeft.fingerDirection, .left)
        XCTAssertEqual(FlickKind.rightToLeft.fingerDirection, .left)
        XCTAssertEqual(FlickKind.centerToRight.fingerDirection, .right)
        XCTAssertEqual(FlickKind.leftToRight.fingerDirection, .right)
    }

    // MARK: - panPath(斜めを含む相対ドラッグ)

    /// 中心を挟んで対称。dx/dy とも非 0 = 斜めになること
    func testPanPathIsDiagonalAndSymmetricAroundTheCenter() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let path = ScrollGeometry.panPath(container: screen, viewport: screen,
                                          dxRatio: 0.5, dyRatio: -0.25)
        XCTAssertEqual(path?.fromX, 100)
        XCTAssertEqual(path?.fromY, 500)
        XCTAssertEqual(path?.toX, 300)
        XCTAssertEqual(path?.toY, 300)
    }

    /// 比率は container(要素)基準。**画面ではなく指定領域の幅・高さに掛かる**
    func testPanPathUsesTheContainerSizeNotTheScreen() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let container = FTRect(x: 100, y: 200, width: 200, height: 100)
        let path = ScrollGeometry.panPath(container: container, viewport: screen,
                                          dxRatio: 0.5, dyRatio: 0)
        // 中心 (200, 250)・移動量 100 → ±50
        XCTAssertEqual(path?.fromX, 150)
        XCTAssertEqual(path?.toX, 250)
        XCTAssertEqual(path?.fromY, 250)
        XCTAssertEqual(path?.toY, 250)
    }

    /// 画面外へはみ出す領域は交差を取ってから計算する(はみ出した座標は注入しても届かない)
    func testPanPathClipsTheContainerToTheViewport() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let container = FTRect(x: 200, y: 0, width: 400, height: 800)   // 右半分だけが画面内
        let path = ScrollGeometry.panPath(container: container, viewport: screen,
                                          dxRatio: 1.0, dyRatio: 0)
        // 交差は x=200..400(幅 200)・中心 300。比率は 0.9 で頭打ち = 移動量 180
        XCTAssertEqual(path?.fromX, 210)
        XCTAssertEqual(path?.toX, 390)
    }

    /// 1 を超える比率でも経路は領域の中に収まる(端をはみ出さない)
    func testPanPathIsClampedInsideTheArea() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let path = ScrollGeometry.panPath(container: screen, viewport: screen,
                                          dxRatio: 5, dyRatio: -5)
        XCTAssertEqual(path?.fromX, 20)     // 中心 200 − 0.9*400/2
        XCTAssertEqual(path?.toX, 380)
        XCTAssertEqual(path?.fromY, 760)
        XCTAssertEqual(path?.toY, 40)
    }

    /// 動かない指示(0 / 非有限 / 極小)は nil = 呼び手が失敗にできる
    func testPanPathReturnsNilWhenTheFingerWouldNotMove() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertNil(ScrollGeometry.panPath(container: screen, viewport: screen,
                                            dxRatio: 0, dyRatio: 0))
        XCTAssertNil(ScrollGeometry.panPath(container: screen, viewport: screen,
                                            dxRatio: .nan, dyRatio: .nan))
        XCTAssertNil(ScrollGeometry.panPath(container: screen, viewport: screen,
                                            dxRatio: 0.001, dyRatio: 0.001))
    }

    /// 交差しない領域では作れない(path と同じ契約)
    func testPanPathReturnsNilWithoutIntersection() {
        XCTAssertNil(ScrollGeometry.panPath(container: FTRect(x: 500, y: 0, width: 100, height: 100),
                                            viewport: FTRect(x: 0, y: 0, width: 400, height: 800),
                                            dxRatio: 0.5, dyRatio: 0.5))
    }
}
