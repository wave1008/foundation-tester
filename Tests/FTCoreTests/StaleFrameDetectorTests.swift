// StaleFrameDetector の純ロジック(画像ハッシュ×木指紋)を検証する。デバイスに触れない。

import XCTest
@testable import FTCore

final class StaleFrameDetectorTests: XCTestCase {
    private func element(ref: Int = 1, label: String = "こんにちは") -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: nil, label: label, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
    }

    private let pngA = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
    private let pngB = Data([0x89, 0x50, 0x4E, 0x47, 0x02])

    /// 画像・木ともに不変 → not stale
    func testUnchangedImageAndTreeIsNotStale() {
        let baseline = StaleFrameDetector.judge(png: pngA, elements: [element()], previous: nil).record
        let result = StaleFrameDetector.judge(png: pngA, elements: [element()], previous: baseline)
        XCTAssertFalse(result.isStale)
    }

    /// 画像はバイト同一なのに木が変わった → stale(凍結フレームの証拠)
    func testByteIdenticalImageWithChangedTreeIsStale() {
        let baseline = StaleFrameDetector.judge(png: pngA, elements: [element(label: "A")],
                                                previous: nil).record
        let result = StaleFrameDetector.judge(png: pngA, elements: [element(label: "B")],
                                              previous: baseline)
        XCTAssertTrue(result.isStale)
    }

    /// 画像が変わっていれば、木も変わっていても stale ではない(通常の画面遷移)
    func testChangedImageIsNeverStaleRegardlessOfTree() {
        let baseline = StaleFrameDetector.judge(png: pngA, elements: [element(label: "A")],
                                                previous: nil).record
        let result = StaleFrameDetector.judge(png: pngB, elements: [element(label: "B")],
                                              previous: baseline)
        XCTAssertFalse(result.isStale)
    }

    /// **record は常に最新の観測へ更新される**契約: stale と判定された直後でも、
    /// 返った record をそのまま次回の previous として使うと(木も画像も不変のまま)
    /// 2回目は「静止画面」と区別できず not stale になる(同じ凍結フレームへの注記は最初の1回だけ)
    func testConsecutiveJudgeAfterStaleDoesNotRepeatTheStaleVerdict() {
        let baseline = StaleFrameDetector.judge(png: pngA, elements: [element(label: "A")],
                                                previous: nil).record
        let first = StaleFrameDetector.judge(png: pngA, elements: [element(label: "B")],
                                             previous: baseline)
        XCTAssertTrue(first.isStale)

        let second = StaleFrameDetector.judge(png: pngA, elements: [element(label: "B")],
                                              previous: first.record)
        XCTAssertFalse(second.isStale)
    }

    /// previous が nil(初回観測)は判定材料が無いので not stale
    func testNoPreviousRecordIsNeverStale() {
        let result = StaleFrameDetector.judge(png: pngA, elements: [element()], previous: nil)
        XCTAssertFalse(result.isStale)
    }
}
