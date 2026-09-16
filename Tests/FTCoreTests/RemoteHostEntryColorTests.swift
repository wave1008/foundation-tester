// 登録簿の color(バッジ色)のデコード規律。パレットに無い鍵・空文字は nil に倒す
// (fmConcurrency と同じ「壊れた設定で止めない」方針)。割り当てそのものは
// RemoteHostRegistry.upsert / MachineBadgeColor が持つ。

import XCTest
@testable import FTCore

final class RemoteHostEntryColorTests: XCTestCase {

    private func decode(_ json: String) throws -> RemoteHostEntry {
        try JSONDecoder().decode(RemoteHostEntry.self, from: Data(json.utf8))
    }

    /// color キーの無い旧 JSON も読める
    func testMissingColorDecodesAsNil() throws {
        let e = try decode(#"{"machine":"M1Max","host":"user@10.0.0.1"}"#)
        XCTAssertNil(e.color)
    }

    func testKnownColorDecodes() throws {
        let e = try decode(#"{"machine":"M1Max","host":"user@h","color":"mint"}"#)
        XCTAssertEqual(e.color, "mint")
    }

    func testUnknownColorFallsBackToNil() throws {
        let e = try decode(#"{"machine":"M1Max","host":"user@h","color":"chartreuse"}"#)
        XCTAssertNil(e.color)
    }

    func testEmptyColorFallsBackToNil() throws {
        let e = try decode(#"{"machine":"M1Max","host":"user@h","color":""}"#)
        XCTAssertNil(e.color)
    }

    func testRoundTrip() throws {
        let set = RemoteHostEntry(machine: "M1Ultra", host: "user@h", color: "sky")
        XCTAssertEqual(try decode(String(data: JSONEncoder().encode(set), encoding: .utf8)!).color, "sky")
        let unset = RemoteHostEntry(machine: "M1Max", host: "user@h")
        let json = String(data: try JSONEncoder().encode(unset), encoding: .utf8)!
        XCTAssertFalse(json.contains("color"), json)
    }
}
