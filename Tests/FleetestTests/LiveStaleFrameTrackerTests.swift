import XCTest
import FTCore
@testable import fleetest

/// LIVE-3: LiveStaleFrameTracker は FTCore.StaleFrameDetector を呼ぶだけの薄い保持役
/// (serve は1プロセスが1台を見続けるので、直前の1記録だけで足りる)。判定そのもの
/// (画像ハッシュ×木指紋)は Tests/FTCoreTests/StaleFrameDetectorTests.swift が固定するので、
/// ここでは「記録を1つ保持し、呼ぶたびに更新すること」「stale のときだけ注記を1件返すこと」を
/// 確かめる。emitObservation/emitFrame からの配線は ApiLiveStaleFrameWiringTests が縛る。
final class LiveStaleFrameTrackerTests: XCTestCase {
    private func element(label: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: nil, label: label, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
    }

    private let pngA = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
    private let pngB = Data([0x89, 0x50, 0x4E, 0x47, 0x02])

    /// 初回は比較材料(previous)が無いので、木がどうであれ注記は出ない
    func testFirstObservationNeverProducesANote() async {
        let tracker = LiveStaleFrameTracker()
        let notes = await tracker.staleNotes(png: pngA, elements: [element(label: "A")])
        XCTAssertTrue(notes.isEmpty)
    }

    /// 画像はバイト同一なのに木が変わった → stale の注記が1件出る(凍結フレームの証拠)
    func testByteIdenticalImageWithChangedTreeProducesOneNote() async {
        let tracker = LiveStaleFrameTracker()
        _ = await tracker.staleNotes(png: pngA, elements: [element(label: "A")])
        let notes = await tracker.staleNotes(png: pngA, elements: [element(label: "B")])
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("stale"), notes[0])
    }

    /// 画像も変わっていれば通常の画面遷移(木も変わっていて当然)なので注記を出さない
    func testChangedImageIsNeverFlaggedRegardlessOfTree() async {
        let tracker = LiveStaleFrameTracker()
        _ = await tracker.staleNotes(png: pngA, elements: [element(label: "A")])
        let notes = await tracker.staleNotes(png: pngB, elements: [element(label: "B")])
        XCTAssertTrue(notes.isEmpty)
    }

    /// **記録は毎回更新される契約**: 同じ凍結フレームへ2回連続で問い合わせても、注記が出るのは
    /// 最初の1回だけ(StaleFrameDetector.judge のドキュメント参照。ここで更新を止めると、
    /// 静止画面を撮り続けるだけの通常の観測まで毎回 stale と言い続けることになる)
    func testTheSameFrozenFrameIsFlaggedOnlyOnce() async {
        let tracker = LiveStaleFrameTracker()
        _ = await tracker.staleNotes(png: pngA, elements: [element(label: "A")])
        let first = await tracker.staleNotes(png: pngA, elements: [element(label: "B")])
        XCTAssertFalse(first.isEmpty)
        let second = await tracker.staleNotes(png: pngA, elements: [element(label: "B")])
        XCTAssertTrue(second.isEmpty, "同じ木・同じ絵をもう一度渡しても記録は既に更新済み")
    }
}
