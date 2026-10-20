// Compose が一覧の半分隠れた行のタッチ範囲で削った枠を、可視性検証の切り抜きのために戻す判定(TouchOverhangFrameRestore)。
// 材料は E2EX-CMP の無限スクロールを M1Ultra の XCUITest で撮った実際の木(削られた台・削られていない台)と、実アプリの固定コーパス

import XCTest
@testable import FTCore

final class TouchOverhangFrameRestoreTests: XCTestCase {
    private func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    private func load(_ url: URL) throws -> SnapshotResponse {
        try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    private func element(_ id: String, in snapshot: SnapshotResponse) throws -> ElementInfo {
        try XCTUnwrap(snapshot.elements.first { $0.identifier == id }, "\(id) が木に無い")
    }

    /// 削られた台: 結果のテキスト 182〜190(8pt)・一覧の上端 214・row_i_49 が 190〜216.7 → 一覧の上端まで戻す
    func testTextTrimmedByTheOverhangingRowIsRestoredUpToTheListTop() throws {
        let snap = try load(fixturesDir().appendingPathComponent("TouchOverhang/cmp-infinite-trimmed.json"))
        let result = try element("txt_infinite_result", in: snap)
        XCTAssertEqual(result.frame.height, 8, accuracy: 0.01, "材料の前提: 削られた枠")
        let restored = try XCTUnwrap(TouchOverhangFrameRestore.restoredFrame(for: result, in: snap.elements))
        XCTAssertEqual(restored.y, 182, accuracy: 0.01)
        XCTAssertEqual(restored.height, 214 - 182, accuracy: 0.01, "一覧の上端(214)まで")
        XCTAssertEqual(restored.x, result.frame.x)
        XCTAssertEqual(restored.width, result.frame.width)
    }

    /// 削られていない台(行が一覧の上端の内側)と、同じ木の他のテキストは戻さない
    func testIntactTextAndUnrelatedTextAreLeftAlone() throws {
        let intact = try load(fixturesDir().appendingPathComponent("TouchOverhang/cmp-infinite-intact.json"))
        XCTAssertNil(TouchOverhangFrameRestore.restoredFrame(
            for: try element("txt_infinite_result", in: intact), in: intact.elements))
        let trimmed = try load(fixturesDir().appendingPathComponent("TouchOverhang/cmp-infinite-trimmed.json"))
        XCTAssertNil(TouchOverhangFrameRestore.restoredFrame(
            for: try element("txt_infinite_count", in: trimmed), in: trimmed.elements))
    }

    /// 実アプリの固定コーパスでは1件も戻さない(戻すのは観測した形だけ)。増えたら1件ずつ見てから基準を変える
    func testRealAppCorpusRestoresNothing() throws {
        let dir = fixturesDir().appendingPathComponent("RealAppSnapshots")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThan(files.count, 40, "コーパスに届いていない")
        var fired: [String] = []
        for file in files {
            let snap = try load(file)
            for e in snap.elements where TouchOverhangFrameRestore.restoredFrame(for: e, in: snap.elements) != nil {
                fired.append("\(file.lastPathComponent): \(e.type) \(e.identifier ?? "-") \(e.label ?? "-") \(e.frame)")
            }
        }
        XCTAssertEqual(fired, [], fired.joined(separator: "\n"))
    }

    /// 可視性検証の入口で、切り抜きより前に戻していること(全段が同じ枠を見る)と、注記を立てていること
    func testOcclusionFlipRestoresTheFrameBeforeAnyCrop() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/StepExecutor+Assert.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "func occlusionFlip("))
        let body = text[start.upperBound...]
        let restore = try XCTUnwrap(body.range(of: "TouchOverhangFrameRestore.restoredFrame(for: element, in: elements)"))
        let firstCrop = try XCTUnwrap(body.range(of: "RegionInk.luminanceStdDev("))
        XCTAssertTrue(restore.upperBound <= firstCrop.lowerBound, "切り抜きの後で戻している")
        XCTAssertTrue(body[restore.upperBound..<firstCrop.lowerBound].contains("noteCodesThisStep.insert(.a11yFrameRestored)"))
    }
}
