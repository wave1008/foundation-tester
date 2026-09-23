import XCTest

/// LIVE-3: 鮮度判定(LiveStaleFrameTracker)は絵と木の両方を撮る emitObservation にだけ効かせ、
/// 絵だけの emitFrame(木が無いので判定できない)には触れないことをソース走査で縛る。
/// 判定そのものの単体テストは LiveStaleFrameTrackerTests。
final class ApiLiveStaleFrameWiringTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// emitObservation は撮影した生 PNG(縮小前)と、そのすぐ後に撮った木(snap.elements)を渡し、
    /// 結果を snapshot イベントの notes へ載せること
    func testEmitObservationFeedsRawPNGAndFreshElementsIntoTheTracker() throws {
        let code = try source()
        guard let start = code.range(of: "private func emitObservation("),
              let end = code.range(of: "private func emitFrame(") else {
            return XCTFail("emitObservation/emitFrame が見当たらない — テストを見直すこと")
        }
        let body = String(code[start.upperBound..<end.lowerBound])
        XCTAssertTrue(
            body.contains("staleFrameTracker.staleNotes(png: png, elements: snap.elements)"),
            "emitObservation は撮影した生 PNG とその直後の木を LiveStaleFrameTracker へ渡すこと"
            + "(縮小後の JPEG や古い木を渡すと画像ハッシュ・木指紋の比較が壊れる)")
        XCTAssertTrue(body.contains("notes: notes"),
                      "鮮度注記を ApiLiveSnapshotEvent(ok:true側)へ渡していない")
    }

    /// emitFrame は絵だけを撮る経路で木が無いため、鮮度判定に触れてはいけない
    /// (触れると「木が変わっていない」という誤った前提のまま常に notStale を返しかねない)
    func testEmitFrameNeverTouchesStaleFrameTracking() throws {
        let code = try source()
        guard let start = code.range(of: "private func emitFrame("),
              let end = code.range(of: "private func logStderr(") else {
            return XCTFail("emitFrame が見当たらない — テストを見直すこと")
        }
        let body = String(code[start.upperBound..<end.lowerBound])
        XCTAssertFalse(body.contains("staleFrameTracker"),
                       "emitFrame は木を撮らないので鮮度判定に触れないこと")
        XCTAssertFalse(body.contains("StaleFrameDetector"),
                       "emitFrame は木を撮らないので StaleFrameDetector を直接呼ばないこと")
    }

    /// handle が emitObservation にだけ staleFrameTracker を渡し、emitFrame(frame コマンド)へは
    /// 渡していないこと(呼び出し側の配線)
    func testHandlePassesTheTrackerOnlyToEmitObservation() throws {
        let code = try source()
        guard code.range(of: "await emitFrame(driver: driver, starter: starter, port: port)") != nil
        else {
            return XCTFail("handle 内の emitFrame 呼び出しが見当たらない — テストを見直すこと")
        }
        guard let observationCallRange = code.range(
            of: "await emitObservation(driver: driver, starter: starter, follower: follower, port: port,")
        else {
            return XCTFail("handle 内の emitObservation 呼び出しが見当たらない — テストを見直すこと")
        }
        let tail = String(code[observationCallRange.upperBound...].prefix(80))
        XCTAssertTrue(tail.contains("staleFrameTracker: staleFrameTracker"),
                      "handle は emitObservation にだけ staleFrameTracker を渡すこと")
    }
}
