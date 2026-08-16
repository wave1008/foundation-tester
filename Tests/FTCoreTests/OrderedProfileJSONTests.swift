// プロファイル JSON のキー順(2026-08-17 ユーザー指示: host を先に書く)と、
// 「エスケープは JSONSerialization に任せる」規律を固定する。
// 順序が壊れても JSON としては妥当なので、人が読むまで気付けない —— だから等号で押さえる。

import XCTest
@testable import FTCore

final class OrderedProfileJSONTests: XCTestCase {

    private func text(_ object: [String: Any]) throws -> String {
        String(decoding: try OrderedProfileJSON.data(object), as: UTF8.self)
    }

    func testHostAndNameComeFirstAndTheRestIsAlphabetical() throws {
        let output = try text(["udid": "U", "avd": "A", "name": "d1", "host": "M1Ultra", "os": "27.0"])
        XCTAssertEqual(output, """
        {
          "host": "M1Ultra",
          "name": "d1",
          "avd": "A",
          "os": "27.0",
          "udid": "U"
        }

        """)
    }

    /// アルファベット順だと Android のデバイスは avd が先に来る(.sortedKeys の実挙動)。
    /// この並べ替えを入れた動機そのものなので、入れ子の配列でも効くことを固定する
    func testDeviceArraysAreOrderedToo() throws {
        let output = try text([
            "ios": ["devices": [["avd": "Pixel_9", "name": "e1", "host": "local"]]],
        ])
        XCTAssertTrue(output.contains("""
                "host": "local",
                "name": "e1",
                "avd": "Pixel_9"
        """), output)
    }

    func testEscapingIsDelegatedToJSONSerialization() throws {
        let output = try text(["name": #"日本語 "引用" \ スラッシュ/"#])
        // / をエスケープしない(withoutEscapingSlashes)。引用符と円記号は JSON の規則どおり
        XCTAssertTrue(output.contains(#""name": "日本語 \"引用\" \\ スラッシュ/""#), output)
    }

    func testNumbersBooleansAndNullSurvive() throws {
        let output = try text(["port": 8123, "heal": true, "os": NSNull()])
        XCTAssertTrue(output.contains("\"port\": 8123"), output)
        XCTAssertTrue(output.contains("\"heal\": true"), output)
        XCTAssertTrue(output.contains("\"os\": null"), output)
    }

    func testEmptyContainersStayOnOneLine() throws {
        // ios はセクションなので devices より先(preferredKeyOrder)
        XCTAssertEqual(try text(["devices": [] as [Any], "ios": [String: Any]()]), """
        {
          "ios": {},
          "devices": []
        }

        """)
    }
}
