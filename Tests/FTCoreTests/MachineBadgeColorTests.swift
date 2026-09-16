// リモートマシン登録簿のバッジ色パレット。拡張はこの定数を持たないので、
// パレットの鍵・hex・割り当て順を等号で固定する(唯一の定義元)。

import XCTest
@testable import FTCore

final class MachineBadgeColorTests: XCTestCase {

    func testPaletteIsFixed() {
        let expected: [(key: String, hex: String)] = [
            ("gray", "#d4d4d4"),
            ("rose", "#f6c1cc"),
            ("sky", "#bcd6f5"),
            ("lemon", "#f3e79b"),
            ("mint", "#b9e6cf"),
            ("lavender", "#dcc8f2"),
            ("peach", "#f9d3b4"),
            ("aqua", "#b5e3e8"),
            ("lime", "#d3ecae"),
            ("pink", "#f3c4e6"),
            ("periwinkle", "#c9cdf6"),
            ("sand", "#e6d8c0"),
        ]
        XCTAssertEqual(MachineBadgeColor.palette.map(\.key), expected.map(\.key))
        XCTAssertEqual(MachineBadgeColor.palette.map(\.hex), expected.map(\.hex))
    }

    func testIsKnown() {
        XCTAssertTrue(MachineBadgeColor.isKnown("rose"))
        XCTAssertTrue(MachineBadgeColor.isKnown("gray"))
        XCTAssertFalse(MachineBadgeColor.isKnown("chartreuse"))
        XCTAssertFalse(MachineBadgeColor.isKnown(""))
    }

    func testAutoAssignReturnsFirstWhenEmpty() {
        XCTAssertEqual(MachineBadgeColor.autoAssign(usedBy: []), "gray")
    }

    func testAutoAssignSkipsUsedColors() {
        XCTAssertEqual(MachineBadgeColor.autoAssign(usedBy: ["gray"]), "rose")
        XCTAssertEqual(MachineBadgeColor.autoAssign(usedBy: ["gray", "rose"]), "sky")
    }

    /// nil と未知の鍵は使用数に数えない
    func testAutoAssignIgnoresNilAndUnknownKeys() {
        XCTAssertEqual(MachineBadgeColor.autoAssign(usedBy: [nil, "not-a-color", nil]), "gray")
    }

    /// 全色使い切ったら、使用数が最小(同数ならパレット順で先)のものへ重ねる
    func testAutoAssignWrapsToLeastUsedWhenPaletteExhausted() {
        let allOnce = MachineBadgeColor.palette.map { Optional($0.key) }
        XCTAssertEqual(MachineBadgeColor.autoAssign(usedBy: allOnce), "gray")

        // 使われた回数は重ねても最小(0回)のうちパレット順で先頭が選ばれる
        let skewed: [String?] = ["gray", "rose", "sky", "sky"]
        XCTAssertEqual(MachineBadgeColor.autoAssign(usedBy: skewed), "lemon")
    }
}
