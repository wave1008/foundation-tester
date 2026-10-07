import Foundation
import XCTest

/// 録画の切り出しは区間だけを読むこと(`VideoRecordingFinalizer.extractClip` の `reader.timeRange`)。
/// 外すと毎回ソースの先頭から全フレームを復号するので、所要がクリップ数 × 録画長の二乗になる
/// (1台で56本の run で切り出しだけ 15 分前後)。意味は既存の切り出しテストが見るので、ここは所要の砦だけ
final class VideoClipTimeRangeScanTests: XCTestCase {
    func testExtractClipLimitsTheReaderToTheClipBeforeReading() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/VideoRecordingFinalizer.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let range = try XCTUnwrap(text.range(of: "reader.timeRange = CMTimeRange(start: clipStart, end: clipEnd)"),
                                  "extractClip が reader.timeRange を区間に絞っていない")
        let start = try XCTUnwrap(text.range(of: "reader.startReading()"))
        XCTAssertLessThan(range.lowerBound, start.lowerBound, "timeRange は startReading より前に設定する(後では効かない)")
    }
}
