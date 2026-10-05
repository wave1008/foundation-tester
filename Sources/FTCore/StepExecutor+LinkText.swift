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
        // **OCR で決めた点は1つのノードの中の点**。in-app の座標タップは「点を含むノードを activate」するので、
        // 段落ノードの activate(= 押した位置と無関係なリンク)に化ける。hybrid では本物のタッチ(XCUITest)で撃つ。
        // 木の子孫で決めた点はそのノード自身なので従来の経路でよい
        if point.source == .ocr, let td = typeDriver {
            let clock = ContinuousClock()
            let start = clock.now
            try await td.tap(x: point.x, y: point.y)
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed,
                               driverFallback: Self.joinNotes(notes,
                                   "link text \"\(linkText)\" located by ocr"
                                       + " at (\(Int(point.x.rounded())), \(Int(point.y.rounded())))",
                                   "sent via XCUITest (a point inside one node)"))
        }
        let tapped = try await executeDirectCoordinateTap(step: step, x: point.x, y: point.y, phase: &phase)
        return StepOutcome(status: tapped.status,
                           driverFallback: Self.joinNotes(notes,
                               "link text \"\(linkText)\" located by \(point.source.rawValue)"
                                   + " at (\(Int(point.x.rounded())), \(Int(point.y.rounded())))",
                               tapped.driverFallback))
    }
}
