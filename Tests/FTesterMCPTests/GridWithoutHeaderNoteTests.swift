// gridWithoutHeaderNote(値の格子はあるのに列見出しがツリーに無い形の検知。2026-08-12・作業2)。
//
// 実アプリの witness 対(Tests/Fixtures/RealAppSnapshots):
//   and-browser_weektable … Android Chrome の tenki.jp 2週間天気。日付ヘッダ行がツリーから
//                           欠落 → 発火するべき
//   ios-browser_weektable … 同じページを iOS Safari で採取。見出し行がツリーにある陰性対照
//                           → 発火してはいけない
//
// **全数検証はテストとしても残す**(testFiresOnlyOnTheWeektableWitness): 固定コーパスに
// この検知器を当てて発火するフィクスチャの集合を固定する。増減があれば、それが
// 真陽性かどうかを見てから基準値を更新すること(NoteCoverageTests と同じ規律)。

import XCTest
@testable import ftester_mcp
import FTCore

final class GridWithoutHeaderNoteTests: XCTestCase {

    // MARK: - 合成木(アルゴリズムそのものの単体テスト)

    private func leaf(_ ref: Int, _ label: String, x: Double, y: Double,
                      width: Double = 80, height: Double = 40, depth: Int = 3) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: width, height: height), depth: depth)
    }

    private func webView(width: Double = 300, height: Double = 600) -> ElementInfo {
        ElementInfo(ref: 1, type: "webView", identifier: nil, label: "page", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: width, height: height), depth: 2)
    }

    /// 3列×2行の最小格子。列は centerX ≈ 50/150/250 で揃え、見出しは置かない
    private func minimalGrid(extra: [ElementInfo] = []) -> SnapshotResponse {
        let elements = [webView()]
            + [leaf(2, "A1", x: 10, y: 200), leaf(3, "B1", x: 110, y: 200), leaf(4, "C1", x: 210, y: 200),
               leaf(5, "A2", x: 10, y: 260), leaf(6, "B2", x: 110, y: 260), leaf(7, "C2", x: 210, y: 260)]
            + extra
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 300, height: 600),
                                elements: elements, truncatedCount: 0)
    }

    func testFiresOnASyntheticThreeByTwoGridWithNoHeader() {
        let note = MCPServer.gridWithoutHeaderNote(minimalGrid())
        XCTAssertTrue(note.contains("3x2"), note)
        XCTAssertTrue(note.contains("ft_screenshot"), "確かめる手段まで書くこと: \(note)")
    }

    /// 見出しらしい要素が帯の中にあれば黙る
    func testStaysSilentWhenSomethingOccupiesTheBandAboveTheGrid() {
        let header = leaf(8, "Header", x: 10, y: 170, width: 280, height: 20)
        XCTAssertEqual(MCPServer.gridWithoutHeaderNote(minimalGrid(extra: [header])), "")
    }

    /// **見出し行が入る余地**の境界(gridHeaderRoomRatio)。格子は 200/260 = pitch 60 なので、
    /// 直上の空きが 120pt 未満なら「抜けた行がそこにあった」とは言えない。
    /// 実アプリの誤検知はどれもこの側(比 0.54 と 1.16)だった
    func testStaysSilentWhenThereIsNoRoomForAMissingHeaderRow() {
        // 上の要素の下端 y=130 → 空き 70pt = pitch の 1.17 倍(閾値 2.0 未満)
        let above = leaf(8, "Section", x: 10, y: 110, width: 280, height: 20)
        XCTAssertEqual(MCPServer.gridWithoutHeaderNote(minimalGrid(extra: [above])), "",
                       "pitch の \(MCPServer.gridHeaderRoomRatio) 倍に満たない空きは見出しの跡ではない")
    }

    /// 陽性側の境界: 同じ格子で空きを 130pt(pitch の 2.17 倍)にすると出る
    func testFiresWhenTheGapAboveCouldHoldTheMissingRow() {
        let above = leaf(8, "Section", x: 10, y: 50, width: 280, height: 20)
        XCTAssertTrue(MCPServer.gridWithoutHeaderNote(minimalGrid(extra: [above])).contains("3x2"))
    }

    /// 上端をまたぐ要素は空きを埋めている(空きが負になり下限で弾かれる)。
    /// またぎを無視して下端をそのまま採ると、**格子の上に何か描かれていても出る**
    func testStaysSilentWhenSomethingSpansTheTopOfTheGrid() {
        let spanning = leaf(8, "Banner", x: 10, y: 60, width: 280, height: 180)  // 60→240(格子は 200 から)
        XCTAssertEqual(MCPServer.gridWithoutHeaderNote(minimalGrid(extra: [spanning])), "",
                       "格子の上端をまたぐ要素はその空白を実際に埋めている")
    }

    /// **行間は中央値で採る**(平均ではない)。実測の格子は途中に別セクションの行が挟まって
    /// 間隔が飛ぶ(and-browser_weektable の 53/65/**184**/53/65)ので、平均だと1本の飛びに
    /// 引きずられて閾値が跳ね上がり、**見出しの抜けた本物の格子を黙って見逃す**
    func testPitchIgnoresOneOutlierGapBetweenSections() {
        // 行 100/160/220/600 → 間隔 60,60,380(中央値 60・平均 166)。直上の空きは 150pt =
        // 中央値の 2.5 倍(出る)だが平均の 0.9 倍(平均だと出ない)
        let rows = [leaf(2, "A1", x: 10, y: 100, height: 20), leaf(3, "B1", x: 110, y: 100, height: 20),
                    leaf(4, "C1", x: 210, y: 100, height: 20),
                    leaf(5, "A2", x: 10, y: 160, height: 20), leaf(6, "B2", x: 110, y: 160, height: 20),
                    leaf(7, "C2", x: 210, y: 160, height: 20),
                    leaf(8, "A3", x: 10, y: 220, height: 20), leaf(9, "B3", x: 110, y: 220, height: 20),
                    leaf(10, "C3", x: 210, y: 220, height: 20),
                    leaf(11, "A4", x: 10, y: 600, height: 20), leaf(12, "B4", x: 110, y: 600, height: 20),
                    leaf(13, "C4", x: 210, y: 600, height: 20)]
        let above = leaf(14, "Section", x: 10, y: -70, width: 280, height: 20)  // 下端 -50 → 空き 150
        let snapshot = SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: -100, width: 300, height: 800),
            elements: [ElementInfo(ref: 1, type: "webView", identifier: nil, label: "page",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: -100, width: 300, height: 800), depth: 2)]
                + rows + [above],
            truncatedCount: 0)
        XCTAssertTrue(MCPServer.gridWithoutHeaderNote(snapshot).contains("3x4"),
                      "1本の飛びで閾値が上がってはいけない: "
                      + MCPServer.gridWithoutHeaderNote(snapshot))
    }

    /// webView が無い画面(ネイティブのみ)では判定しない —— 実測(ダイヤルパッド等)で
    /// webView に絞らない版が5件の誤検知を出したための前提
    func testStaysSilentWithoutAWebView() {
        let native = SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 300, height: 600),
            elements: [ElementInfo(ref: 1, type: "clickable", identifier: nil, label: "OK", value: nil,
                                   placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 2)],
            truncatedCount: 0)
        XCTAssertEqual(MCPServer.gridWithoutHeaderNote(native), "")
    }

    // MARK: - 実アプリの witness(固定コーパス)

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
    }

    private func load(_ name: String) throws -> SnapshotResponse {
        let url = Self.fixtureDirectory.appendingPathComponent(name + ".json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    func testFiresOnTheAndroidWeektableWitness() throws {
        let note = MCPServer.gridWithoutHeaderNote(try load("and-browser_weektable"))
        XCTAssertTrue(note.contains("4x6"), note)
        XCTAssertTrue(note.contains("y=1485"), note)
        XCTAssertTrue(note.contains("ft_screenshot"), note)
    }

    /// **陰性対照**: 同じページを iOS Safari で採取した木は見出し行(日付ラベル)がツリーにあるので、
    /// この検知器は沈黙しなければならない
    func testStaysSilentOnTheIOSWeektableWithHeadersPresent() throws {
        XCTAssertEqual(MCPServer.gridWithoutHeaderNote(try load("ios-browser_weektable")), "")
    }

    /// **実アプリで出た誤検知の witness**(2026-08-13・Yahoo!天気を iOS Safari で)。
    /// 週間表は日付(`8/15`…)と曜日(`（土）`…)が木にあるが、**どちらも値のセルと centerX で
    /// 揃っている**ため見出し行が鎖の最上行として取り込まれ、その上の段落間(22pt)が
    /// 「見出しが無い」と読まれていた。行間 19pt に対し空きは 1.16 倍しかない ——
    /// 抜けた行が入る余地が無いので黙るのが正しい
    func testStaysSilentOnTheYahooWeeklyGridWhoseHeaderIsItsTopRow() throws {
        XCTAssertEqual(MCPServer.gridWithoutHeaderNote(try load("ios-browser_weather_weekly")), "",
                       "見出し行が格子の最上行として取り込まれた形で出してはいけない")
    }

    /// **全数検証**: 固定コーパスでこの検知器が発火するフィクスチャの集合を固定する
    /// (2026-08-12 実測: and-browser_weektable の1枚のみ。他29枚は電話キーパッド・写真グリッド・
    /// URL バーのツールバーアイコン列を含め0件 —— 誤検知が出ないことの根拠がこの等号照合)
    func testFiresOnlyOnTheAndroidWeektableWitness() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtureDirectory.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }.sorted()
        var fired: [String] = []
        for name in names {
            let snapshot = try load(name)
            if !MCPServer.gridWithoutHeaderNote(snapshot).isEmpty { fired.append(name) }
        }
        XCTAssertEqual(fired, ["and-browser_weektable"],
                       "発火したフィクスチャの集合が変わった。増えた分は真陽性か誤検知か検分してから"
                       + "この一覧を更新すること: \(fired)")
    }
}
