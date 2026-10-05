// occlusion-guard の「絵が古い」の見送り(stale-screenshot)は、2か所とも見送る前に
// staleFrameShowsExpectedText(期待する文字が絵に丸ごと描かれていれば古くないとみなす)を通すこと。
// 木が絵より遅れて追いつく画面(Compose の iOS のスイッチ)で、最新の絵を古いと読み違えて撮り直しの予算
// いっぱい待っていた(1本 5.7s → 18s)。読みは Vision の実呼び出しで差し替え口が無いので配線を走査で固定する
// (純関数の挙動は RegionText 側のテストが持つ)。

import XCTest

final class StaleFrameTextVisibleWiringTests: XCTestCase {

    private static var source: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // FTCoreTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // リポジトリルート
                .appendingPathComponent("Sources/FTCore/StepExecutor+Assert.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// occlusionFlip の本体(次の関数宣言まで)
    private static func occlusionFlipBody() throws -> String {
        let code = try source
        let start = try XCTUnwrap(code.range(of: "    func occlusionFlip(element: ElementInfo"),
                                  "occlusionFlip が見つからない(走査の前提が崩れた)")
        let rest = code[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        return String(code[start.lowerBound..<end])
    }

    func testBothStaleSkipsCheckTheExpectedTextFirst() throws {
        let body = try Self.occlusionFlipBody()
        let marker = "noteCodesThisStep.insert(.staleScreenshot)"
        var searchFrom = body.startIndex
        var sites = 0
        while let hit = body.range(of: marker, range: searchFrom..<body.endIndex) {
            sites += 1
            // その見送りの直前(同じ if の中)に確認があること
            let windowStart = body.index(hit.lowerBound, offsetBy: -500, limitedBy: body.startIndex)
                ?? body.startIndex
            let window = String(body[windowStart..<hit.lowerBound])
            XCTAssertTrue(window.contains("staleFrameShowsExpectedText("),
                          "stale-screenshot の見送り(\(sites) 箇所目)の前に期待する文字の確認が無い")
            searchFrom = hit.upperBound
        }
        XCTAssertEqual(sites, 2, "occlusionFlip の stale-screenshot の見送りの数が変わった —— 増えた口も確認を通すか見直す")
    }

    func testTheCheckOnlyTrustsAWholeReading() throws {
        let code = try Self.source
        let start = try XCTUnwrap(code.range(of: "private func staleFrameShowsExpectedText("))
        let body = String(code[start.lowerBound...].prefix(1400))
        // 近道が撃てないときは確かめない(未コンパイル の読みで古い絵を通さない)
        XCTAssertTrue(body.contains("RegionText.shouldTakeShortcut("), "OCR の近道の門を通していない")
        // 丸ごと読めた(readable)ときだけ古くないとみなす
        XCTAssertTrue(body.contains("case .read(let readable, _) = outcome, readable"),
                      "丸ごと読めたときだけ古くないとみなす条件が崩れた")
        XCTAssertTrue(body.contains("noteCodesThisStep.insert(.staleFrameTextVisible)"), "注記を立てていない")
    }
}
