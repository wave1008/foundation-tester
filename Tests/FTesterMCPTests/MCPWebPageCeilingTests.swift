// 切り詰められた **web ページ**は、言われる前に要素上限の天井で撮り直す(2026-08-15 の外部評価:
// 1セッションで 89 件と 72 件を落とされた)。
//
// DSL には同じ撮り直し(`StepExecutor.retakenAtElementLimitCeiling`)が既にあったが、**MCP は
// 別経路なので届いていなかった** —— 注記で「maxElements を上げろ」と案内するだけで、読み手は
// 必ず1往復を払い、注記を見落とせば実在する行を存在しないものとして扱う。
//
// 規律は3つ。**web だけ**(native の密な画面は間引きの規則が違う)/ **ラッチする**
// (2枚払うのは1回だけ。waitFor のポーリングで読みが倍にならない)/ **黙ってやらない**
// (出力量が変わるので初回に名乗る)。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPWebPageCeilingTests: XCTestCase {

    private func tree(_ count: Int, truncated: Int, webView: Bool) -> SnapshotResponse {
        var elements: [ElementInfo] = []
        if webView {
            elements.append(ElementInfo(ref: 1, type: "webView", identifier: "WebView", label: nil,
                                        value: nil, placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: 0, width: 402, height: 800), depth: 1))
        }
        for i in 0..<count {
            elements.append(ElementInfo(ref: i + 2, type: "staticText", identifier: nil,
                                        label: "row\(i)", value: nil, placeholder: nil,
                                        enabled: true,
                                        frame: FTRect(x: 0, y: Double(i) * 10, width: 100,
                                                      height: 9),
                                        depth: 2))
        }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: truncated)
    }

    private func makeServer(_ driver: FakeDriver) -> MCPServer {
        MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// 切り詰められた web の木は、その場で天井で撮り直したものが返る
    func testTruncatedWebPageIsRetakenAtTheCeiling() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [tree(120, truncated: 89, webView: true),
                                    tree(209, truncated: 0, webView: true)]
        let text = body(try await makeServer(driver).call(tool: "ft_snapshot", args: [:]))

        XCTAssertTrue(text.contains("row208"), "天井で撮り直した木が返っていない")
        XCTAssertTrue(text.contains("taken at the \(BridgeAPI.maxSnapshotElementsCeiling)-element"),
                      "勝手に上限を上げたことを名乗っていない: \(text)")
    }

    /// **native の密な画面は対象外**(間引きの規則が違う。web だけを対象にする根拠は
    /// `needsWebPageCeiling` の doc)。ここまで広げると、地図や長いリストで毎回
    /// 400 行が返る
    func testTruncatedNativeScreenIsLeftAlone() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [tree(120, truncated: 89, webView: false),
                                    tree(209, truncated: 0, webView: false)]
        let text = body(try await makeServer(driver).call(tool: "ft_snapshot", args: [:]))

        XCTAssertFalse(text.contains("row208"), "native の画面まで撮り直している")
        XCTAssertFalse(text.contains("-element ceiling instead"), text)
    }

    /// **既に天井で読まれた木は撮り直さない**(同じ木がもう1枚返るだけ)
    func testTreeAlreadyAtTheCeilingIsNotRetaken() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [tree(BridgeAPI.maxSnapshotElementsCeiling, truncated: 12,
                                         webView: true)]
        _ = try await makeServer(driver).call(tool: "ft_snapshot", args: [:])

        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("snapshot") }.count, 1,
                       "天井の木を撮り直している: \(driver.calls)")
    }

    /// **ラッチする**: 2回目以降は最初から天井で撮るので、読みは1枚に戻る。
    /// これが無いと waitFor のポーリングで毎周2枚払う
    func testSecondReadCostsOnlyOneSnapshot() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [tree(120, truncated: 89, webView: true),
                                    tree(209, truncated: 0, webView: true)]
        let server = makeServer(driver)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let afterFirst = driver.calls.filter { $0.hasPrefix("snapshot") }.count
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let afterSecond = driver.calls.filter { $0.hasPrefix("snapshot") }.count

        XCTAssertEqual(afterFirst, 2, "1回目は撮り直しの2枚のはず: \(driver.calls)")
        XCTAssertEqual(afterSecond - afterFirst, 1, "2回目も2枚払っている: \(driver.calls)")
    }

    /// **明示された maxElements は素通し**(読み手の指定を勝手に上書きしない)
    func testExplicitMaxElementsIsNotOverridden() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [tree(120, truncated: 89, webView: true),
                                    tree(209, truncated: 0, webView: true)]
        _ = try await makeServer(driver).call(tool: "ft_snapshot", args: ["maxElements": 150])

        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("snapshot") }.count, 1,
                       "指定があるのに撮り直している: \(driver.calls)")
    }

    /// 実コーパスの Android ブラウザ(切り詰めあり)で発火すること
    func testAndroidBrowserFixtureFires() throws {
        let chrome = try fixture("and-browser_j1_standings")
        XCTAssertGreaterThan(chrome.truncatedCount, 0, "コーパスの形が変わった")
        XCTAssertTrue(MCPServer.needsWebPageCeiling(chrome))
    }

    /// **本命**(2026-08-15 の2度目の追試): iOS Safari の a11y 木は `webView` 要素を
    /// **出したり出さなかったりする**。ブラウザ chrome もスクロールで木から落ちる。
    /// どちらも「そのとき何が公開されたか」に依存するので、**セッションのアプリ**で判定する
    func testBrowserSessionCountsEvenWhenNothingInTheTreeSaysWeb() {
        let bare = SnapshotResponse(sessionBundleID: "com.apple.mobilesafari",
                                    screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                    elements: tree(120, truncated: 89, webView: false).elements,
                                    truncatedCount: 89)
        XCTAssertFalse(bare.elements.contains { $0.type == "webView" })
        XCTAssertNil(TreeCoverage.addressBarCandidate(in: bare))
        XCTAssertTrue(MCPServer.needsWebPageCeiling(bare),
                      "ブラウザのセッションなのに web と見なせていない")
    }

    /// **アプリ内 WebView は DOM 由来の印で拾う**(ブラウザではないのでセッションでは拾えない)
    func testInAppWebContentCountsViaTheWebFlag() {
        var elements = tree(120, truncated: 89, webView: false).elements
        elements[0] = ElementInfo(ref: elements[0].ref, type: "staticText", identifier: nil,
                                  label: "body", value: nil, placeholder: nil, enabled: true,
                                  frame: elements[0].frame, depth: 2, web: true)
        let snapshot = SnapshotResponse(sessionBundleID: "com.example.app",
                                        screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: elements, truncatedCount: 89)
        XCTAssertTrue(MCPServer.needsWebPageCeiling(snapshot))
    }

    /// **webView 要素が1つも無いブラウザの木**でも、アドレス欄があれば web と見なす。
    /// Chrome は「ページ本体どころか webView 容器すら a11y に出さない」状態を取り得る
    /// (`missingPageContentNote` が扱う形。デバイスで実際に観測した)
    func testBrowserChromeWithoutAWebViewElementCountsViaTheAddressBar() {
        let addressBar = ElementInfo(ref: 1, type: "textField", identifier: "url_bar", label: nil,
                                     value: "tenki.jp", placeholder: nil, enabled: true,
                                     frame: FTRect(x: 0, y: 0, width: 400, height: 40), depth: 1)
        var elements = tree(120, truncated: 81, webView: false).elements
        elements.append(addressBar)
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: elements, truncatedCount: 81)
        XCTAssertTrue(MCPServer.needsWebPageCeiling(snapshot))
    }

    /// **待ちの経路にも上限が要る**(2026-08-15 の実害): 最初の1枚は撮り直して天井にするのに、
    /// 直後の waitFor が素の既定で撮り直すため、**返る木は切り詰められたまま**になり
    /// 「maxElements を上げろ」の旧注記が出続けていた
    /// (`raiseElementLimitOnNextSnapshot` は1回ぶんの指定で、最初の読みで消費されている)
    func testWaitForPollingKeepsTheCeilingOnALatchedDevice() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [tree(120, truncated: 81, webView: true),
                                    tree(209, truncated: 0, webView: true)]
        let server = makeServer(driver)
        _ = try await server.call(tool: "ft_snapshot", args: [:])   // ここでラッチ
        driver.elementLimits.removeAll()

        _ = try await server.call(tool: "ft_snapshot",
                                  args: ["waitFor": "#never_appears", "timeout": 0.6])

        XCTAssertGreaterThanOrEqual(
            driver.elementLimits.filter { $0 == BridgeAPI.maxSnapshotElementsCeiling }.count, 2,
            "ポーリングの読みが既定の上限に戻っている: \(driver.elementLimits)")
    }

    /// **コーパス全数で発火する集合を等号で固定する**(増減は1件ずつ検分してから更新)。
    /// `ios-news_feed` はアプリ内 WebView のフィード —— アドレス欄は無いが webView 要素で拾う
    func testFiringSetOverTheWholeCorpus() throws {
        var fired: [String] = []
        for name in try fixtureNames() where MCPServer.needsWebPageCeiling(try fixture(name)) {
            fired.append(name)
        }
        XCTAssertEqual(fired.sorted(),
                       ["and-browser_j1_standings", "ios-browser_j1_standings",
                        "ios-browser_nationwide", "ios-browser_startpage", "ios-news_feed"],
                       "撮り直す画面の集合が変わった。増えた分が本当に web か1件ずつ見ること")
    }

    private func fixture(_ name: String) throws -> SnapshotResponse {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots/\(name).json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    private func fixtureNames() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/RealAppSnapshots")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// 判定そのもの(3条件)
    func testNeedsWebPageCeilingRules() {
        XCTAssertTrue(MCPServer.needsWebPageCeiling(tree(120, truncated: 1, webView: true)))
        XCTAssertFalse(MCPServer.needsWebPageCeiling(tree(120, truncated: 0, webView: true)),
                       "切り詰められていない木を撮り直している")
        XCTAssertFalse(MCPServer.needsWebPageCeiling(tree(120, truncated: 1, webView: false)),
                       "webView の無い画面を撮り直している")
        XCTAssertFalse(MCPServer.needsWebPageCeiling(
            tree(BridgeAPI.maxSnapshotElementsCeiling, truncated: 1, webView: true)),
                       "天井の木を撮り直している")
    }
}
