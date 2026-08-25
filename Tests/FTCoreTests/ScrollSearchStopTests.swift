// スクロール探索が**もう動かない画面で上限まで振り続けない**ことを固定する。
//
// 端に着いた後のスワイプは1本も結果を変えないのに、旧実装は maxSwipes(既定 8)まで撃っていた。
// 判定は木の contentSignature が2周続けて同一(1周で切ると、遅れて描画される行を
// 「動かなかった」と誤断して取りこぼす)。

import XCTest
@testable import FTCore

/// swipe 回数と snapshot 回数だけ数える最小ドライバ
private final class CountingDriver: AppDriver {
    /// 何周目でも同じ木を返す = 「振っても動かない」画面
    let frame: [ElementInfo]
    private(set) var swipeCount = 0

    init(frame: [ElementInfo]) { self.frame = frame }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipeCount += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipeCount += 1
    }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: frame, truncatedCount: 0)
    }
}

/// 1周ごとに木が変わり続ける(= 動いている)画面。最後まで目標は出てこない。
/// `movesAtMost` を絞ると**動いた末に凍る**(= リストの末尾に着いた形)になる
private final class MovingDriver: AppDriver {
    private(set) var swipeCount = 0
    private var snapshots = 0
    private let movesAtMost: Int

    init(movesAtMost: Int = .max) { self.movesAtMost = movesAtMost }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipeCount += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipeCount += 1
    }
    func snapshot() async throws -> SnapshotResponse {
        snapshots += 1
        // 整定(1周目)で同じ木を2枚要求されるので、2枚ごとに位置を動かす
        let y = 600 - Double(min((snapshots - 1) / 2, movesAtMost)) * 40
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: [ElementInfo(ref: 1, type: "clickable",
                                                       identifier: "anchor", label: "行",
                                                       value: nil, placeholder: nil, enabled: true,
                                                       frame: FTRect(x: 16, y: y,
                                                                     width: 370, height: 56),
                                                       depth: 1)],
                                truncatedCount: 0)
    }
}

final class ScrollSearchStopTests: XCTestCase {

    private static let still = [
        ElementInfo(ref: 1, type: "clickable", identifier: "anchor", label: "行", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 600, width: 370, height: 56), depth: 1)
    ]

    private func scrollTo(_ id: String, maxSwipes: Int) -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: id),
                 direction: "up", maxSwipes: maxSwipes)
    }

    /// **動かない画面では上限より手前で止まる**。判定は2周連続の同一なので、
    /// 撃つのは 2 本(1本目で比較材料を作り、2・3本目の比較で打ち切り)
    func testSearchStopsOnceTheContentNoLongerMoves() async throws {
        let driver = CountingDriver(frame: Self.still)

        let result = await StepExecutor(driver: driver).execute(scrollTo("missing", maxSwipes: 8))

        XCTAssertLessThan(driver.swipeCount, 8,
                          "動かない画面なのに上限まで振っている: \(driver.swipeCount) 回")
        guard case .failed(let reason) = result.status else {
            return XCTFail("見つからない探索は失敗のはず: \(result.status)")
        }
        XCTAssertTrue(reason.contains("nothing moved at all"),
                      "1度も動かなかったことが理由文に出ていない: \(reason)")
        XCTAssertTrue(reason.contains("raising maxSwipes will not help"),
                      "上限を上げても無駄だと言っていない: \(reason)")
        XCTAssertFalse(reason.contains("after 8 scroll(s)"),
                       "実際には振っていない回数を名乗っている: \(reason)")
    }

    /// **末尾に着いた回を「途中で諦めた」と読ませない**。
    /// iOS の設定アプリで実測: リストの末尾まで届いていたのに旧文言が
    /// 「stopped early: the content no longer moved」としか言わず、読み手は欠陥と受け取って
    /// maxSwipes を 15 に上げて撃ち直した(結果は同じ)
    func testReachedTheEndSaysSoInsteadOfStoppedEarly() {
        let step = scrollTo("missing", maxSwipes: 8)
        let reachedEnd = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                         viaXCUITest: false, hintJumps: 0,
                                                         swipes: 3, stoppedUnmoving: true,
                                                         contentEverMoved: true)
        let message = StepExecutor.scrollNotFoundMessage(step, reachedEnd)
        XCTAssertTrue(message.contains("reached its end"), message)
        XCTAssertTrue(message.contains("raising maxSwipes will not help"), message)
        XCTAssertFalse(message.contains("nothing moved at all"),
                       "動いた末の停止を「1度も動かなかった」と言っている: \(message)")
    }

    /// 1度も動かなかった回は別の手(容器の指定・上に重なった物の始末)が要るので文を分ける
    func testNeverMovedIsDistinguishedFromReachingTheEnd() {
        let step = scrollTo("missing", maxSwipes: 8)
        let neverMoved = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                         viaXCUITest: false, hintJumps: 0,
                                                         swipes: 3, stoppedUnmoving: true,
                                                         contentEverMoved: false)
        let message = StepExecutor.scrollNotFoundMessage(step, neverMoved)
        XCTAssertTrue(message.contains("nothing moved at all"), message)
        XCTAssertFalse(message.contains("reached its end"), message)
    }

    /// **動いた末に止まったことを探索本体が申告する**。文言のテストだけだと
    /// `contentEverMoved` を常に false にしても両方緑のままになる(配線の砦)
    func testSearchReportsThatTheContentMovedBeforeItStopped() async throws {
        let driver = MovingDriver(movesAtMost: 1)

        let result = await StepExecutor(driver: driver).execute(scrollTo("missing", maxSwipes: 8))

        guard case .failed(let reason) = result.status else {
            return XCTFail("見つからない探索は失敗のはず: \(result.status)")
        }
        XCTAssertTrue(reason.contains("reached its end"),
                      "動いた後で止まったのに「1度も動かなかった」と言っている: \(reason)")
    }

    /// **動いている間は打ち切らない**(上限まで使う)。ここが縮むと、
    /// 遅れて現れる行に届かなくなる
    func testSearchKeepsGoingWhileTheContentMoves() async throws {
        let driver = MovingDriver()

        _ = await StepExecutor(driver: driver).execute(scrollTo("missing", maxSwipes: 5))

        XCTAssertEqual(driver.swipeCount, 5,
                       "動いているのに打ち切った: \(driver.swipeCount) 回")
    }

    /// **明示 scrollFrame が解決できないなら、1本も振らずに失敗させる**。
    /// 黙って全画面スワイプへ退化すると、無関係な要素(カードのボタン等)を発火させ得るための
    /// fail-fast(実害: Apple マップで申告した容器がツリーから消え、退化したスワイプが
    /// カードの「計画」ボタンを叩いて画面遷移した)。MCP はこのコードで文面を分岐する(RefGuard 経由)
    func testExplicitScrollFrameThatDoesNotResolveFailsWithoutSwiping() async throws {
        let driver = CountingDriver(frame: Self.still)
        var step = scrollTo("missing", maxSwipes: 8)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        let outcome = await StepExecutor(driver: driver).execute(step)

        XCTAssertEqual(driver.swipeCount, 0, "scrollFrame が解決できないなら1本も振らないこと")
        guard case .failed(let reason) = outcome.status else {
            return XCTFail("scrollFrame 未解決は失敗のはず: \(outcome.status)")
        }
        XCTAssertTrue(reason.contains("search was not run"), reason)
        XCTAssertTrue(outcome.notes.contains(.scrollFrameMissing),
                      "MCP が分岐に使う機械可読コードが立っていない")
    }

    /// **シート展開のヒント**: `stoppedUnmoving` かつ `containerIsPartialHeight`(明示 scrollFrame が
    /// 画面の大半を占めない)のときだけ末尾に追記する(2026-08-08・Google マップ実測: 半開ボトムシート
    /// 内のリストが1pxも動かず「content no longer moved」で終わり、シート展開が要ることを
    /// 利用者が推測するしかなかった)
    func testStoppedUnmovingMessageSuggestsExpandingTheSheet() {
        let step = scrollTo("missing", maxSwipes: 8)
        let stopped = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                       hintJumps: 0, swipes: 3, stoppedUnmoving: true,
                                                       containerIsPartialHeight: true)
        let message = StepExecutor.scrollNotFoundMessage(step, stopped)
        XCTAssertTrue(message.contains("half-open bottom sheet"), message)
    }

    /// **全画面リストの末尾到達では出さない**(containerIsPartialHeight == false)。
    /// 毎回シートの心配をさせない
    func testStoppedUnmovingAtFullHeightContainerDoesNotMentionTheSheet() {
        let step = scrollTo("missing", maxSwipes: 8)
        let stopped = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                       hintJumps: 0, swipes: 3, stoppedUnmoving: true,
                                                       containerIsPartialHeight: false)
        let message = StepExecutor.scrollNotFoundMessage(step, stopped)
        XCTAssertFalse(message.contains("bottom sheet"), message)
    }

    // MARK: - scrollFrame 未指定でもシートを見つける

    private func snapshot(_ elements: [ElementInfo], height: Double = 874) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 402, height: height),
                         elements: elements, truncatedCount: 0)
    }

    private func scroller(_ ref: Int, y: Double, height: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "scrollView", identifier: "list", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 402, height: height), depth: 2,
                    scrollable: true)
    }

    /// **実測の形**(Apple マップの経路手順): 折りたたまれたトレイの中の
    /// `#TransitDirectionsListView` は 189/874 = 22%。scrollFrame を渡していない1回目でも
    /// 「シートを広げろ」に辿り着けること
    func testPartialHeightSheetIsFoundWithoutAnExplicitScrollFrame() {
        XCTAssertTrue(StepExecutor.partialHeightSheetExists(
            in: snapshot([scroller(1, y: 676, height: 189)])))
    }

    /// 全画面リストは対象外(末尾到達で毎回シートを探しに行かせない)
    func testFullHeightListIsNotASheet() {
        XCTAssertFalse(StepExecutor.partialHeightSheetExists(
            in: snapshot([scroller(1, y: 0, height: 800)])))
    }

    /// チップ行・横カルーセル(実測 5% 前後)も対象外 —— これを拾うと Android のほぼ全画面で鳴る
    func testAThinCarouselIsNotASheet() {
        XCTAssertFalse(StepExecutor.partialHeightSheetExists(
            in: snapshot([scroller(1, y: 305, height: 126)], height: 2361)))
    }

    /// **申告のある容器だけ**を見る(推測まで混ぜると全画面リストでも鳴る)
    func testUndeclaredContainerIsNotCountedAsASheet() {
        let plain = ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 676, width: 402, height: 189), depth: 2)
        XCTAssertFalse(StepExecutor.partialHeightSheetExists(in: snapshot([plain])))
    }

    /// 打ち切られていない(上限まで振った/探索が続いている)ときはシートの話は出さない
    func testStillGoingMessageDoesNotMentionTheSheet() {
        let step = scrollTo("missing", maxSwipes: 8)
        let stillGoing = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                          viaXCUITest: false, hintJumps: 0, swipes: 8)
        let message = StepExecutor.scrollNotFoundMessage(step, stillGoing)
        XCTAssertFalse(message.contains("bottom sheet"), message)
    }

    /// **fail-fast の文言はスワイプ数で分岐する**: 1本も送っていなければ
    /// 「検索は走っていない」、送った後に消えたなら「N 本振った後に消えた」と言う ——
    /// 送信後にも「送られなかった」と言うのは嘘になるため
    func testFailFastMessageBeforeAnySwipe() {
        let step = scrollTo("missing", maxSwipes: 8)
        let result = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                      hintJumps: 0, swipes: 0, scrollFrameMissing: true)
        let message = StepExecutor.scrollNotFoundMessage(step, result)
        XCTAssertTrue(message.contains("search was not run"), message)
    }

    func testFailFastMessageAfterSomeSwipes() {
        let step = scrollTo("missing", maxSwipes: 8)
        let result = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                      hintJumps: 0, swipes: 3, scrollFrameMissing: true)
        let message = StepExecutor.scrollNotFoundMessage(step, result)
        XCTAssertFalse(message.contains("was not run"), message)
        XCTAssertTrue(message.contains("disappeared from the tree after 3 swipe(s)"), message)
    }
}
