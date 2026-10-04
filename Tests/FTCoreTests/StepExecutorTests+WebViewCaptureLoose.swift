// occlusion-guard: WebView の層を撮り逃した絵(対象の領域が一色)の見送り(webViewCaptureBlank)は、
// ロケータのラベルが部分一致(looseMatch)でも効くこと。部分一致は「領域が覆われているか」とは無関係なのに、
// 幾何の疑い(OcclusionSuspicion.geometric)へ混ぜていたため救済の門を素通りし、撮り逃した黒い WebView を
// OCR だけの判定が「描かれていない」の誤った赤にしていた(2026-10-01 の E2E-Flutter、`textIs "wv_result=*"`)。
import XCTest
@testable import FTCore

extension StepExecutorTests {

    func testWebViewCaptureBlankIsSkippedEvenWhenTheLabelMatchedOnlyPartially() async throws {
        let log = CallLog()
        let webView = ElementInfo(ref: 1, type: "webView", identifier: nil, label: nil, value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 0, width: 400, height: 600), depth: 0)
        let text = ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "wv_result=link",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 16, y: 300, width: 200, height: 24), depth: 1)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[webView, text]],
                                    screenshots: [Self.blankPNG])
        let executor = StepExecutor(driver: primary, delegate: NoVerdictVisibilityDelegate(),
                                    occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
        // ラベルの前方一致で掴む = 部分一致(実ラベルは "wv_result=link"。E2E で落ちた `"wv_result=*"` と同じ形)
        let step = FlowStep(assert: "exists", locator: FlowLocator(label: "wv_result=", labelMatch: .startsWith),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { XCTFail("実際は \(outcome.status)"); return }
        XCTAssertTrue(outcome.notes.contains(.webViewCaptureBlank),
                      "部分一致でも WebView の撮り逃しとして見送るはず: \(outcome.notes)")
    }
}
