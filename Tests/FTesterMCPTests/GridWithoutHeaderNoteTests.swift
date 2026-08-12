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
