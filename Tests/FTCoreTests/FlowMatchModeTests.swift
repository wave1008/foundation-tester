import XCTest

@testable import FTCore

/// ゼロ幅文字(実データが混入させる不可視文字)を挟んでも一致すること。
/// 同期対象: SnapshotRenderer.renderElement が出力からも同じ文字集合を除去する
/// (Tests/FTCoreTests/SnapshotRenderingTests.swift)。
final class FlowMatchModeTests: XCTestCase {
    private let zwLabel = "\u{200B}\u{200B}中央線\u{200D}\u{FEFF}\u{2060}"

    func testExactMatchIgnoresZeroWidthCharactersInActualAndExpected() {
        XCTAssertTrue(FlowMatchMode.exact.matches(zwLabel, "中央線"))
        XCTAssertTrue(FlowMatchMode.exact.matches("中央線", zwLabel))
    }

    func testContainsMatchIgnoresZeroWidthCharacters() {
        XCTAssertTrue(FlowMatchMode.contains.matches(zwLabel, "央線"))
    }

    /// .matches は正規表現なので expected 側は正規化しない(パターンを書き換えないため)。
    /// actual 側だけ正規化されれば素のパターンで一致する
    func testRegexMatchNormalizesActualOnlyNotPattern() {
        XCTAssertTrue(FlowMatchMode.matches.matches(zwLabel, "中央線"))
    }

    func testExactMatchStillFailsOnRealDifference() {
        XCTAssertFalse(FlowMatchMode.exact.matches(zwLabel, "中央本線"))
    }
}
