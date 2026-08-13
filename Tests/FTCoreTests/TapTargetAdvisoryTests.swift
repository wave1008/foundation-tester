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

    /// **ホイールピッカーは何も覆わない**(2026-08-12 の実アプリ監査)。`pickerWheel` は
    /// 回転ドラムの content 全長を frame に出すので入れ物を上下にはみ出す ——
    /// 実測(Apple マップの経路オプション・iOS 27 Simulator): `datePicker`
    /// (41,246.7 320x216) の中のホイールが (81,209.2 133x291) で、その上に並ぶ
    /// セグメント「今すぐ出発」(26,204.3 116x32) の中心 (84,220.3) を覆っていた。
    /// 実際のタップは通る(同日 ft_batch で実測)ので純粋な誤検知。
    ///
    /// **並び順はフィクスチャ ios-maps_route_options のまま**にしてある —— ホイールを
    /// セグメントの直後に置くと `lineage` が子孫として除外してしまい、
    /// 「修正が効いた」のか「候補にすら上がらなかった」のか区別できないテストになる
    func testPickerWheelDoesNotOccludeTheSegmentAboveIt() {
        let segment = element(13, "OptionLabel", "button", 26, 204.33, 116, 32, depth: 17)
        let elements = [
            segment,
            element(14, "OptionLabel", "button", 142, 204.33, 117, 32, depth: 17),
            element(16, "", "clickable", 16, 246.67, 370, 216, depth: 11),
            element(18, "", "datePicker", 41, 246.67, 320, 216, depth: 16),
            element(19, "", "pickerWheel", 81, 209.17, 133, 291, depth: 18),
        ]
        XCTAssertNil(OcclusionGeometry.overlayCovering(segment, in: elements, screen: screen),
                     "ホイールの申告 frame は描画範囲ではないので遮蔽と言わないこと")
        XCTAssertNil(TapTargetGeometry.advisory(for: segment, in: elements, screen: screen))
    }

    /// **入れ物ごと外したのではない**ことの対照: ピッカーの器そのものが中心を覆うなら
    /// 従来どおり名指しする。これが黙ると「ピッカーが下の入力欄を覆っている」本物の形を落とす
    func testTheEnclosingPickerContainerStillOccludes() {
        let field = element(13, "field", "button", 60, 300, 116, 32, depth: 17)
        let elements = [
            field,
            element(18, "", "datePicker", 41, 246.67, 320, 216, depth: 17),
        ]
        let hit = OcclusionGeometry.overlayCovering(field, in: elements, screen: screen)
        XCTAssertEqual(hit?.ref, 18, "ホイールでなく器が覆っているなら名指しすること")
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

    // MARK: - occlusionAdvisory(座標に依るチェーン。MCP の RefGuard.overlapWarning と同じ優先順)

    func testZeroWidthFrameIsCalledOutByChain() {
        let e = element(1, "z", "button", 100, 100, 0, 40)
        let note = TapTargetGeometry.occlusionAdvisory(for: e, in: [e], screen: screen)
        XCTAssertTrue(note?.contains("zero width/height") == true, note ?? "")
    }

    func testZeroHeightFrameIsCalledOutByChain() {
        let e = element(1, "z", "button", 100, 100, 40, 0)
        let note = TapTargetGeometry.occlusionAdvisory(for: e, in: [e], screen: screen)
        XCTAssertTrue(note?.contains("zero width/height") == true, note ?? "")
    }

    /// 実測形と同じ nav_heal / tab_controls(OcclusionGeometry.overlayCovering の doc 参照)
    func testOverlayCoveringIsCalledOutByChain() {
        let target = ElementInfo(ref: 1, type: "clickable", identifier: "nav_heal", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 16, y: 788, width: 370, height: 62), depth: 2)
        let overlay = ElementInfo(ref: 2, type: "clickable", identifier: "tab_controls", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 134, y: 778, width: 134, height: 62), depth: 2)
        let note = TapTargetGeometry.occlusionAdvisory(for: target, in: [target, overlay], screen: screen)
        XCTAssertTrue(note?.contains("#tab_controls") == true, note ?? "")
        XCTAssertTrue(note?.contains("instead") == true, note ?? "")
    }

    /// 対話的な親の子孫が中心を横取りする形(`nestedActionCoveringCentre` の doc 参照)
    func testNestedActionIsCalledOutByChain() {
        let parent = ElementInfo(ref: 1, type: "cell", identifier: "row", label: nil, value: nil,
                                 placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 2)
        let child = ElementInfo(ref: 2, type: "button", identifier: "chip", label: nil, value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 40, y: 40, width: 20, height: 20), depth: 3)
        let note = TapTargetGeometry.occlusionAdvisory(for: parent, in: [parent, child], screen: screen)
        XCTAssertTrue(note?.contains("#chip") == true, note ?? "")
        XCTAssertTrue(note?.contains("instead") == true, note ?? "")
    }

    /// 同一矩形に3件以上積まれた要素(`OcclusionGeometry.stackedRefs` の doc 参照)。
    /// 「other」型で子孫を持たないので missedContent/nested には掛からず、stacked だけが発火する
    func testStackedFramesAreCalledOutByChain() {
        func stacked(_ ref: Int, _ label: String) -> ElementInfo {
            ElementInfo(ref: ref, type: "other", identifier: "poi", label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 300, y: 300, width: 30, height: 30), depth: 1)
        }
        let elements = (0..<3).map { stacked($0 + 1, "STACK\($0)") }
        let note = TapTargetGeometry.occlusionAdvisory(for: elements[0], in: elements, screen: screen)
        XCTAssertTrue(note?.contains("clamped leftovers") == true, note ?? "")
    }

    /// 実害形と同じ細帯(`isClippedSliver` のテスト群と同じ要素)がチェーン経由でも出る
    func testSliverIsCalledOutByChain() {
        var e = element(1, "tab_sunrise_seto", "tab", 1071, 100, 9, 137)
        e.label = "サンライズ瀬戸"
        let note = TapTargetGeometry.occlusionAdvisory(for: e, in: [e], screen: screen)
        XCTAssertTrue(note?.contains("sliver") == true, note ?? "")
    }

    /// **優先順**: 画面外と遮蔽が両方成り立つ形で、画面外(強い事実)だけが出る
    func testOffscreenBeatsOverlayInThePriorityChain() {
        let target = ElementInfo(ref: 1, type: "clickable", identifier: "target", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: -46, width: 402, height: 56), depth: 2)
        // 中心 (201, -18) を覆う候補(画面外チェックより先に評価されたら誤って発火する)
        let overlay = ElementInfo(ref: 2, type: "clickable", identifier: "overlay", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: -60, width: 250, height: 80), depth: 2)
        let smallScreen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let note = TapTargetGeometry.occlusionAdvisory(
            for: target, in: [target, overlay], screen: smallScreen)
        XCTAssertTrue(note?.contains("outside the visible screen") == true, note ?? "")
        XCTAssertFalse(note?.contains("covered by") == true, note ?? "")
    }

    /// **優先順**: 容器外送出と遮蔽が両方成り立つ形で、容器外(frame が古い = 遮蔽の名指しも
    /// 嘘になる)だけが出る
    func testScrolledOutBeatsOverlayInThePriorityChain() {
        let smallScreen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let scroller = ElementInfo(ref: 1, type: "other", identifier: "scroller", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 100, width: 402, height: 600), depth: 1,
                                   scrollable: true)
        let rowA = ElementInfo(ref: 2, type: "clickable", identifier: "row_a", label: "行A",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: 110, width: 370, height: 20), depth: 2)
        let rowB = ElementInfo(ref: 3, type: "clickable", identifier: "row_b", label: "行B",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: 160, width: 370, height: 20), depth: 2)
        let target = ElementInfo(ref: 4, type: "clickable", identifier: "target", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 750, width: 370, height: 20), depth: 2)
        // 中心 (195, 760) を覆う候補(容器外チェックより先に評価されたら誤って発火する)
        let overlay = ElementInfo(ref: 5, type: "clickable", identifier: "overlay", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 740, width: 300, height: 60), depth: 2)
        let elements = [scroller, rowA, rowB, target, overlay]
        let note = TapTargetGeometry.occlusionAdvisory(for: target, in: elements, screen: smallScreen)
        XCTAssertTrue(note?.contains("leftover from scrolling") == true, note ?? "")
        XCTAssertFalse(note?.contains("covered by") == true, note ?? "")
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
        XCTAssertTrue(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// アイコン(9x13)は縦横比条件で除外される(ラベルを付けても偽)
    func testSmallIconIsNotASliver() {
        var e = element(1, "icon_close", "image", 1071, 100, 9, 13)
        e.label = "閉じる"
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// ラベル無しの細帯は「読めるテキストが切れた」ことを示せないので偽
    func testThinSliverWithoutALabelIsNotFlagged() {
        let e = element(1, "tab_unlabeled", "tab", 1071, 100, 9, 137)
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// 横帯(height<=10, width>=30)も同じ判定を通る
    func testThinHorizontalSliverWithLabelIsClipped() {
        var e = element(1, "banner_clipped", "staticText", 0, 866, 300, 8)
        e.label = "ライブ配信中"
        XCTAssertTrue(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// 実害形: 画面端に接した幅12px(素の閾値10は取りこぼす。実測: Google マップの
    /// モードタブ「2 時間 26」(1068,449 12x59)、画面幅1080)
    func testEdgeFlushWidth12IsClipped() {
        var e = element(1, "mode_tab", "tab", 1068, 449, 12, 59)
        e.label = "2 時間 26"
        XCTAssertTrue(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// 同じ幅12でも画面端に接していなければ「デザイン上細いだけ」の可能性を排せないので偽
    func testWidth12NotAtEdgeIsNotFlagged() {
        var e = element(1, "mode_tab", "tab", 500, 449, 12, 59)
        e.label = "2 時間 26"
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e, screen: screen))
    }

    /// 画面端でも edgeSliverThinDimension(14)を超える幅20は誤検知を避けるため偽
    func testEdgeFlushWidth20IsNotFlagged() {
        var e = element(1, "mode_tab", "tab", 1060, 449, 20, 59)
        e.label = "2 時間 26"
        XCTAssertFalse(TapTargetGeometry.isClippedSliver(e, screen: screen))
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
    /// T7: type の既存値注記テスト用。非 nil なら `#target` の value に載せる
    /// (secure=true なら型を secureTextField にして伏せ字経路を通す)
    let existingValue: String?
    let secure: Bool
    private(set) var taps = 0
    init(disabled: Bool, missesContent: Bool = false, offscreen: Bool = false,
         driverNote: String? = nil, existingValue: String? = nil, secure: Bool = false) {
        self.disabled = disabled
        self.missesContent = missesContent
        self.offscreen = offscreen
        self.driverNote = driverNote
        self.existingValue = existingValue
        self.secure = secure
    }
    var lastActionNote: String? { driverNote }
    /// このフェイクは T7(既存値注記)の配線だけを見る。snapshot() が固定値を返すので、
    /// 既定 false のままだと type 読み返しが「値が変わらない」と誤認して 8s 後に失敗する
    var verifiesTypedText: Bool { true }

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
                ElementInfo(ref: 1,
                            type: secure ? "secureTextField" : (existingValue != nil ? "textField" : "clickable"),
                            identifier: "target", label: "対象",
                            value: existingValue, placeholder: nil, enabled: !disabled,
                            frame: FTRect(x: 16, y: 410, width: 370, height: 56), depth: 2),
            ],
            truncatedCount: 0)
    }
}

/// **新チェーンの配線テスト専用ドライバ**: 固定の SnapshotResponse をそのまま返すだけ
/// (AdvisoryProbeDriver の分岐では表現しにくい複数要素の木を組むため)
private final class FixedSnapshotDriver: AppDriver {
    let response: SnapshotResponse
    private(set) var taps = 0
    private(set) var presses = 0
    private(set) var doubleTaps = 0
    init(_ response: SnapshotResponse) { self.response = response }
    var lastActionNote: String? { nil }

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
    func press(ref: Int, duration: Double) async throws { presses += 1 }
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {}
    func doubleTap(x: Double, y: Double) async throws { doubleTaps += 1 }
    func snapshot() async throws -> SnapshotResponse { response }
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

    // MARK: - 新チェーン(occlusionAdvisory)の配線: tap / 長押し / doubleTap

    private func overlayCoveringSnapshot() -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let target = ElementInfo(ref: 1, type: "clickable", identifier: "target", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 16, y: 788, width: 370, height: 62), depth: 2)
        let overlay = ElementInfo(ref: 2, type: "clickable", identifier: "overlay", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 134, y: 778, width: 134, height: 62), depth: 2)
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [target, overlay], truncatedCount: 0)
    }

    private func scrolledOutSnapshot() -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let scroller = ElementInfo(ref: 1, type: "other", identifier: "scroller", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 100, width: 402, height: 600), depth: 1,
                                   scrollable: true)
        let rowA = ElementInfo(ref: 2, type: "clickable", identifier: "row_a", label: "行A",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: 110, width: 370, height: 20), depth: 2)
        let rowB = ElementInfo(ref: 3, type: "clickable", identifier: "row_b", label: "行B",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 10, y: 160, width: 370, height: 20), depth: 2)
        let target = ElementInfo(ref: 4, type: "clickable", identifier: "target", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 10, y: 750, width: 370, height: 20), depth: 2)
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [scroller, rowA, rowB, target], truncatedCount: 0)
    }

    /// **視界の縁に半分だけ乗った要素**(visibleTapRect 経路。ClampedCoordinateTests の
    /// `testThinSliverIsNotTapped` の「real」形と同じ構成)。`phantom` は raw frame の中心を覆う
    /// 候補で、もし新チェーンが呼ばれてしまえば overlayCovering として発火するはずの罠
    private func clippedStraddleSnapshot() -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let container = ElementInfo(ref: 1, type: "other", identifier: "list", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: 230, width: 370, height: 462), depth: 11)
        let target = ElementInfo(ref: 2, type: "clickable", identifier: "target", label: "行",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 16, y: 206, width: 370, height: 38), depth: 12)
        let inside1 = ElementInfo(ref: 3, type: "clickable", identifier: "row3", label: "行",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 16, y: 300, width: 370, height: 56), depth: 12)
        let inside2 = ElementInfo(ref: 4, type: "clickable", identifier: "row4", label: "行",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 16, y: 360, width: 370, height: 56), depth: 12)
        let phantom = ElementInfo(ref: 5, type: "clickable", identifier: "phantom", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 100, y: 200, width: 200, height: 50), depth: 12)
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [container, target, inside1, inside2, phantom],
                                truncatedCount: 0)
    }

    /// 素の tap で overlayCovering が注記に出る
    func testTapCarriesOverlayCoveringAdvisory() async throws {
        let driver = FixedSnapshotDriver(overlayCoveringSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#overlay"), "overlayCovering の注記が出ていない: \(note)")
        XCTAssertTrue(note.contains("instead"), note)
    }

    /// 素の tap で scrolledOut が注記に出る
    func testTapCarriesScrolledOutAdvisory() async throws {
        let driver = FixedSnapshotDriver(scrolledOutSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#scroller"), "scrolledOut の注記が出ていない: \(note)")
        XCTAssertTrue(note.contains("leftover from scrolling"), note)
    }

    /// 長押し(hold>0 = press(ref:) 経路)でも新チェーンが出る
    func testLongPressCarriesOverlayCoveringAdvisory() async throws {
        let driver = FixedSnapshotDriver(overlayCoveringSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target"), duration: 0.5))
        XCTAssertEqual(driver.presses, 1, "長押しは press(ref:) 経路を通るはず")
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#overlay"), "長押しで overlayCovering の注記が出ていない: \(note)")
    }

    /// doubleTap(advisory() 経由)でも scrolledOut が出る
    func testDoubleTapCarriesScrolledOutAdvisory() async throws {
        let driver = FixedSnapshotDriver(scrolledOutSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "doubleTap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("#scroller"), "doubleTap で scrolledOut の注記が出ていない: \(note)")
    }

    /// **visibleTapRect で寄せた経路では新チェーンを出さない**(撃つ点が変わるので、
    /// raw frame の中心を前提にした遮蔽の名指しは嘘になる)
    func testVisibleTapRectPathDoesNotCarryTheChain() async throws {
        let driver = FixedSnapshotDriver(clippedStraddleSnapshot())
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "target")))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("tapped the visible part"), "寄せた注記が出ていない: \(note)")
        XCTAssertFalse(note.contains("covered by"), "寄せた経路で新チェーンが出てはいけない: \(note)")
        XCTAssertFalse(note.contains("outside the visible screen"), note)
    }

    // MARK: - T7: type の既存値注記

    /// 通常欄: **撃つ前に入っていた値だけ**をエコーする。連結後の値は予告しない(2026-08-13)——
    /// ここでは読み返さないので観測していない値であり、ヒント文字列を `value` に載せる欄
    /// (E2E-CMP の `#field_single` が witness)では外れる。詳細は StepExecutor.readbackTarget
    func testTypeEchoesExistingValueInTheNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false, existingValue: "東京タワー")
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "type", locator: FlowLocator(id: "target"), text: "レストラン"))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("東京タワー"), note)
        XCTAssertFalse(note.contains("東京タワーレストラン"),
                       "観測していない連結後の値を予告している: \(note)")
    }

    /// secureTextField: 既存値の中身は出さず、あることだけを言う
    func testTypeMasksExistingValueForSecureField() async throws {
        let driver = AdvisoryProbeDriver(disabled: false, existingValue: "s3cr3t", secure: true)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "type", locator: FlowLocator(id: "target"), text: "more"))
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("already holds a value"), note)
        XCTAssertFalse(note.contains("s3cr3t"), "秘匿欄の実値が漏れている: \(note)")
    }

    /// 空値なら注記を足さない(毎回付くと意味を失う)
    func testTypeWithNoExistingValueAddsNoNote() async throws {
        let driver = AdvisoryProbeDriver(disabled: false)
        let outcome = await StepExecutor(driver: driver)
            .execute(FlowStep(action: "type", locator: FlowLocator(id: "target"), text: "hello"))
        XCTAssertNil(outcome.driverFallback, "空値なのに注記が付いた: \(outcome.driverFallback ?? "")")
    }
}
