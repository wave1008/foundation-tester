// 探索スワイプの刻みを詰める自己補正(`spanScale`)が、**容器の高さ**を基準に発火することを固定する。
//
// 旧実装は**画面の高さ**で割っていた。容器は定義上それより小さいので、実移動量が容器を大きく
// 超えていても閾値(0.8×画面)に届かず**ほぼ発火しなかった** —— docs/performance-tuning.md
// §3.18(f) の実測を当てると、SwiftUI は 1 スワイプ 681pt に対し閾値 699pt で素通りする一方、
// リストの可視高は 492pt = 1.38 倍の超過(いちばん取りこぼす SUT でガードが無効だった)。
//
// **効くのは `scrollFrame` を書いた経路だけ**(刻みを縮める口が `scrollPath` しかないため)。
// 未指定の経路はエンジン既定に委ねる = ここを広げると2度撤回した暗黙の座標化になる。

import XCTest
@testable import FTCore

/// `swipe(_:intent:path:)` を**素通しせず自分で受ける**ドライバ。既定実装に任せると
/// path が落ちて「刻みが縮んだか」を観測できない(AppDriver の既定は自分の swipe(_:) を呼ぶ)
private final class PathRecordingDriver: AppDriver {
    let elements: [[ElementInfo]]
    /// キーボードが立っている体で snapshot() に一律で乗せる(nil = 従来どおり非表示)。
    /// キーボード clip の回帰テスト専用
    var keyboardFrame: FTRect?
    private(set) var snapshotCount = 0
    private(set) var paths: [FTSwipePath?] = []

    init(elements: [[ElementInfo]], keyboardFrame: FTRect? = nil) {
        self.elements = elements
        self.keyboardFrame = keyboardFrame
    }

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
    func swipe(_ direction: FTSwipeDirection) async throws { paths.append(nil) }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        paths.append(path)
    }

    func snapshot() async throws -> SnapshotResponse {
        snapshotCount += 1
        let frame = elements[min(snapshotCount - 1, elements.count - 1)]
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: frame, truncatedCount: 0,
                                keyboardFrame: keyboardFrame)
    }
}

final class ScrollSpanShrinkTests: XCTestCase {

    /// 容器 `#list_rows` は y 230..692(高さ 462)。閾値は 0.8×462 = 369.6pt。
    /// **画面基準だと 0.8×874 = 699.2pt** なので、下の 500pt の移動は旧実装では素通りする
    private static func frame(anchorY: Double) -> [ElementInfo] {
        [ElementInfo(ref: 1, type: "other", identifier: "list_rows", label: nil, value: nil,
                     placeholder: nil, enabled: true,
                     frame: FTRect(x: 16, y: 230, width: 370, height: 462), depth: 1),
         ElementInfo(ref: 2, type: "clickable", identifier: "anchor", label: "行", value: nil,
                     placeholder: nil, enabled: true,
                     frame: FTRect(x: 16, y: anchorY, width: 370, height: 56), depth: 2)]
    }

    /// 距離を測る。縦方向なので y の移動量(始点→終点)
    private func span(_ path: FTSwipePath?) -> Double {
        guard let path else { return 0 }
        return abs(path.toY - path.fromY)
    }

    /// **容器を 1.08 倍超えた移動を観測したら次の刻みが縮む**。
    /// 500pt(容器 462 の 1.08 倍)は旧実装の閾値 699.2pt には届かないので、
    /// 画面基準に戻すとこのテストは落ちる。
    ///
    /// **フレーム列は探索ループの取得順に合わせる**: 1周目は `settledSignature` が
    /// 「連続2回同じ」を確認するので**同じ木を2枚**消費し、2周目の1枚が移動後になる
    func testSpanShrinksWhenTravelExceedsTheContainer() async throws {
        // 整定(600・600)→ 探索2周目に y=100 = 500pt 動いた
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 600),
                                                    Self.frame(anchorY: 600),
                                                    Self.frame(anchorY: 100)])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"),
                            direction: "up", maxSwipes: 2,
                            scrollFrame: FlowLocator(id: "list_rows"))

        _ = await StepExecutor(driver: driver).execute(step)

        let swipes = driver.paths.compactMap { $0 }
        XCTAssertGreaterThanOrEqual(swipes.count, 2, "刻みの比較には2回ぶんの path が要る: \(driver.paths)")
        XCTAssertLessThan(span(swipes[1]), span(swipes[0]) * 0.95,
                          "容器を超える移動を観測したのに刻みが縮んでいない"
                          + "(1周目 \(span(swipes[0]))pt → 2周目 \(span(swipes[1]))pt)")
    }

    /// 容器に収まる移動では縮めない(縮めるほどスワイプ本数が増えて遅くなるので、
    /// **必要なときだけ**発火させる)
    func testSpanIsKeptWhenTravelFitsInTheContainer() async throws {
        // 整定(400・400)→ 探索2周目に y=300(= 100pt。閾値 369.6pt を下回る)
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 400),
                                                    Self.frame(anchorY: 400),
                                                    Self.frame(anchorY: 300)])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"),
                            direction: "up", maxSwipes: 2,
                            scrollFrame: FlowLocator(id: "list_rows"))

        _ = await StepExecutor(driver: driver).execute(step)

        let swipes = driver.paths.compactMap { $0 }
        XCTAssertGreaterThanOrEqual(swipes.count, 2)
        XCTAssertEqual(span(swipes[1]), span(swipes[0]), accuracy: 0.001,
                       "容器に収まっているのに刻みを縮めてはいけない")
    }

    /// **`scrollFrame` 未指定なら path を送らない**(= エンジン既定の刻みに委ねる)。
    /// ここが nil でなくなったら、2度撤回した「暗黙の座標化」が復活している
    func testUnspecifiedScrollFrameSendsNoPath() async throws {
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 600),
                                                    Self.frame(anchorY: 100)])
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"),
                            direction: "up", maxSwipes: 2)

        _ = await StepExecutor(driver: driver).execute(step)

        XCTAssertFalse(driver.paths.isEmpty, "スワイプ自体は撃たれるはず")
        XCTAssertTrue(driver.paths.allSatisfy { $0 == nil },
                      "領域未指定で座標を送ってはいけない(暗黙の座標化は2度撤回済み): \(driver.paths)")
    }

    // MARK: - キーボード表示中の viewport クリップ(action "scroll"・scrollFrame 未指定)
    //
    // **バグ実測(iPhone 13・XCUITest エンジン)**: `scrollDown`/`scrollUp`(action "scroll")は
    // scrollFrame が無いと1周目の snapshot を撮らず(latest が常に nil)path ごと nil になり、
    // エンジン既定の swipeUp() がキーボードの上を撃っていた(始点は画面全体の固定比率で
    // 作られるため常にキー面に乗る = 中身がほぼ動かない)。修正後は scrollFrame 未指定でも
    // 毎回 snapshot を撮り、キーボードが立っていれば screen 全体を容器として座標を作る
    // (StepExecutor+ScrollFrame.swift の scrollContainer/scrollPath 参照)。

    func testScrollActionClipsTheViewportWhenTheKeyboardIsUpEvenWithoutScrollFrame() async throws {
        let keyboard = FTRect(x: 0, y: 600, width: 402, height: 274)
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 400)], keyboardFrame: keyboard)
        let step = FlowStep(action: "scroll", direction: "up", maxSwipes: 1)

        _ = await StepExecutor(driver: driver).execute(step)

        XCTAssertEqual(driver.paths.count, 1, "\(driver.paths)")
        let path = try XCTUnwrap(driver.paths[0], "キーボード表示中は座標つきスワイプを送るはず")
        XCTAssertLessThan(path.fromY, keyboard.y, "始点がキーボードの上に乗っている: \(path)")
        XCTAssertLessThan(path.toY, keyboard.y, "終点がキーボードの上に乗っている: \(path)")
    }

    /// キーボードが無ければ従来どおり座標を送らない(scrollFrame 未指定の既定経路は変えない)
    func testScrollActionSendsNoPathWithoutScrollFrameOrKeyboard() async throws {
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 400)])
        let step = FlowStep(action: "scroll", direction: "up", maxSwipes: 1)

        _ = await StepExecutor(driver: driver).execute(step)

        XCTAssertEqual(driver.paths.count, 1, "\(driver.paths)")
        XCTAssertNil(driver.paths[0],
                     "キーボードが無いのに座標化してはいけない(暗黙の座標化は2度撤回済み): \(driver.paths)")
    }

    // MARK: - キーボード表示中の viewport クリップ(素の action "swipe")
    //
    // scroll と同じ穴が素の swipe にもあった: `swipe(.up)` の始点はエンジン既定の固定比率で
    // 作られるため、キーボードの上を撃つと中身がほぼ動かない。executeAction の "swipe" 分岐が
    // 振る前に1回 snapshot を撮り、キーボードが立っていれば scrollPath で削った座標を送る

    func testSwipeActionUsesKeyboardClippedPathWhenKeyboardIsUp() async throws {
        let keyboard = FTRect(x: 0, y: 509, width: 390, height: 335)
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 400)], keyboardFrame: keyboard)
        let step = FlowStep(action: "swipe", direction: "up")

        _ = await StepExecutor(driver: driver).execute(step)

        XCTAssertEqual(driver.paths.count, 1, "\(driver.paths)")
        let path = try XCTUnwrap(driver.paths[0], "キーボード表示中は座標つきスワイプを送るはず")
        XCTAssertLessThan(path.fromY, keyboard.y, "始点がキーボードの上に乗っている: \(path)")
        XCTAssertGreaterThan(path.fromY, path.toY, "上スワイプは始点が終点より下のはず: \(path)")
    }

    /// キーボードが無ければ従来どおり座標を送らない(エンジン既定に委ねる。1バイトも変わらない)
    func testSwipeActionSendsNoPathWithoutKeyboard() async throws {
        let driver = PathRecordingDriver(elements: [Self.frame(anchorY: 400)])
        let step = FlowStep(action: "swipe", direction: "up")

        _ = await StepExecutor(driver: driver).execute(step)

        XCTAssertEqual(driver.paths.count, 1, "\(driver.paths)")
        XCTAssertNil(driver.paths[0],
                     "キーボードが無いのに座標化してはいけない(暗黙の座標化は2度撤回済み): \(driver.paths)")
    }

    /// `scrollNotFoundMessage` はキーボードを**1度も動かなかった回にだけ**名指しする
    /// (末尾に着いた回・キーボード無しでは既存文言を1バイトも変えない。ScrollSearchStopTests の
    /// pinned文言と両立させるための境界)
    func testNotFoundMessageNamesTheKeyboardOnlyWhenNothingEverMoved() {
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"),
                            direction: "up", maxSwipes: 8)
        let keyboard = FTRect(x: 0, y: 509, width: 390, height: 335)

        let stuckUnderKeyboard = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                                  viaXCUITest: false, hintJumps: 0,
                                                                  swipes: 3, stoppedUnmoving: true,
                                                                  contentEverMoved: false,
                                                                  keyboardFrame: keyboard)
        let message = StepExecutor.scrollNotFoundMessage(step, stuckUnderKeyboard)
        XCTAssertTrue(message.contains("the soft keyboard covers (0,509 390x335)"), message)
        XCTAssertTrue(message.contains("pass scrollFrame or close the keyboard"), message)

        let reachedEnd = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                          viaXCUITest: false, hintJumps: 0,
                                                          swipes: 3, stoppedUnmoving: true,
                                                          contentEverMoved: true,
                                                          keyboardFrame: keyboard)
        XCTAssertFalse(StepExecutor.scrollNotFoundMessage(step, reachedEnd).contains("soft keyboard"),
                       "末尾に着いた回にはキーボードを名指ししない")

        let noKeyboard = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                          viaXCUITest: false, hintJumps: 0,
                                                          swipes: 3, stoppedUnmoving: true,
                                                          contentEverMoved: false)
        XCTAssertFalse(StepExecutor.scrollNotFoundMessage(step, noKeyboard).contains("soft keyboard"),
                       "キーボードが無いのに名指ししてはいけない")
    }
}
