// 「キーボードが出ているか」は `KeyboardWait.isShown` / `shownState` の1か所で決める。
// 隠れた・最小化したキーボードは nil ではなく画面の外の矩形で来て、iOS の XCUITest は `keyboardShown` も true にする。
// `keyboardFrame != nil || keyboardShown == true` と書いた読み手(MCP 4か所・DSL 4か所)が、それを「出ている」と読んでいた
// (実測: Apple マップ・画面高 874pt で (0,891 402x233))。

import XCTest
@testable import FTCore

final class KeyboardShownJudgmentTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func snapshot(frame: FTRect?, shown: Bool?) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0,
                         keyboardShown: shown, keyboardFrame: frame)
    }

    func testAKeyboardBelowTheScreenIsNotShownEvenWhenTheBridgeSaysShown() {
        let hidden = snapshot(frame: FTRect(x: 0, y: 891, width: 402, height: 233), shown: true)
        XCTAssertFalse(KeyboardWait.isShown(hidden))
        XCTAssertEqual(KeyboardWait.shownState(hidden), false)
    }

    func testAKeyboardOnTheScreenIsShown() {
        let up = snapshot(frame: FTRect(x: 0, y: 600, width: 402, height: 274), shown: nil)
        XCTAssertTrue(KeyboardWait.isShown(up))
        XCTAssertEqual(KeyboardWait.shownState(up), true)
    }

    /// 矩形が無いときだけ `keyboardShown` を使う(Android は矩形を持たない回がある)。どちらも無ければ不明
    func testWithoutAFrameTheFlagDecidesAndNothingMeansUnknown() {
        XCTAssertTrue(KeyboardWait.isShown(snapshot(frame: nil, shown: true)))
        XCTAssertEqual(KeyboardWait.shownState(snapshot(frame: nil, shown: false)), false)
        XCTAssertNil(KeyboardWait.shownState(snapshot(frame: nil, shown: nil)), "不明を非表示と読まない")
        XCTAssertFalse(KeyboardWait.isShown(snapshot(frame: nil, shown: nil)))
    }

    /// **chrome から帯を推定するのは、画面に掛かっている chrome だけ**(画面の外へ隠れたキーボードの chrome で帯を作らない)
    func testKeyboardBandFromChromeIgnoresChromeBelowTheScreen() {
        func chrome(y: Double) -> ElementInfo {
            ElementInfo(ref: 1, type: "other", identifier: "inputView", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: y, width: 402, height: 301), depth: 1)
        }
        XCTAssertNotNil(TapTargetGeometry.keyboardBandFromChrome(in: [chrome(y: 573)], screen: screen))
        XCTAssertNil(TapTargetGeometry.keyboardBandFromChrome(in: [chrome(y: 891)], screen: screen))
    }

    /// **同じ書き方の再発を落とす**: ホスト側(ブリッジの実装を除く)で生の欄から「出ている」を作らない
    func testNoHostCodeReadsTheRawFieldsAsKeyboardShown() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100, "走査が Sources に届いていない")
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "KeyboardWait.swift" {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in code where line.contains("keyboardFrame != nil") || line.contains("keyboardShown == true")
                || line.contains("lastShown = snapshot.keyboardShown") {
                offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "KeyboardWait.isShown / shownState を通していない")
    }
}
