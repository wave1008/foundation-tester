// 登録簿の fmConcurrency(機械ごとの FM 枠)のデコード規律。
// **既存の登録簿を読めなくしない**ことと、**壊れた値で run を止めない**ことを固定する。

import XCTest
@testable import FTCore

final class RemoteHostEntryFMConcurrencyTests: XCTestCase {

    private func decode(_ json: String) throws -> RemoteHostEntry {
        try JSONDecoder().decode(RemoteHostEntry.self, from: Data(json.utf8))
    }

    /// 欄が無い既存の登録簿を読める(後方互換)
    func testMissingFieldDecodesAsNil() throws {
        let e = try decode(#"{"machine":"M1Max","host":"user@10.0.0.1"}"#)
        XCTAssertNil(e.fmConcurrency)
    }

    func testValueDecodes() throws {
        let e = try decode(#"{"machine":"M1Ultra","host":"user@10.0.0.2","fmConcurrency":1}"#)
        XCTAssertEqual(e.fmConcurrency, 1)
    }

    /// **0 以下は nil へ倒す**。実行の可否を決める設定ではないので、壊れた値で止めるより
    /// 既定で動かすほうが害が小さい
    func testNonPositiveFallsBackToNil() throws {
        XCTAssertNil(try decode(#"{"machine":"a","host":"h","fmConcurrency":0}"#).fmConcurrency)
        XCTAssertNil(try decode(#"{"machine":"a","host":"h","fmConcurrency":-3}"#).fmConcurrency)
    }

    /// 書いた値が読み戻せる(round trip)。設定されていなければ欄ごと出さない
    func testRoundTrip() throws {
        let set = RemoteHostEntry(machine: "M1Ultra", host: "user@h", fmConcurrency: 2)
        XCTAssertEqual(try decode(String(data: JSONEncoder().encode(set), encoding: .utf8)!)
                        .fmConcurrency, 2)
        let unset = RemoteHostEntry(machine: "M1Max", host: "user@h")
        let json = String(data: try JSONEncoder().encode(unset), encoding: .utf8)!
        XCTAssertFalse(json.contains("fmConcurrency"), json)
    }
}
