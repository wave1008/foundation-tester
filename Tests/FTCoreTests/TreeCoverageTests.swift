// 「木が画面を代表していない」判定の共有(2026-08-15)。
//
// 2つを守る:
//   1. **MCP と DSL が同じ答えを出す** —— 判定は `TreeCoverage` の1本で、MCP の
//      webViewGapNote / missingPageContentNote はその文言。実アプリの固定コーパスで
//      発火する画面の集合を**等号で**固定する(片方だけ動いたら落ちる)。
//   2. **DSL の否定アサーションが黙らない** —— 空の木・部分的な木では notExist が必ず通るので、
//      緑であることは証拠にならない。注記が付くことを直接見る。
//
// 誤検知0の確認もここで兼ねる: 自前 SUT(`sut-`/`sutec-`)とネイティブ画面は1枚も発火しない。

import XCTest
@testable import FTCore

final class TreeCoverageTests: XCTestCase {

    // MARK: - 固定コーパス

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)      // Tests/FTCoreTests/このファイル
            .deletingLastPathComponent()      // Tests/FTCoreTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/RealAppSnapshots")
    }

    private func corpus() throws -> [(name: String, snapshot: SnapshotResponse)] {
        try FileManager.default.contentsOfDirectory(atPath: Self.fixtureDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { file in
                let url = Self.fixtureDirectory.appendingPathComponent(file)
                return (String(file.dropLast(".json".count)),
                        try JSONDecoder().decode(SnapshotResponse.self,
                                                 from: try Data(contentsOf: url)))
            }
    }

    /// **等号で固定する**(部分集合ではない)。増えたら1件ずつ見て真陽性だと確かめてから直すこと ——
    /// 黙って足すとこの砦は現状追認装置になる。値は `NoteCoverageTests` の
    /// webViewGapNote の baseline と一致していなければならない(同じ判定の別の呼び手)
    private let expectedGapFixtures: Set<String> = [
        "and-browser_weather", "and-browser_weather_weekly", "and-browser_weektable",
    ]

    /// 同上。`NoteCoverageTests` の missingPageContentNote の baseline と一致
    private let expectedMissingContentFixtures: Set<String> = ["and-browser_jma_notree"]

    func testGapFiresOnExactlyTheKnownBrowserScreens() throws {
        let fired = Set(try corpus().filter { TreeCoverage.gap(in: $0.snapshot) != nil }.map(\.name))
        XCTAssertEqual(fired, expectedGapFixtures,
                       "webView の空白帯が発火する画面が変わった。増分を1件ずつ検分すること")
    }

    func testMissingPageContentFiresOnExactlyTheKnownScreen() throws {
        let fired = Set(try corpus().filter { TreeCoverage.missingPageContent(in: $0.snapshot) }
            .map(\.name))
        XCTAssertEqual(fired, expectedMissingContentFixtures)
    }

    /// **誤検知0**: 自前 SUT とネイティブ画面は1枚も疑われない。ここが破れると
    /// DSL の全シナリオに `treeUnderreported` が付き、注記が意味を失う
    func testNoNativeScreenIsSuspected() throws {
        let suspected = try corpus()
            .filter { TreeCoverage.underreports($0.snapshot) }
            .map(\.name)
        XCTAssertTrue(suspected.allSatisfy { $0.hasPrefix("and-browser") },
                      "ブラウザ以外の画面が疑われた: \(suspected)")
    }

    /// 2つの原因の**和**であること(片方だけ配線した変異を殺す)
    func testUnderreportsIsTheUnionOfBothCauses() throws {
        let fired = Set(try corpus().filter { TreeCoverage.underreports($0.snapshot) }.map(\.name))
        XCTAssertEqual(fired, expectedGapFixtures.union(expectedMissingContentFixtures))
    }

    // MARK: - 閾値(合成木で境界を撃つ)

    private let screen = FTRect(x: 0, y: 0, width: 1000, height: 1000)

    /// 容器いっぱいの webView と、`bandHeight` の空白を挟んで上下に葉を置いた木。
    /// 帯は上端にも下端にも接しない(接する帯は数えない仕様)
    private func treeWithBand(height bandHeight: Double) -> SnapshotResponse {
        let gapTop = 200.0
        let leaves: [ElementInfo] = [
            ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "top", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 1000, height: gapTop), depth: 2),
            ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "bottom", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: gapTop + bandHeight, width: 1000,
                                      height: 1000 - gapTop - bandHeight), depth: 2),
        ]
        let container = ElementInfo(ref: 1, type: "webView", identifier: "page", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 1000, height: 1000), depth: 1)
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [container] + leaves, truncatedCount: 0)
    }

    /// 容器比 8% を下回る帯では騒がない。**容器 = 画面いっぱい**の木なので、ここで効いているのは
    /// 容器比のほう(画面比を単独で確かめるのは下の test)
    func testASmallBandRelativeToItsContainerIsIgnored() {
        XCTAssertNotNil(TreeCoverage.gap(in: treeWithBand(height: 120)),
                        "容器比 12% / 画面比 12% の帯は発火するはず")
        XCTAssertNil(TreeCoverage.gap(in: treeWithBand(height: 40)),
                     "容器比 4% の帯で騒いではいけない")
    }

    /// **画面比の下限が単独で効くこと**。容器が画面の一部しか占めない木でないと2つの閾値は
    /// 区別できない —— 容器 = 画面の木だけで確かめると、画面比を 0 にする変異が生き残る
    /// (実際に生き残った。2026-08-15 の変異チェック)。
    /// 帯は容器の 20%(容器比は通る)だが画面の 4%(画面比で落ちる)
    func testTheScreenFractionFloorAloneSilencesASmallContainer() {
        let containerTop = 100.0, containerHeight = 200.0, band = 40.0
        let container = ElementInfo(ref: 1, type: "webView", identifier: "page", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: containerTop, width: 1000,
                                                 height: containerHeight), depth: 1)
        let top = ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "top", value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: containerTop, width: 1000, height: 80),
                              depth: 2)
        let bottom = ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "bottom",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: containerTop + 80 + band, width: 1000,
                                               height: containerHeight - 80 - band), depth: 2)
        let tree = SnapshotResponse(sessionBundleID: nil, screen: screen,
                                    elements: [container, top, bottom], truncatedCount: 0)
        XCTAssertGreaterThan(band / containerHeight, TreeCoverage.gapBandContainerFraction,
                             "前提: 容器比では通る帯であること")
        XCTAssertLessThan(band / screen.height, TreeCoverage.gapBandScreenFraction,
                          "前提: 画面比では落ちる帯であること")
        XCTAssertNil(TreeCoverage.gap(in: tree),
                     "画面の 4% の穴で騒いではいけない(小さな容器の中の小さな穴)")
    }

    /// **上端に接する帯は数えない**(容器の余白はどのページにもある)。
    /// 上の葉を外すと同じ大きさの空白が上端に接する形になり、黙るのが正しい
    func testABandTouchingTheTopEdgeIsNotCounted() {
        var tree = treeWithBand(height: 300)
        tree.elements = tree.elements.filter { $0.label != "top" }
        XCTAssertNil(TreeCoverage.gap(in: tree))
    }

    /// **葉だけを数える**(容器を数えると、どんな木でも「埋まっている」に見える)。
    ///
    /// 足す容器は**容器より低く**すること: 葉の絞り込みには高さの条件
    /// (`frame.height < 容器の可視高`)もあり、容器と同じ高さの矩形はそちらで落ちるので、
    /// **scrollable/webView を無視する変異を1つも殺せない**(実際に生き残った。2026-08-15)。
    /// ここでは帯(y=200..500)をちょうど覆う 400 高の容器を2形とも置く
    func testContainersDoNotFillTheBand() {
        for (type, scrollable) in [("scrollView", true), ("webView", nil as Bool?)] {
            var tree = treeWithBand(height: 300)
            tree.elements.append(ElementInfo(ref: 9, type: type, identifier: "inner", label: nil,
                                            value: nil, placeholder: nil, enabled: true,
                                            frame: FTRect(x: 0, y: 150, width: 1000, height: 400),
                                            depth: 2, scrollable: scrollable))
            XCTAssertNotNil(TreeCoverage.gap(in: tree),
                            "\(type) が帯を埋めたことにされた(葉だけを数えていない)")
        }
    }

    /// **アドレス欄が無ければ黙る**: 空白率だけで判定するとネイティブ画面まで拾う
    /// (地図の `and-overflow` は 0.564 に達するが、ブラウザではないので黙るべき)
    func testMissingPageContentRequiresAnAddressBar() {
        let blank = SnapshotResponse(
            sessionBundleID: nil, screen: screen,
            elements: [ElementInfo(ref: 1, type: "other", identifier: "top_strip", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 1000, height: 50), depth: 1)],
            truncatedCount: 0)
        XCTAssertGreaterThan(TreeCoverage.unrepresentedScreenFraction(blank),
                             TreeCoverage.missingPageContentFractionThreshold)
        XCTAssertFalse(TreeCoverage.missingPageContent(in: blank), "アドレス欄が無いので黙るはず")

        var browser = blank
        browser.elements.append(ElementInfo(ref: 2, type: "textField", identifier: "url_bar",
                                           label: nil, value: "https://example.com",
                                           placeholder: nil, enabled: true,
                                           frame: FTRect(x: 0, y: 0, width: 1000, height: 50),
                                           depth: 1))
        XCTAssertTrue(TreeCoverage.missingPageContent(in: browser))
    }

    /// **webView が居る画面では黙る**(そちらは `gap` の担当。二重に言わない)
    func testMissingPageContentStaysSilentWhenAWebViewExists() {
        var tree = treeWithBand(height: 300)
        tree.elements.append(ElementInfo(ref: 8, type: "textField", identifier: "url_bar",
                                         label: nil, value: "https://example.com",
                                         placeholder: nil, enabled: true,
                                         frame: FTRect(x: 0, y: 0, width: 1000, height: 50),
                                         depth: 1))
        XCTAssertFalse(TreeCoverage.missingPageContent(in: tree))
    }
}

/// 与えた木をそのまま返すドライバ(DSL 配線の確認用)
private final class FixedTreeDriver: AppDriver {
    private let response: SnapshotResponse

    init(_ response: SnapshotResponse) { self.response = response }

    func snapshot() async throws -> SnapshotResponse { response }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// 否定アサーションが**通った回に**注記を運ぶこと。緑は証拠にならないので直接見る
final class TreeCoverageStepNoteTests: XCTestCase {

    /// webView の内側に大きな空白帯がある木(TreeCoverageTests の合成木と同じ形)
    private func gappyTree() -> SnapshotResponse {
        let container = ElementInfo(ref: 1, type: "webView", identifier: "page", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 1000, height: 1000), depth: 1)
        let top = ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "top", value: nil,
                              placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 1000, height: 200), depth: 2)
        let bottom = ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "bottom",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 500, width: 1000, height: 500), depth: 2)
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 1000, height: 1000),
                                elements: [container, top, bottom], truncatedCount: 0)
    }

    /// 同じ木から空白帯だけを埋めたもの(陰性対照)
    private func fullTree() -> SnapshotResponse {
        var tree = gappyTree()
        tree.elements.append(ElementInfo(ref: 4, type: "staticText", identifier: nil,
                                         label: "middle", value: nil, placeholder: nil,
                                         enabled: true,
                                         frame: FTRect(x: 0, y: 200, width: 1000, height: 300),
                                         depth: 2))
        return tree
    }

    func testAPassingAbsenceOnAnUnderreportedTreeCarriesTheNote() async {
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "submit"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: FixedTreeDriver(gappyTree())).execute(step)
        XCTAssertTrue(outcome.notes.contains(.treeUnderreported),
                      "部分的な木で成立した不在が黙って通った: \(outcome.notes) / \(outcome.status)")
    }

    /// **陰性対照**: 帯が埋まっていれば付かない(常に出す変異を殺す)
    func testACompleteTreeCarriesNoNote() async {
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "submit"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: FixedTreeDriver(fullTree())).execute(step)
        XCTAssertFalse(outcome.notes.contains(.treeUnderreported), "\(outcome.notes)")
    }

    /// **判定に木を使う4経路すべてに載る**(`noteEmptyWebView` と同じ配線)。
    /// 片方だけに載せると、同じ木で下した判断なのに注記の有無が分岐で変わる
    func testTheNoteReachesEveryJudgingPath() async {
        let steps: [(String, FlowStep)] = [
            ("count", FlowStep(assert: "count", locator: FlowLocator(id: "submit"),
                               timeout: 0, expectedCount: 0)),
            ("exists", FlowStep(assert: "exists", locator: FlowLocator(id: "submit"),
                                timeout: 0, occlusionGuard: false)),
            ("textNotEquals", FlowStep(assert: "textNotEquals", locator: FlowLocator(id: "submit"),
                                       expected: "送信", timeout: 0, occlusionGuard: false)),
        ]
        for (name, step) in steps {
            let outcome = await StepExecutor(driver: FixedTreeDriver(gappyTree())).execute(step)
            XCTAssertTrue(outcome.notes.contains(.treeUnderreported),
                          "\(name) が黙った: \(outcome.notes) / \(outcome.status)")
        }
    }
}
