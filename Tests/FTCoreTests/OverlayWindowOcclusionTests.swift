// **木に出ないオーバーレイ・ウィンドウ**による遮蔽の判定。witness は実機 Pixel 4a の
// Chrome(2026-08-28): テキスト選択のフローティングツールバー(実測 x 96..1046 / y 251..375)が
// 段落 (22,136 1036x266) の中心 (540,269) を覆っている状態で、ref タップが無警告の "done" を
// 返し、実際には「Select all」に当たってページ全体が選択された。

import XCTest
@testable import FTCore

final class OverlayWindowOcclusionTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2340)

    /// 実機で採った実寸(上のコメント)。**production の定数から作らない**
    private let toolbar = FTRect(x: 96, y: 251, width: 950, height: 124)

    private func element(_ ref: Int, _ id: String,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: id, label: "para", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 2)
    }

    /// 実機 witness そのもの: 段落の中心がツールバーの下にある
    func testCentreUnderTheDeclaredOverlayIsCalledOut() {
        let para = element(1, "content", 22, 136, 1036, 266)
        let occlusion = OverlayWindowOcclusion.resolve(reported: [toolbar])
        XCTAssertEqual(occlusion.covering(para), toolbar)
        let note = occlusion.advisory(for: para)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("(540, 269)") == true, note ?? "")
        XCTAssertTrue(note?.contains("overlay window") == true, note ?? "")
    }

    /// **縁に触れているだけでは言わない**。ツールバーの直下に続く段落は見えていて押せるので、
    /// ここで警告すると実機の通常操作が毎回濁る
    func testElementBelowTheOverlayStaysSilent() {
        let below = element(2, "next", 22, 400, 1036, 398)   // 中心 y=599 > 375
        let occlusion = OverlayWindowOcclusion.resolve(reported: [toolbar])
        XCTAssertNil(occlusion.covering(below))
        XCTAssertNil(occlusion.advisory(for: below))
    }

    /// 実機の実測どおり、**重なってはいるが中心は外**の形でも黙る(部分的な重なりで撃つと
    /// 当たるのは要素のほう)。witness: ツールバー y 710..841 と段落 (22,732 1036x333)・中心 898
    func testPartialOverlapWithTheCentreOutsideStaysSilent() {
        let para = element(3, "content", 22, 732, 1036, 333)
        let band = FTRect(x: 96, y: 710, width: 950, height: 131)
        XCTAssertNil(OverlayWindowOcclusion.resolve(reported: [band]).covering(para))
    }

    /// 申告が無い経路(iOS・旧ブリッジ)は `.none` に落ちて従来動作のまま
    func testNoDeclarationDegradesToSilence() {
        let para = element(1, "content", 22, 136, 1036, 266)
        XCTAssertNil(OverlayWindowOcclusion.resolve(reported: nil).advisory(for: para))
        XCTAssertNil(OverlayWindowOcclusion.resolve(reported: []).advisory(for: para))
        // 退化した矩形は捨てる(幅か高さが 0 の申告で全要素が「覆われている」にならないこと)
        // **フィルタが無ければ中心に当たる形にする** —— 中心を外した矩形だと、フィルタを
        // 外す変異を1つも殺せない(2026-08-28 の変異チェックで実際に生き残った)
        let degenerate = FTRect(x: 540, y: 0, width: 0, height: 2340)
        XCTAssertNil(OverlayWindowOcclusion.resolve(reported: [degenerate]).advisory(for: para))
    }

    /// 複数申告のうち**中心を含むもの**を選ぶ(最初の1枚ではない)
    func testPicksTheFrameThatActuallyContainsTheCentre() {
        let para = element(1, "content", 22, 136, 1036, 266)          // 中心 (540, 269)
        let sheet = FTRect(x: 0, y: 2075, width: 1080, height: 225)   // 下端のボトムシート
        let occlusion = OverlayWindowOcclusion.resolve(reported: [sheet, toolbar])
        XCTAssertEqual(occlusion.covering(para), toolbar)
    }

    /// **全画面のオーバーレイでも黙らない** —— 木が丸ごと後ろに居る最も危険な形なので、
    /// 面積で足切りしていないこと
    func testFullScreenOverlayStillWarns() {
        let para = element(1, "content", 22, 136, 1036, 266)
        XCTAssertNotNil(OverlayWindowOcclusion.resolve(reported: [screen]).advisory(for: para))
    }

    /// 申告由来の2つ(キーボード・オーバーレイ)は**木由来の警告より先**に出る。
    /// 覆っている実体が elements に載っていないので確度が最も高い
    func testDeclaredOverlayOutranksTreeDerivedAdvisories() {
        let para = element(1, "content", 22, 136, 1036, 266)
        let note = TapTargetGeometry.advisory(
            for: para, in: [para], screen: screen,
            keyboardOcclusion: .none,
            overlayWindows: OverlayWindowOcclusion.resolve(reported: [toolbar]), isAndroid: false)
        XCTAssertTrue(note?.contains("overlay window") == true, note ?? "")
    }

    /// **Java と Swift をまたぐキー名の一致**。Codable の合成だけに任せると、どちらか片方の
    /// 改名が黙って通り「ブリッジは申告しているのにホストでは永久に nil」になる
    /// (型検査の効かない境界は往復で縛る)
    func testDecodesTheKeyTheAndroidBridgeWrites() throws {
        let json = #"{"screen":{"x":0,"y":0,"width":1080,"height":2340},"elements":[],"#
            + #""truncatedCount":0,"overlayWindowFrames":"#
            + #"[{"x":96,"y":251,"width":950,"height":124}]}"#
        let decoded = try JSONDecoder().decode(SnapshotResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.overlayWindowFrames, [toolbar])
        // 申告が無い応答は nil のまま(既存のブリッジと同じ形)
        let bare = #"{"screen":{"x":0,"y":0,"width":1080,"height":2340},"#
            + #""elements":[],"truncatedCount":0}"#
        XCTAssertNil(try JSONDecoder().decode(SnapshotResponse.self,
                                              from: Data(bare.utf8)).overlayWindowFrames)
    }

    /// キーボードが先(より具体的な逃げ道を書ける)。申告は互いに素
    /// (ブリッジは TYPE_INPUT_METHOD を overlayWindowFrames に入れない)だが、
    /// 万一重なっても順序が揺れないことを固定する
    func testKeyboardIsAnnouncedBeforeTheGenericOverlay() {
        let para = element(1, "content", 22, 136, 1036, 266)
        let note = TapTargetGeometry.advisory(
            for: para, in: [para], screen: screen,
            keyboardOcclusion: KeyboardOcclusion.resolve(reported: toolbar, in: [para]),
            overlayWindows: OverlayWindowOcclusion.resolve(reported: [toolbar]), isAndroid: false)
        XCTAssertTrue(note?.contains("soft keyboard") == true, note ?? "")
    }
}
