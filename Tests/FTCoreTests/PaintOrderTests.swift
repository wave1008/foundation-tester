// 塗り順の共有判定。**MCP(RefGuard)と DSL(OcclusionSuspicion)が同じ答えを出す**ことが要点で、
// 別々に持つと同じ画面で遮蔽の判定が食い違う。

import XCTest
@testable import FTCore

final class PaintOrderTests: XCTestCase {

    private func element(_ ref: Int, _ id: String, _ x: Double, _ y: Double,
                         _ w: Double, _ h: Double, z: Int? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 2, z: z)
    }

    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2424)

    /// **z があるときは z を信じる**。ツリー順とは逆になる形が production に実在する
    /// (Google マップは地図の chrome をシートより後に出すが、描画はシートが手前)
    func testPaintOrderBeatsTreeOrderWhenReported() {
        let sheet = element(17, "sheet", 0, 408, 1080, 1796, z: 76)
        let chrome = element(88, "chrome", 881, 1075, 199, 186, z: 17)
        XCTAssertTrue(chrome.ref > sheet.ref, "ツリー順では chrome が後")
        XCTAssertTrue(PaintOrder.drawnAbove(sheet, chrome), "塗り順ではシートが手前")
        XCTAssertFalse(PaintOrder.drawnAbove(chrome, sheet))
    }

    /// z を申告しないエンジン(iOS)では従来どおりツリー順
    func testFallsBackToTreeOrderWithoutZ() {
        let behind = element(5, "a", 0, 0, 10, 10)
        let front = element(9, "b", 0, 0, 10, 10)
        XCTAssertTrue(PaintOrder.drawnAbove(front, behind))
        XCTAssertFalse(PaintOrder.drawnAbove(behind, front))
    }

    /// **片方だけ z を持つ木では比べない**(打ち切りや別ブリッジの混在で大小が無意味になる)
    func testMixedTreesFallBackToTreeOrder() {
        let known = element(3, "a", 0, 0, 10, 10, z: 999)
        let unknown = element(5, "b", 0, 0, 10, 10)
        XCTAssertFalse(PaintOrder.drawnAbove(known, unknown), "ref 順では 3 < 5")
        XCTAssertTrue(PaintOrder.drawnAbove(unknown, known))
    }

    func testIsReportedNeedsEveryElement() {
        XCTAssertTrue(PaintOrder.isReported(in: [element(1, "a", 0, 0, 1, 1, z: 0)]))
        XCTAssertFalse(PaintOrder.isReported(in: [element(1, "a", 0, 0, 1, 1, z: 0),
                                                  element(2, "b", 0, 0, 1, 1)]))
        XCTAssertFalse(PaintOrder.isReported(in: []))
    }

    /// **DSL の遮蔽疑いも塗り順に従う**: ツリー順ではシートが「奥」なので拾えなかった形
    /// (地図 chrome がシートの裏に隠れる)を、z があれば拾う
    func testOcclusionSuspicionUsesPaintOrder() {
        let chrome = element(88, "chrome", 881, 1075, 199, 186, z: 17)
        let sheet = element(17, "sheet", 0, 408, 1080, 1796, z: 76)
        let withZ = [sheet, chrome]
        XCTAssertEqual(OcclusionSuspicion.covering(element: chrome, in: withZ,
                                                   screen: screen)?.identifier, "sheet")
        // z が無ければ従来どおり(ツリー順では sheet が先 = 奥とみなす)= 拾えない
        let noZ = [element(17, "sheet", 0, 408, 1080, 1796),
                   element(88, "chrome", 881, 1075, 199, 186)]
        XCTAssertNil(OcclusionSuspicion.covering(element: noZ[1], in: noZ, screen: screen))
    }
}

/// **失敗メッセージの「何に覆われているか」も塗り順に従う**。`coveringHint` は FM ゲートの外に
/// あるので、FM が無効な環境でも実行される —— つまりシナリオ実行の失敗文言に直接効く。
/// 緑の run では1度も実行されない経路なので、実アプリのスナップショットで陽性対照を固定する。
final class CoveringHintPaintOrderTests: XCTestCase {

    func testFailureHintNamesTheSheetThatTreeOrderMissed() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots/and-place_expanded.json")
        let snap = try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
        let target = try XCTUnwrap(snap.elements.first { $0.identifier == "mylocation_button" })
        // ツリー順ではシート(ref 17)が地図 chrome(ref 88)より前 = 「奥」に見えるので拾えなかった
        XCTAssertTrue(target.ref > 17)
        let hint = StepExecutor.coveringHint(element: target, elements: snap.elements,
                                             screen: snap.screen)
        XCTAssertTrue(hint.contains("#place_page_tabs_container"), hint)
        XCTAssertTrue(hint.contains("covered by"), hint)
    }
}
