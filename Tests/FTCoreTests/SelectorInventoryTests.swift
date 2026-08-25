import XCTest
@testable import FTCore

/// `#id` の実在照合に使う台帳。**誤検知を出さない側に倒す**設計なので、
/// 「足りないときに黙る」ことと「和集合で消えない」ことが本体。
final class SelectorInventoryTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-inventory-\(UUID().uuidString)/.fleetest/inv.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent()
            .deletingLastPathComponent())
        super.tearDown()
    }

    func testMissingFileLoadsAsNil() {
        XCTAssertNil(SelectorInventory.load(at: url), "台帳が無いのに読めたことになっている")
    }

    /// **画面ごとに撮る**ので、後の記録が前の画面の id を消してはいけない
    func testRecordUnionsAcrossCaptures() {
        SelectorInventory.record(ids: ["login_btn", "email"], platform: "ios", at: url)
        SelectorInventory.record(ids: ["email", "home_title"], platform: "ios", at: url)

        let loaded = SelectorInventory.load(at: url)
        XCTAssertEqual(loaded?.ids(platform: "ios"), ["login_btn", "email", "home_title"])
        XCTAssertEqual(loaded?.platforms["ios"]?.captures, 2)
    }

    func testPlatformsAreKeptSeparate() {
        SelectorInventory.record(ids: ["ios_only"], platform: "ios", at: url)
        SelectorInventory.record(ids: ["android_only"], platform: "android", at: url)

        let loaded = SelectorInventory.load(at: url)
        XCTAssertEqual(loaded?.ids(platform: "ios"), ["ios_only"])
        XCTAssertEqual(loaded?.ids(platform: "android"), ["android_only"])
        XCTAssertNil(loaded?.ids(platform: "web"), "記録の無いプラットフォームが空集合として見えている")
    }

    /// 上限に当たっても**既存を消さない**(消すと警告が増える方向 = 誤検知に倒れる)
    func testCapStopsGrowingWithoutDroppingKnownIDs() {
        let first = (0..<SelectorInventory.maxIDs).map { "id_\($0)" }
        SelectorInventory.record(ids: first, platform: "ios", at: url)
        SelectorInventory.record(ids: ["overflow"], platform: "ios", at: url)

        let ids = SelectorInventory.load(at: url)?.ids(platform: "ios")
        XCTAssertEqual(ids?.count, SelectorInventory.maxIDs)
        XCTAssertTrue(ids?.contains("id_0") ?? false, "上限で既存の id を落とした")
        XCTAssertFalse(ids?.contains("overflow") ?? true, "上限を超えて増え続けている")
    }

    /// 版が上がった台帳は**読まない**(読めない形を推測で解釈して誤検知を出さない)
    func testFutureVersionIsIgnored() {
        SelectorInventory.record(ids: ["a"], platform: "ios", at: url)
        var raw = try! String(contentsOf: url, encoding: .utf8)
        raw = raw.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        try! raw.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(SelectorInventory.load(at: url), "未来の版を読んでしまった")
    }

    func testIDsFromSnapshotSkipUnidentifiedElements() {
        let snapshot = SnapshotResponse(
            sessionBundleID: nil,
            screen: FTRect(x: 0, y: 0, width: 100, height: 100),
            elements: [
                ElementInfo(ref: 1, type: "button", identifier: "ok", label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 1, height: 1), depth: 0),
                ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "ラベルだけ",
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 1, height: 1), depth: 0),
                ElementInfo(ref: 3, type: "other", identifier: "", label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 1, height: 1), depth: 0),
            ],
            truncatedCount: 0)
        XCTAssertEqual(SelectorInventory.ids(in: snapshot), ["ok"])
    }

    // MARK: - 照合対象の抽出

    /// スコープ・相対の対象・除外条件の中の id も**実在していなければならない**ので拾う。
    /// ワイルドカード(`#row_*`)は台帳に無くて当然なので拾わない
    func testExactIDsWalkTheWholeLocatorTree() {
        var target = FlowLocator(id: "row")
        target.scope = [FlowLocator(id: "list")]
        target.not = [FlowLocator(id: "excluded")]
        target.relative = [FlowRelativeStep(direction: .right,
                                            filter: [FlowLocator(id: "switch_wifi")])]
        XCTAssertEqual(Set(SelectorInventory.exactIDs(in: target)),
                       ["row", "list", "excluded", "switch_wifi"])

        var wildcard = FlowLocator(id: "row_")
        wildcard.idMatch = .startsWith
        XCTAssertEqual(SelectorInventory.exactIDs(in: wildcard), [],
                       "ワイルドカードの id を完全一致で照合しようとしている")
    }
}
