// `InterruptHandler` の `||` 代替の照合規則: **先に書いたほうが勝つ**(他の `||` と同じ)。
// 鍵(注記・回数)は代替が無ければ従来どおり `detect.summary`

import XCTest
@testable import FTCore

final class InterruptHandlerFallbackTests: XCTestCase {

    private func snapshot(ids: [String]) -> SnapshotResponse {
        let elements = ids.enumerated().map { index, id in
            ElementInfo(ref: index + 1, type: "button", identifier: id, label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index) * 50, width: 100, height: 40), depth: 0)
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: elements, truncatedCount: 0)
    }

    func testFirstWrittenAlternativeWins() {
        let handler = StepExecutor.InterruptHandler(
            detect: FlowLocator(id: "modal_en"), dismiss: FlowLocator(id: "close_en"),
            detectFallbacks: [FlowLocator(id: "modal_ja")],
            dismissFallbacks: [FlowLocator(id: "close_ja")])
        let both = snapshot(ids: ["modal_ja", "close_ja", "modal_en", "close_en"])
        XCTAssertEqual(handler.matchDetect(in: both)?.identifier, "modal_en")
        XCTAssertEqual(handler.matchDismiss(in: both)?.identifier, "close_en")

        let onlySecond = snapshot(ids: ["modal_ja", "close_ja"])
        XCTAssertEqual(handler.matchDetect(in: onlySecond)?.identifier, "modal_ja")
        XCTAssertEqual(handler.matchDismiss(in: onlySecond)?.identifier, "close_ja")

        XCTAssertNil(handler.matchDetect(in: snapshot(ids: ["other"])))
    }

    func testKeyIsUnchangedWithoutFallbacks() {
        let plain = StepExecutor.InterruptHandler(detect: FlowLocator(id: "promo_modal"),
                                                  dismiss: FlowLocator(id: "btn_close"))
        XCTAssertEqual(plain.key, FlowLocator(id: "promo_modal").summary)
        let withAlternative = StepExecutor.InterruptHandler(
            detect: FlowLocator(id: "promo_modal"), dismiss: FlowLocator(id: "btn_close"),
            detectFallbacks: [FlowLocator(id: "promo_modal_ja")])
        XCTAssertEqual(withAlternative.key,
                       FlowLocator(id: "promo_modal").summary + "||" + FlowLocator(id: "promo_modal_ja").summary)
    }
}
