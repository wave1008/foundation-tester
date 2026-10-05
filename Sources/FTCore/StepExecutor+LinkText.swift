// tap(sel, linkText:) の本体。位置の決め方は LinkTextLocator(木 → OCR)。
// 位置が決まったら座標タップの既存経路(executeDirectCoordinateTap)で撃つ
// = in-app が要素の無い点を XCUITest へ回す等の振り分けをそのまま通る

import Foundation

extension StepExecutor {

    func executeTapLinkText(_ linkText: String, element: ElementInfo, snapshot: SnapshotResponse,
                            step: FlowStep, notes: String?, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        var point = LinkTextLocator.treePoint(linkText: linkText, element: element, in: snapshot.elements)
        var ocrLines: [String] = []
        var ocrAttempts = 0
        if point == nil {
            let clock = ContinuousClock()
            let start = clock.now
            let png = try await driver.screenshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            if let located = await RegionText.locateLink(linkText: linkText, pngData: png,
                                                         frame: element.frame, screen: snapshot.screen) {
                ocrLines = located.lines
                ocrAttempts = located.attempts
                if let p = located.point { point = .init(x: p.x, y: p.y, source: .ocr) }
            }
        }
        guard let point else {
            let read = ocrLines.isEmpty ? "OCR read no text in the element"
                : "OCR read: " + ocrLines.map { "\"\($0)\"" }.joined(separator: ", ")
            return StepOutcome(status: failed(.notFound,
                "cannot find the link text \"\(linkText)\" inside \(TapTargetGeometry.describe(element)):"
                    + " no descendant in the tree has that label, and the text was not found in the element's pixels"
                    + " (\(read); \(ocrAttempts) OCR pass\(ocrAttempts == 1 ? "" : "es"))"))
        }
        let tapped = try await executeDirectCoordinateTap(step: step, x: point.x, y: point.y, phase: &phase)
        return StepOutcome(status: tapped.status,
                           driverFallback: Self.joinNotes(notes,
                               "link text \"\(linkText)\" located by \(point.source.rawValue)"
                                   + " at (\(Int(point.x.rounded())), \(Int(point.y.rounded())))",
                               tapped.driverFallback))
    }
}
