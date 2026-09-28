// ラベルだけのライブリージョン(Flutter の iOS の SnackBar の文言)を文字として扱う判定。
// 実測値: traits=0x200(頻繁に更新される)・ラベルあり。

import XCTest
@testable import FTCore

final class LiveRegionTextTests: XCTestCase {

    func testLabelledLiveRegionIsText() {
        XCTAssertTrue(LiveRegionText.isLabelOnlyLiveRegion(traits: 0x200, label: "削除しました"))
    }

    func testLiveRegionWithoutLabelIsNotText() {
        XCTAssertFalse(LiveRegionText.isLabelOnlyLiveRegion(traits: 0x200, label: nil))
        XCTAssertFalse(LiveRegionText.isLabelOnlyLiveRegion(traits: 0x200, label: ""))
    }

    /// 特性の無い Other(装飾・入れ物)はラベルがあっても出さない(木が入れ物のラベルで膨らむ)
    func testLabelWithoutTheTraitIsNotText() {
        XCTAssertFalse(LiveRegionText.isLabelOnlyLiveRegion(traits: 0, label: "入れ物"))
        XCTAssertFalse(LiveRegionText.isLabelOnlyLiveRegion(traits: 1 << 8, label: "別の特性"))
    }

    func testTheTraitBitIsPinned() {
        XCTAssertEqual(LiveRegionText.updatesFrequently, 512)
    }
}
