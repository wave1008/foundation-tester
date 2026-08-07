// 「撃つ前に言える危なさ」の共有判定。**MCP と DSL が同じ定義を使う**ことが要点。
// DSL 側は失敗にせずステップ注記へ混ぜる(無効な要素をわざと叩く書き方は正当なため)。

import XCTest
@testable import FTCore

final class TapTargetAdvisoryTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)

    private func element(_ ref: Int, _ id: String, _ type: String,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                         depth: Int = 2, enabled: Bool = true) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: enabled,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    /// 木には `disabled` と印字しているのに、操作経路は `enabled` を一度も見ていなかった
    /// (E2E-CMP の契約上「押しても何も起きない」ボタンで実測)
    func testDisabledTargetIsCalledOut() {
        let off = element(1, "btn_always_disabled", "button", 42, 1544, 309, 126, enabled: false)
        let note = TapTargetGeometry.advisory(for: off, in: [off], screen: screen)
        XCTAssertEqual(note, "the target is disabled, so this almost certainly did nothing")
    }

    /// 有効な要素では黙る(毎回付くと注記が意味を失う)
    func testEnabledPlainTargetIsSilent() {
        let on = element(1, "btn", "button", 0, 0, 100, 40)
        XCTAssertNil(TapTargetGeometry.advisory(for: on, in: [on], screen: screen))
    }

    /// 全幅の非対話コンテナで中身は右端の FAB だけ = 中心は地図の上
    /// (実測: 叩くと海上の座標にピンが落ちて place page が開いた)
    func testContainerWhoseCentreMissesItsContent() {
        let elements = [
            element(1, "map", "clickable", 0, 0, 1080, 2424),
            element(2, "layers_fab_button", "other", 0, 442, 1080, 157, depth: 4),
            element(3, "layers_fab", "image", 928, 457, 152, 142, depth: 5),
        ]
        let note = TapTargetGeometry.advisory(for: elements[1], in: elements, screen: screen)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("#layers_fab") == true, note ?? "")
        XCTAssertTrue(note?.contains("behind it") == true, note ?? "")
    }

    /// **囲っている対話要素がタップを受け止めるなら黙る**(誤検知の抑制)
    func testEnclosingInteractiveAncestorSilencesIt() {
        let elements = [
            element(1, "card", "clickable", 0, 1399, 1080, 1025),
            element(2, "business_place_card", "other", 0, 1399, 1080, 320, depth: 3),
            element(3, "title", "staticText", 42, 1462, 440, 58, depth: 4),
        ]
        XCTAssertNil(TapTargetGeometry.advisory(for: elements[1], in: elements, screen: screen))
    }

    /// **中心が画面の外**は空振りの警告になる(実測: Compose iOS のカレンダーで
    /// ヘッダ裏へ抜けた `#slot_07`(中心 y=-18)への ref タップが無警告の no-op だった)
    func testOffscreenCentreIsCalledOut() {
        let above = element(1, "slot_07", "button", 0, -46, 402, 56)
        let note = TapTargetGeometry.advisory(
            for: above, in: [above], screen: FTRect(x: 0, y: 0, width: 402, height: 874))
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("outside the visible screen") == true, note ?? "")
        XCTAssertTrue(note?.contains("(201, -18)") == true, note ?? "")
    }

    /// **縁の丸め誤差では黙る**(実測: Apple マップ下端バーの `#SubtitleLabel` は中心が
    /// screen.height を 0.3pt だけ超えるが、見えているラベルなので警告したら嘘)
    func testEdgeRoundingIsNotCalledOffscreen() {
        let edge = element(1, "SubtitleLabel", "staticText", 51, 866.8, 23, 15)
        XCTAssertNil(TapTargetGeometry.offscreenAdvisory(
            for: edge, screen: FTRect(x: 0, y: 0, width: 402, height: 874)))
    }

    /// screen が採れない(0 サイズ)ときは黙る(嘘を足さない)
    func testZeroScreenStaysSilent() {
        let e = element(1, "x", "button", -100, -100, 10, 10)
        XCTAssertNil(TapTargetGeometry.offscreenAdvisory(
            for: e, screen: FTRect(x: 0, y: 0, width: 0, height: 0)))
    }

    /// **disabled が優先**: 両方に当てはまるときは「そもそも無効」を先に言う
    func testDisabledWinsOverTheGeometricAdvice() {
        let elements = [
            element(1, "map", "clickable", 0, 0, 1080, 2424),
            element(2, "wrap", "other", 0, 442, 1080, 157, depth: 4, enabled: false),
            element(3, "inner", "image", 928, 457, 152, 142, depth: 5),
        ]
        XCTAssertEqual(TapTargetGeometry.advisory(for: elements[1], in: elements, screen: screen),
                       "the target is disabled, so this almost certainly did nothing")
    }

    // MARK: - keyboardCoveredAdvisory
    //
    // 木からは判定できない(キーボードはスナップショットの対象外)ので、ブリッジ申告の
    // keyboardFrame でだけ言える。実測(2026-08-08・iOS): キーボード下の候補行 ref タップが
    // 警告なしで顔文字キーに当たった(inputView は空葉になり、既存の空葉除外で遮蔽から漏れる)。

    /// 中心がキーボードの中 → 警告
    func testKeyboardCoveredCentreIsCalledOut() {
        let keyboard = FTRect(x: 0, y: 600, width: 402, height: 274)
        let target = element(1, "suggestion_row", "button", 16, 620, 370, 40)
        let note = TapTargetGeometry.keyboardCoveredAdvisory(target, keyboardFrame: keyboard)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("soft keyboard") == true, note ?? "")
    }

    /// 中心がキーボードの外 → 黙る
    func testCentreAboveTheKeyboardIsSilent() {
        let keyboard = FTRect(x: 0, y: 600, width: 402, height: 274)
        let target = element(1, "row", "button", 16, 400, 370, 40)
        XCTAssertNil(TapTargetGeometry.keyboardCoveredAdvisory(target, keyboardFrame: keyboard))
    }

    /// keyboardFrame が nil(旧ブリッジ・キーボード非表示)→ 黙る
    func testNoKeyboardFrameIsSilent() {
        let target = element(1, "row", "button", 16, 620, 370, 40)
        XCTAssertNil(TapTargetGeometry.keyboardCoveredAdvisory(target, keyboardFrame: nil))
    }

    // MARK: - isClippedSliver

    /// 実害形: 右端で幅9pxに切れたタブ「サンライズ瀬戸」(2026-08-08・Apple マップ)
    func testThinVerticalSliverWithLabelIsClipped() {
        var e = element(1, "tab_sunrise_seto", "tab", 1071, 100, 9, 137)
        e.label = "サンライズ瀬戸"
        XCTAssertTrue(TapTargetGeometry.isClippedSliver(e))
    }

    /// アイコン(9x13)は縦横比条件で除外される(ラベルを付けても偽)
    func testSmallIconIsNotASliver() {
        var e = element(1, "icon_close", "image", 1071, 100, 9, 13)
        e.label = "閉じる"
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e))
    }

    /// ラベル無しの細帯は「読めるテキストが切れた」ことを示せないので偽
    func testThinSliverWithoutALabelIsNotFlagged() {
        let e = element(1, "tab_unlabeled", "tab", 1071, 100, 9, 137)
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e))
    }

    /// 横帯(height<=10, width>=30)も同じ判定を通る
    func testThinHorizontalSliverWithLabelIsClipped() {
        var e = element(1, "banner_clipped", "staticText", 0, 866, 300, 8)
        e.label = "ライブ配信中"
        XCTAssertTrue(TapTargetGeometry.isClippedSliver(e))
    }
}

/// **配線のテスト**: 判定関数を単体で確かめるだけでは「DSL の tap がそれを通っているか」を
/// 検証できない(2026-08-07 に掃討ハーネスで同じ穴を踏んだ)。実際に `StepExecutor` の
/// tap を実行して、ステップ注記に載ることを固定する。
private final class AdvisoryProbeDriver: AppDriver {
    let disabled: Bool
    /// true = 中心が中身のどこにも乗らない容器を `#target` として返す(有効な要素)
    let missesContent: Bool
    /// true = 中心が画面の外にある `#target` を返す(スクロールで縁の外へ抜けた形)
    let offscreen: Bool
    /// ドライバ自身が申告する注記(InAppBridge の「activate 不発→合成タッチ」に相当)
    let driverNote: String?
    private(set) var taps = 0
    init(disabled: Bool, missesContent: Bool = false, offscreen: Bool = false,
         driverNote: String? = nil) {
        self.disabled = disabled
        self.missesContent = missesContent
        self.offscreen = offscreen
        self.driverNote = driverNote
    }
    var lastActionNote: String? { driverNote }

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
    func tap(ref: Int) async throws { taps += 1 }
    func tap(x: Double, y: Double) async throws { taps += 1 }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}
    /// **doubleTap を実装しないと**ジェスチャが失敗して早期 return し、注記の配線を通らない
    func doubleTap(x: Double, y: Double) async throws { taps += 1 }

    func snapshot() async throws -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        if offscreen {
            // スクロールで縁の外へ抜けた要素(実測の #slot_07 と同じ形)。単独で返す =
            // 兄弟が2つ無いので容器は推測されず、visibleTapRect には寄せられない経路になる
            return SnapshotResponse(
                sessionBundleID: nil, screen: screen,
                elements: [
                    ElementInfo(ref: 1, type: "button", identifier: "target", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: -46, width: 402, height: 56), depth: 2),
                ],
                truncatedCount: 0)
        }
        if missesContent {
            // 全幅の非対話コンテナ(#target)の中身は右端の小さな像だけ = 中心は背後の地図
            return SnapshotResponse(
                sessionBundleID: nil, screen: screen,
                elements: [
                    ElementInfo(ref: 1, type: "clickable", identifier: "canvas", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: screen, depth: 1),
                    ElementInfo(ref: 2, type: "other", identifier: "target", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 160, width: 402, height: 60), depth: 3),
                    ElementInfo(ref: 3, type: "image", identifier: "inner", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 350, y: 170, width: 40, height: 40), depth: 4),
                ],
                truncatedCount: 0)
        }
        return SnapshotResponse(
            sessionBundleID: nil, screen: screen,
            elements: [
                ElementInfo(ref: 1, type: "clickable", identifier: "target", label: "対象",
                            value: nil, placeholder: nil, enabled: !disabled,
                            frame: FTRect(x: 16, y: 410, width: 370, height: 56), depth: 2),
            ],
            truncatedCount: 0)
    }
}

final class TapAdvisoryWiringTests: XCTestCase {

    /// 無効な要素を叩いたら**ステップ注記に出る**(失敗にはしない)
    func testDisabledTargetSurfacesInTheStepNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))

        XCTAssertEqual(driver.taps, 1, "注記は出すが撃つのはやめない(拒否ではない)")
        if case .passed = outcome.status {} else { XCTFail("失敗にしてはいけない: \(outcome.status)") }
        XCTAssertTrue(outcome.driverFallback?.contains("disabled") == true,
                      "注記が出ていない: \(outcome.driverFallback ?? "nil")")
    }

    /// 有効な要素では注記を足さない
    func testEnabledTargetAddsNoNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        XCTAssertEqual(driver.taps, 1)
        XCTAssertNil(outcome.driverFallback, "余計な注記が付いた: \(outcome.driverFallback ?? "")")
    }

    /// **ドライバ自身の注記と共存する**。以前はここで代入していたため、
    /// activate 不発のような**まさに飲まれた場面**で「無効な要素」の注記が消えていた
    /// (2026-08-07 のレビューで発覚。上書き→合流に直した)
    func testDriverNoteDoesNotSwallowTheAdvisory() async throws {
        let driver = AdvisoryProbeDriver(disabled: true,
                                         driverNote: "activate misfired: synthesized a touch instead")
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("disabled"), "advisory が消えた: \(note)")
        XCTAssertTrue(note.contains("activate misfired"), "ドライバの注記が消えた: \(note)")
    }

    /// **doubleTap にも載る**(配線のテスト。定数 nil に差し替えると落ちること)
    func testDoubleTapCarriesTheAdvisory() async throws {
        let driver = AdvisoryProbeDriver(disabled: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "doubleTap", locator: FlowLocator(id: "target")))
        XCTAssertTrue(outcome.driverFallback?.contains("disabled") == true,
                      "doubleTap で注記が出ていない: \(outcome.driverFallback ?? "nil")")
    }

    /// **見えている部分へ寄せたときは「背後へ抜けた」と言わない**(嘘になる)。
    /// 無効かどうかは撃つ座標に依らないので、そちらは言ってよい
    func testGeometricAdviceIsPointDependentButDisabledIsNot() {
        let elements = [
            ElementInfo(ref: 1, type: "clickable", identifier: "map", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 1080, height: 2424), depth: 2),
            ElementInfo(ref: 2, type: "other", identifier: "wrap", label: nil, value: nil,
                        placeholder: nil, enabled: false,
                        frame: FTRect(x: 0, y: 442, width: 1080, height: 157), depth: 4),
            ElementInfo(ref: 3, type: "image", identifier: "inner", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 928, y: 457, width: 152, height: 142), depth: 5),
        ]
        let wrap = elements[1]
        XCTAssertNotNil(TapTargetGeometry.disabledAdvisory(for: wrap))
        XCTAssertNotNil(TapTargetGeometry.missedContentAdvisory(
            for: wrap, in: elements, screen: FTRect(x: 0, y: 0, width: 1080, height: 2424)))
        // 有効な要素なら disabled 側だけが黙る
        let on = ElementInfo(ref: 4, type: "button", identifier: "b", label: nil, value: nil,
                             placeholder: nil, enabled: true,
                             frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 2)
        XCTAssertNil(TapTargetGeometry.disabledAdvisory(for: on))
    }

    /// **画面外の中心の配線**(tap の「寄せずに中心を撃つ」経路。実測: Compose iOS の
    /// カレンダーで #slot_07 への ref タップが無警告の no-op だった)
    func testOffscreenCentreAdvisoryReachesTheStepNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false, offscreen: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        XCTAssertEqual(driver.taps, 1, "警告は出すが撃つのはやめない(拒否ではない)")
        XCTAssertTrue(outcome.driverFallback?.contains("outside the visible screen") == true,
                      "画面外の注記が出ていない: \(outcome.driverFallback ?? "nil")")
    }

    /// **中身外しの配線**(有効な要素なので disabled 側の早期 return を通らない経路)
    func testMissedContentAdvisoryReachesTheStepNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false, missesContent: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#inner"), "中身外しの注記が出ていない: \(note)")
        XCTAssertTrue(note.contains("behind it"), note)
    }
}
