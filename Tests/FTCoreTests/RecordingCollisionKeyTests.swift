// 録画の元ファイル名・クリップ名の重複判定の鍵(RecordingIndexIO.collisionKey)。置き場(APFS の既定)は大小文字を区別せず
// (Unicode の case folding)、正規化の違いも無視するので、名前のまま数えると別の鍵のまま同じファイルになる。

import XCTest
@testable import FTCore

final class RecordingCollisionKeyTests: XCTestCase {
    func testCaseVariantsShareAKey() {
        XCTAssertEqual(RecordingIndexIO.collisionKey(for: "Phone"), RecordingIndexIO.collisionKey(for: "phone"))
        XCTAssertEqual(RecordingIndexIO.collisionKey(for: "σ"), RecordingIndexIO.collisionKey(for: "ς"),
                       "`ς` の case folding は `σ`(lowercased では別のまま)")
    }

    func testNormalizationVariantsShareAKey() {
        XCTAssertEqual(RecordingIndexIO.collisionKey(for: "\u{00E9}"), RecordingIndexIO.collisionKey(for: "e\u{0301}"))
        // 結合文字の順だけが違う正規等価。fold → NFC の順だと別の鍵になる(fold が ͅ を ι に変えて構造が変わる)
        XCTAssertEqual(RecordingIndexIO.collisionKey(for: "\u{03B1}\u{0345}\u{0301}"),
                       RecordingIndexIO.collisionKey(for: "\u{03B1}\u{0301}\u{0345}"))
    }

    func testDifferentNamesKeepDifferentKeys() {
        XCTAssertNotEqual(RecordingIndexIO.collisionKey(for: "phone"), RecordingIndexIO.collisionKey(for: "phone2"))
        XCTAssertNotEqual(RecordingIndexIO.collisionKey(for: "phone"), RecordingIndexIO.collisionKey(for: "phone~2"))
    }
}
