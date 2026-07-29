// `ftester results` の表示整形と、インストール済みデバイス一覧の OS 表記の正規化。
// どちらも人が読む出力だが、崩れても実行は成功するため実機側では気付けない。

import XCTest
@testable import ftester

final class ResultsFormattingTests: XCTestCase {

    // MARK: - SimpleTable

    func testRenderAlignsColumnsToWidestCell() {
        let table = SimpleTable.render(
            headers: ["id", "result"],
            rows: [["S0010", "passed"], ["S1", "failed"]])
        let lines = table.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 4, "ヘッダ + 区切り + 行数")
        // 区切り行の各列幅が、その列の最長セルに一致する
        XCTAssertEqual(lines[1], "-----  ------")
        // 短いセルは右側が空白で埋まる(列開始位置が揃う)
        XCTAssertTrue(lines[3].hasPrefix("S1     "), "実際: \(lines[3])")
    }

    func testRenderUsesHeaderWidthWhenRowsAreShorter() {
        let table = SimpleTable.render(headers: ["scenario"], rows: [["S1"]])
        XCTAssertEqual(table.split(separator: "\n")[1], "--------")
    }

    func testRenderToleratesRowsWithMissingCells() {
        // 列数が足りない行が来ても落ちない(空セル扱い)
        let table = SimpleTable.render(headers: ["a", "b", "c"], rows: [["1"]])
        XCTAssertEqual(table.split(separator: "\n").count, 3)
    }

    func testRenderWithNoRowsStillEmitsHeaderAndSeparator() {
        let table = SimpleTable.render(headers: ["id"], rows: [])
        XCTAssertEqual(table.split(separator: "\n").map(String.init), ["id", "--"])
    }

    // MARK: - formatLocal

    func testFormatLocalRendersISO8601AsLocalTime() {
        // 表示はローカル時刻。壁時計の桁形だけを確認する(TZ 依存の値そのものは見ない)
        let formatted = formatLocal("2026-07-29T10:20:30Z")
        XCTAssertNotEqual(formatted, "2026-07-29T10:20:30Z", "ISO 文字列のまま返してはいけません")
        XCTAssertEqual(formatted.count, 19, "yyyy-MM-dd HH:mm:ss: \(formatted)")
        XCTAssertTrue(formatted.contains(":"))
    }

    func testFormatLocalPassesThroughUnparsableInput() {
        // 壊れた値でも表示は止めない(結果一覧が1行の異常で全滅しないため)
        XCTAssertEqual(formatLocal("not-a-date"), "not-a-date")
        XCTAssertEqual(formatLocal(""), "")
    }

    // MARK: - normalizeOS

    func testNormalizeOSStripsIOSPrefix() {
        XCTAssertEqual(ApiInstalledDevicesCommand.normalizeOS("iOS 27.0"), "27.0")
    }

    func testNormalizeOSLeavesOtherFormsUntouched() {
        XCTAssertEqual(ApiInstalledDevicesCommand.normalizeOS("27.0"), "27.0")
        XCTAssertEqual(ApiInstalledDevicesCommand.normalizeOS("iPadOS 26.0"), "iPadOS 26.0")
        XCTAssertEqual(ApiInstalledDevicesCommand.normalizeOS(""), "")
    }
}
