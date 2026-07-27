import XCTest
@testable import FTCore

/// occlusion-guard の Tier-0 幾何ヒューリスティック(FM/スクショ非依存)の検証。
/// 特に F 修正: Compose-iOS の frame クランプで画面端に潰れた ghost スタックを occluder から除外する。
final class OcclusionSuspicionTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    private func el(_ ref: Int, _ frame: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: nil, label: "x", value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: 0)
    }

    /// 画面端に潰れた同一 frame の ghost スタック(3枚)は occluder とみなさない → 疑い無し(false)。
    func testClampGhostStackIsNotOcclusion() {
        let target = el(1, FTRect(x: 0, y: 750, width: 400, height: 40))   // 見えている最下段の行
        let ghost = FTRect(x: 0, y: 760, width: 400, height: 40)           // 画面端(y+h=800)に潰れた行
        let elements = [target, el(2, ghost), el(3, ghost), el(4, ghost)]  // 同一 frame ×3 = スタック
        XCTAssertFalse(OcclusionSuspicion.geometric(
            element: target, in: elements, screen: screen, looseMatch: false),
            "クランプ ghost スタックで偽の occlusion 疑いを立てないこと")
    }

    /// 本物の単独オーバーレイ(ユニーク frame)が重なれば従来どおり疑う(true)。検出力は維持。
    func testGenuineSingleOverlayIsOcclusion() {
        let target = el(1, FTRect(x: 0, y: 750, width: 400, height: 40))
        let overlay = el(2, FTRect(x: 0, y: 760, width: 400, height: 40))   // 重複なし
        XCTAssertTrue(OcclusionSuspicion.geometric(
            element: target, in: [target, overlay], screen: screen, looseMatch: false),
            "本物の単独オーバーレイは占有率 >= 0.4 で疑うこと")
    }

    /// 親子で frame を共有するだけの2重複は ghost 扱いしない(本物の occluder を守る・閾値3)。
    func testTwoDuplicateFramesStillOcclusion() {
        let target = el(1, FTRect(x: 0, y: 750, width: 400, height: 40))
        let shared = FTRect(x: 0, y: 760, width: 400, height: 40)
        XCTAssertTrue(OcclusionSuspicion.geometric(
            element: target, in: [target, el(2, shared), el(3, shared)], screen: screen, looseMatch: false),
            "2重複(親子共有)は除外せず疑うこと")
    }

    /// 画面端に接しない同一 frame スタックは(クランプの兆候が無いので)ghost 扱いしない。
    func testDuplicateFramesAwayFromEdgeStillOcclusion() {
        let target = el(1, FTRect(x: 50, y: 300, width: 200, height: 40))
        let mid = FTRect(x: 50, y: 305, width: 200, height: 40)            // 画面中央・端に非接触
        XCTAssertTrue(OcclusionSuspicion.geometric(
            element: target, in: [target, el(2, mid), el(3, mid), el(4, mid)], screen: screen, looseMatch: false),
            "端に接しない重複は clamp ghost ではない")
    }

    /// 部分一致(substring)ロケータは従来どおり無条件で疑う。
    func testLooseMatchAlwaysSuspicious() {
        let target = el(1, FTRect(x: 0, y: 100, width: 100, height: 20))
        XCTAssertTrue(OcclusionSuspicion.geometric(
            element: target, in: [target], screen: screen, looseMatch: true))
    }

    // MARK: - covering(誰が覆っているか)

    /// 失敗メッセージ用。**どの要素が覆っているか**まで返す(geometric は真偽だけ)
    func testCoveringReturnsTheOverlappingElement() {
        let target = el(1, FTRect(x: 0, y: 100, width: 400, height: 40))
        let overlay = el(2, FTRect(x: 0, y: 90, width: 400, height: 200))
        XCTAssertEqual(
            OcclusionSuspicion.covering(element: target, in: [target, overlay], screen: screen)?.ref, 2)
    }

    /// 重なりが閾値未満なら覆っていない扱い(geometric の判定と同じ規則を共有する)
    func testCoveringIgnoresSmallOverlap() {
        let target = el(1, FTRect(x: 0, y: 100, width: 400, height: 40))
        let grazing = el(2, FTRect(x: 0, y: 135, width: 400, height: 40))   // 5/40 = 0.125
        XCTAssertNil(OcclusionSuspicion.covering(element: target, in: [target, grazing], screen: screen))
    }

    /// 記載順で**前**にある要素は奥にいるとみなす(手前寄りだけを occluder にする)
    func testCoveringIgnoresElementsBehindTheTarget() {
        let behind = el(1, FTRect(x: 0, y: 90, width: 400, height: 200))
        let target = el(2, FTRect(x: 0, y: 100, width: 400, height: 40))
        XCTAssertNil(OcclusionSuspicion.covering(element: target, in: [behind, target], screen: screen))
    }

    /// クランプ ghost は飛ばし、本物の occluder を返す(geometric と同じ除外規則)
    func testCoveringSkipsClampGhostAndReturnsGenuineOne() {
        let target = el(1, FTRect(x: 0, y: 750, width: 400, height: 40))
        let ghost = FTRect(x: 0, y: 760, width: 400, height: 40)
        let genuine = el(5, FTRect(x: 0, y: 740, width: 400, height: 60))
        let elements = [target, el(2, ghost), el(3, ghost), el(4, ghost), genuine]
        XCTAssertEqual(
            OcclusionSuspicion.covering(element: target, in: elements, screen: screen)?.ref, 5)
    }
}
