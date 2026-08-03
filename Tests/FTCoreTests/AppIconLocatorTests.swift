import XCTest
@testable import FTCore

/// AppIconLocator(tapAppIcon の純粋ロジック)の境界を固定する。ドライバを必要としない層なので、
/// ここで落とせない誤りは E2E まで見つからない。
final class AppIconLocatorTests: XCTestCase {

    private func element(_ ref: Int, label: String?) -> ElementInfo {
        ElementInfo(ref: ref, type: "Icon", identifier: nil, label: label, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 60, height: 60), depth: 0)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    // MARK: - findIcon

    func testFindIconMatchesExactLabel() {
        let snap = snapshot([element(1, label: "Settings"), element(2, label: "Maps")])
        XCTAssertEqual(AppIconLocator.findIcon("Maps", in: snap)?.ref, 2)
    }

    func testFindIconReturnsNilWhenNoLabelMatches() {
        let snap = snapshot([element(1, label: "Settings")])
        XCTAssertNil(AppIconLocator.findIcon("Maps", in: snap))
    }

    /// label なし(nil)の要素は決してマッチしない(部分一致・大小無視をしない完全一致の確認を兼ねる)
    func testFindIconDoesNotMatchNilOrSubstringLabels() {
        let snap = snapshot([element(1, label: nil), element(2, label: "My Settings App")])
        XCTAssertNil(AppIconLocator.findIcon("Settings", in: snap))
    }

    /// 複数一致時は最初の1件(Shirates の「最初に見つかった方」と同じ)
    func testFindIconReturnsFirstMatchOnDuplicateLabels() {
        let snap = snapshot([element(1, label: "Clock"), element(2, label: "Clock")])
        XCTAssertEqual(AppIconLocator.findIcon("Clock", in: snap)?.ref, 1)
    }

    // MARK: - signature

    /// ラベル集合が同じなら ref の割り当てが違っても同じ署名(並び替えに依存しないことの確認)
    func testSignatureIsOrderIndependent() {
        let a = snapshot([element(1, label: "Maps"), element(2, label: "Clock")])
        let b = snapshot([element(5, label: "Clock"), element(9, label: "Maps")])
        XCTAssertEqual(AppIconLocator.signature(of: a), AppIconLocator.signature(of: b))
    }

    func testSignatureChangesWhenLabelSetChanges() {
        let a = snapshot([element(1, label: "Maps")])
        let b = snapshot([element(1, label: "Clock")])
        XCTAssertNotEqual(AppIconLocator.signature(of: a), AppIconLocator.signature(of: b))
    }

    // MARK: - shouldStopSearch

    func testStopsAfterTwoConsecutiveUnchangedScreens() {
        XCTAssertFalse(AppIconLocator.shouldStopSearch(consecutiveUnchanged: 1, attempts: 1, maxAttempts: 8))
        XCTAssertTrue(AppIconLocator.shouldStopSearch(consecutiveUnchanged: 2, attempts: 2, maxAttempts: 8))
    }

    func testStopsAtMaxAttemptsEvenIfStillChanging() {
        XCTAssertTrue(AppIconLocator.shouldStopSearch(consecutiveUnchanged: 0, attempts: 8, maxAttempts: 8))
        XCTAssertFalse(AppIconLocator.shouldStopSearch(consecutiveUnchanged: 0, attempts: 7, maxAttempts: 8))
    }
}
