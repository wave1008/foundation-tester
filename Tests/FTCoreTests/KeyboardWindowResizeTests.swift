// Android adjustResize でキーボード上端まで窓が縮み、覆われた要素が木から**消える**形
// (遮蔽ではなく脱落。実測 2026-09-05・Pixel 4a: パスワード欄フォーカスで窓 2340→1267px、
// 送信/クリアが木から脱落)。判定は KeyboardOcclusion.windowResizedAboveKeyboard の1箇所。

import XCTest
@testable import FTCore
import FTTestSupport

final class KeyboardWindowResizeTests: XCTestCase {

    private func element(ref: Int, type: String = "button", id: String? = nil,
                         x: Double, y: Double, w: Double, h: Double,
                         depth: Int = 2) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    /// 根の容器の下端がキーボード上端にちょうど一致し、はみ出す要素も無い形
    /// (実測: Pixel 4a・E2E-Android 入力画面 1267=1267)
    func testResolvesTrueWhenNothingSpillsPastTheKeyboardTop() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
            element(ref: 2, type: "editText", x: 100, y: 400, w: 800, h: 100, depth: 3),
            element(ref: 3, type: "other", id: "tab_bar", x: 0, y: 1135, w: 360, h: 132),
        ]
        let occlusion = KeyboardOcclusion.resolve(
            reported: FTRect(x: 0, y: 1267, width: 1080, height: 1073), in: elements)
        XCTAssertTrue(occlusion.windowResizedAboveKeyboard,
                      "根の下端がキーボード上端に一致するのに resized と判定されなかった")
    }

    /// キーボード下へはみ出す要素(送信/クリアボタン相当)が1つでもあれば false
    /// (iOS のように窓が縮まず、覆われているだけの形)
    func testResolvesFalseWhenAnElementSpillsPastTheKeyboardTop() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
            element(ref: 2, type: "editText", x: 100, y: 400, w: 800, h: 100, depth: 3),
            element(ref: 3, type: "other", id: "tab_bar", x: 0, y: 1135, w: 360, h: 132),
            element(ref: 4, type: "button", id: "btn_submit", x: 0, y: 1400, w: 360, h: 132),
        ]
        let occlusion = KeyboardOcclusion.resolve(
            reported: FTRect(x: 0, y: 1267, width: 1080, height: 1073), in: elements)
        XCTAssertFalse(occlusion.windowResizedAboveKeyboard,
                       "はみ出す要素があるのに resized と判定された")
    }

    /// 申告(keyboardFrame)が無ければ即 false(`.none` と同じ)
    func testResolvesFalseWhenThereIsNoReportedKeyboardFrame() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
        ]
        let occlusion = KeyboardOcclusion.resolve(reported: nil, in: elements)
        XCTAssertFalse(occlusion.windowResizedAboveKeyboard)
        XCTAssertEqual(occlusion.frame, KeyboardOcclusion.none.frame)
    }

    // MARK: - 固定コーパスでの発火(等号で固定。増分は1件ずつ検分すること)

    /// **witness**: `and-e2e_input_keyboard_resized`(実機 Pixel 4a・keyboardFrame y=1267・
    /// 要素19件・maxBottom 1267)/ `and-form_keyboard`(1541=1541)。それ以外の keyboardFrame 持ち
    /// (`and-maps_suggest_ime` / `and-browser_urlmenu` / `ios-*`)は、木の最下端がキーボード上端を
    /// 越えて残る(はみ出す要素がある)ので false
    func testFiresOnExactlyTheKnownWindowResizeWitnesses() throws {
        let corpus = try RealAppSnapshotCorpus.all()
        let withKeyboardFrame = corpus.filter { $0.snapshot.keyboardFrame != nil }
        XCTAssertFalse(withKeyboardFrame.isEmpty, "keyboardFrame 持ちのフィクスチャが1件も無い")
        let resized = Set(withKeyboardFrame.filter {
            KeyboardOcclusion.resolve(reported: $0.snapshot.keyboardFrame,
                                      in: $0.snapshot.elements).windowResizedAboveKeyboard
        }.map(\.name))
        XCTAssertEqual(resized, ["and-e2e_input_keyboard_resized", "and-form_keyboard"],
                       "窓の縮みで resized と判定される画面の集合が変わった。増分を1件ずつ検分すること")
    }

    // MARK: - DSL の失敗文言(keyboardResizedHint)

    private func snapshot(elements: [ElementInfo], keyboardFrame: FTRect?) -> SnapshotResponse {
        var snap = SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 1080, height: 2340),
                                    elements: elements, truncatedCount: 0)
        snap.keyboardFrame = keyboardFrame
        return snap
    }

    func testKeyboardResizedHintDescribesTheShrunkWindowWithCoordinates() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
            element(ref: 3, type: "other", id: "tab_bar", x: 0, y: 1135, w: 360, h: 132),
        ]
        let snap = snapshot(elements: elements,
                            keyboardFrame: FTRect(x: 0, y: 1267, width: 1080, height: 1073))
        let hint = StepExecutor.keyboardResizedHint(snap)
        XCTAssertTrue(hint.contains("(0,1267 1080x1073)"), "座標が実効矩形のままであること: \(hint)")
        XCTAssertTrue(hint.contains("gone from the tree"), "脱落の事実を言うこと: \(hint)")
    }

    func testKeyboardResizedHintIsEmptyWhenTheWindowHasNotResized() {
        let elements = [
            element(ref: 1, type: "other", id: "root", x: 0, y: 136, w: 1080, h: 1131),
            element(ref: 4, type: "button", id: "btn_submit", x: 0, y: 1400, w: 360, h: 132),
        ]
        let snap = snapshot(elements: elements,
                            keyboardFrame: FTRect(x: 0, y: 1267, width: 1080, height: 1073))
        XCTAssertEqual(StepExecutor.keyboardResizedHint(snap), "")
    }

    func testKeyboardResizedHintIsEmptyWithoutASnapshot() {
        XCTAssertEqual(StepExecutor.keyboardResizedHint(nil), "")
    }
}
