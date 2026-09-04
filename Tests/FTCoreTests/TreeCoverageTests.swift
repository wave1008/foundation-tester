// 「木が画面を代表していない」判定の共有。
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
import FTTestSupport

final class TreeCoverageTests: XCTestCase {

    // MARK: - 固定コーパス

    private func corpus() throws -> [(name: String, snapshot: SnapshotResponse)] {
        try RealAppSnapshotCorpus.all()
    }

    /// **等号で固定する**(部分集合ではない)。増えたら1件ずつ見て真陽性だと確かめてから直すこと ——
    /// 黙って足すとこの砦は現状追認装置になる。値は `NoteCoverageTests` の
    /// webViewGapNote の baseline と一致していなければならない(同じ判定の別の呼び手)
    private let expectedGapFixtures: Set<String> = [
        "and-browser_weather", "and-browser_weather_weekly", "and-browser_weektable",
        // 2026-08-15 に足した J1順位表(gridWithoutHeaderNote の誤検知修正の witness 対)。
        // iOS 側だけが season セレクタ(「2026/27」)を a11y から落としており、**初めて iOS 単独**
        // (Android 対になし)で発火した真陽性
        "ios-browser_j1_standings",
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
    /// DSL の全シナリオに `treeUnderreported` が付き、注記が意味を失う。
    /// **接頭辞はブラウザなら何でもよい**(2026-08-15 に `ios-browser_j1_standings` が加わり、
    /// `and-browser` 限定では真陽性まで弾いてしまうようになった)——見ているのは「ネイティブ画面が
    /// 疑われないこと」であって「Android の Chrome だけが疑われること」ではない
    func testNoNativeScreenIsSuspected() throws {
        let suspected = try corpus()
            .filter { TreeCoverage.underreports($0.snapshot) }
            .map(\.name)
        XCTAssertTrue(suspected.allSatisfy { $0.contains("browser") },
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
                                   frame: FTRect(x: 0, y: 0, width: 1000, height: 1000), depth: 1,
                                   scrollable: true)
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [container] + leaves, truncatedCount: 0)
    }

    /// **viewport に収まりきるページでは空白帯を証拠にしない**(2026-08-15 の監査ラウンドの witness:
    /// Chrome の `DNS_PROBE_FINISHED_NXDOMAIN` エラーページが容器の 75% を「落ちたかもしれない」と
    /// 警告していたが、スクリーンショットでは本当に白紙だった)。
    ///
    /// **両方向に掛ける** —— 証拠を消す変異(常に黙る)と、証拠を無視する変異(常に鳴る)の
    /// どちらも殺せるように、同じ帯で「鳴らない木」と「鳴る木」を並べる。
    /// 証拠の形は OS で違うので**2つとも**確かめる(Android=スクロール容器 / iOS=画面外ノード)
    func testABandInAPageThatFitsTheViewportIsNotEvidence() {
        let fitting = withoutBeyondViewportEvidence(treeWithBand(height: 400))
        XCTAssertNil(TreeCoverage.gap(in: fitting),
                     "収まりきるページの空白帯は「木が落とした」証拠にならない"
                     + "(白紙のページと幾何では区別できない)")
        XCTAssertNotNil(TreeCoverage.gap(in: treeWithBand(height: 400)),
                        "前提: 同じ帯はスクロール容器の申告があれば発火すること")
        let offscreenOnly = SnapshotResponse(
            sessionBundleID: nil, screen: screen, elements: fitting.elements, truncatedCount: 0,
            offscreen: [ElementInfo(ref: 99, type: "staticText", identifier: nil, label: "below",
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 3000, width: 1000, height: 40),
                                    depth: 2)])
        XCTAssertNotNil(TreeCoverage.gap(in: offscreenOnly),
                        "画面外ノードの報告だけでもページは viewport の外へ続いている"
                        + "(iOS の webView は scrollable を申告しない)")
    }

    /// `scrollable` の申告だけを落とした同じ木(他は1バイトも変えない)
    private func withoutBeyondViewportEvidence(_ tree: SnapshotResponse) -> SnapshotResponse {
        let elements = tree.elements.map { element -> ElementInfo in
            guard element.type == "webView" else { return element }
            return ElementInfo(ref: element.ref, type: element.type,
                               identifier: element.identifier, label: element.label,
                               value: element.value, placeholder: element.placeholder,
                               enabled: element.enabled, frame: element.frame,
                               depth: element.depth, scrollable: nil)
        }
        return SnapshotResponse(sessionBundleID: nil, screen: tree.screen, elements: elements,
                                truncatedCount: 0)
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
                                                 height: containerHeight), depth: 1,
                                   scrollable: true)
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

    // MARK: - 高さ条件はテキストを持たない要素にだけ効く(2026-08-15 レビュー修正)

    /// ヘッダ(0-100)+3000pt の本文(100-3100)+フッタ(700-1000)。本文が可視高(1000)より
    /// 高いラッパーと区別できないまま除外されると、埋まっている 100-700 が空白帯に見える
    private func treeWithTallLeaf(bodyLabel: String?, bodyValue: String?) -> SnapshotResponse {
        let container = ElementInfo(ref: 1, type: "webView", identifier: "page", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 1000, height: 1000), depth: 1,
                                   scrollable: true)
        let header = ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "header",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 1000, height: 100), depth: 2)
        let body = ElementInfo(ref: 3, type: "staticText", identifier: nil, label: bodyLabel,
                               value: bodyValue, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 100, width: 1000, height: 3000), depth: 2)
        let footer = ElementInfo(ref: 4, type: "staticText", identifier: nil, label: "footer",
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 700, width: 1000, height: 300), depth: 2)
        return SnapshotResponse(sessionBundleID: nil, screen: screen,
                                elements: [container, header, body, footer], truncatedCount: 0)
    }

    /// 確定トレースそのもの: ラベル付きの縦長本文は可視高より高くても覆いに数える(誤検知の直し)
    func testATallLabeledLeafCoversTheBandItSpans() throws {
        let tree = treeWithTallLeaf(bodyLabel: "article body text", bodyValue: nil)
        XCTAssertFalse(TreeCoverage.underreports(tree),
                       "ラベル付き本文で埋まっている帯が空白と誤報告された")
    }

    /// ラベルも値も持たない同じ形(全面ラッパー)は従来どおり覆いに数えない ——
    /// 高さ条件の役目(ラッパーの除外)が残っていること。逆方向の変異を殺す
    func testATallUnlabeledLeafStillDoesNotCoverTheBand() throws {
        let tree = treeWithTallLeaf(bodyLabel: nil, bodyValue: nil)
        XCTAssertNotNil(TreeCoverage.gap(in: tree),
                        "ラベルも値も無い全面ラッパーが覆いにされた(高さ条件が効いていない)")
    }

    /// OR のもう一方の枝: value だけ(label は nil)でも覆いになる
    func testATallLeafWithOnlyAValueCoversTheBand() throws {
        let tree = treeWithTallLeaf(bodyLabel: nil, bodyValue: "27.4")
        XCTAssertNil(TreeCoverage.gap(in: tree),
                     "value だけ持つ縦長葉が覆いにされなかった")
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

    /// **打ち切られた木からは結論しない**(2026-08-15 の witness: `maxElements: 6` で撮った
    /// Chrome のエラーページが「webView 容器すら無い」と断言した。既定の上限で読み直すと在る)。
    /// 材料が3つとも「要素が無いこと」なので、**上限で落とされただけの木でも同じように真になる**
    func testMissingPageContentIsNotConcludedFromATruncatedTree() {
        let elements = [
            ElementInfo(ref: 1, type: "other", identifier: "top_strip", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 1000, height: 50), depth: 1),
            ElementInfo(ref: 2, type: "textField", identifier: "url_bar", label: nil,
                        value: "https://example.com", placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 1000, height: 50), depth: 1),
        ]
        let whole = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements,
                                     truncatedCount: 0)
        XCTAssertTrue(TreeCoverage.missingPageContent(in: whole),
                      "前提: 打ち切りが無ければこの木は真陽性の形")
        let truncated = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements,
                                         truncatedCount: 1)
        XCTAssertFalse(TreeCoverage.missingPageContent(in: truncated),
                       "落とされた要素を「公開されていない」と読んではいけない"
                       + "(件数は truncationNote が別に言う)")
        XCTAssertFalse(TreeCoverage.underreports(truncated),
                       "否定アサーションの裏取りにもこの疑いを持ち込まないこと")
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

    // MARK: - モーダルがアドレス欄ごと木を置き換える形(2026-09-01・実機 iPhone 13)

    func testAModalThatRemovedTheAddressBarIsStillSuspected() {
        let tree = modalCollapsedBrowserTree()
        XCTAssertNil(TreeCoverage.addressBarCandidate(in: tree),
                     "前提: モーダルがアドレス欄ごと消した木であること")
        XCTAssertGreaterThan(TreeCoverage.unrepresentedScreenFraction(tree), 0.5)
        XCTAssertTrue(TreeCoverage.missingPageContent(in: tree),
                      "画面に見えているページが木から消えているのに疑われなかった")
        XCTAssertTrue(TreeCoverage.underreports(tree))
    }

    /// **陰性対照①**: 同じ形でもブラウザでなければ黙る(空白率だけで判定する変異を殺す)。
    /// ネイティブアプリのモーダルは正当に疎な画面と区別できないので、ここは見逃す側に倒してある
    func testTheSameShapeInANativeAppIsNotSuspected() {
        let native = modalCollapsedBrowserTree(session: "com.sutec.mobile")
        XCTAssertFalse(TreeCoverage.missingPageContent(in: native))
        XCTAssertFalse(TreeCoverage.underreports(native))
    }

    /// **陰性対照②**: ブラウザでも本文が木に在れば黙る(常に真を返す変異を殺す)
    func testABrowserTreeThatPublishesItsPageIsNotSuspected() {
        var filled = modalCollapsedBrowserTree()
        filled.elements.append(ElementInfo(ref: 7, type: "staticText", identifier: nil,
                                           label: "Example Domain", value: "Example Domain",
                                           placeholder: nil, enabled: true,
                                           frame: FTRect(x: 78, y: 0, width: 187, height: 441),
                                           depth: 8))
        XCTAssertLessThan(TreeCoverage.unrepresentedScreenFraction(filled), 0.5)
        XCTAssertFalse(TreeCoverage.missingPageContent(in: filled))
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
                                   frame: FTRect(x: 0, y: 0, width: 1000, height: 1000), depth: 1,
                                   scrollable: true)
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
        let outcome = await StepExecutor(driver: FixedTreeDriver(gappyTree()), isAndroid: false).execute(step)
        XCTAssertTrue(outcome.notes.contains(.treeUnderreported),
                      "部分的な木で成立した不在が黙って通った: \(outcome.notes) / \(outcome.status)")
    }

    /// **陰性対照**: 帯が埋まっていれば付かない(常に出す変異を殺す)
    func testACompleteTreeCarriesNoNote() async {
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "submit"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: FixedTreeDriver(fullTree()), isAndroid: false).execute(step)
        XCTAssertFalse(outcome.notes.contains(.treeUnderreported), "\(outcome.notes)")
    }

    /// count も不在を結論するので同じ注記が要る
    func testTheNoteAlsoReachesCount() async {
        let step = FlowStep(assert: "count", locator: FlowLocator(id: "submit"),
                            timeout: 0, expectedCount: 0)
        let outcome = await StepExecutor(driver: FixedTreeDriver(gappyTree()), isAndroid: false).execute(step)
        XCTAssertTrue(outcome.notes.contains(.treeUnderreported), "count: \(outcome.notes)")
    }

    /// **肯定側には載せない**(2026-08-15 のデバイス実行で確定)。隣の `noteEmptyWebView` は
    /// 4経路すべてから呼ぶので揃えたくなるが、こちらは a11y に出ない部分がある WebView なら
    /// **どの画面でも立つ**。4経路へ広げたところ、5 SUT の緑の run すべてで
    /// `exist "WebView 画面外テキスト"` に毎回付いた(真陽性だが**毎回出る注記は率を見る役に
    /// 立たない**うえ、通った `exist` に「不在の証拠にならない」と書くのは噛み合わない)
    func testAPositiveAssertDoesNotCarryTheNote() async {
        let step = FlowStep(assert: "exists", locator: FlowLocator(label: "top"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: FixedTreeDriver(gappyTree()), isAndroid: false).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertFalse(outcome.notes.contains(.treeUnderreported),
                       "通った肯定形に付いた: \(outcome.notes)")
    }

    /// モーダルで消えた本文への不在も注記まで届くこと(判定は TreeCoverageTests 側)
    func testTheModalTreeMakesAPassingAbsenceCarryTheNote() async {
        let step = FlowStep(assert: "notExists", locator: FlowLocator(label: "Example Domain"),
                            timeout: 0, occlusionGuard: false)
        let outcome = await StepExecutor(driver: FixedTreeDriver(modalCollapsedBrowserTree()),
                                         isAndroid: false).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertTrue(outcome.notes.contains(.treeUnderreported),
                      "モーダルで消えた本文への notExists が黙って通った: \(outcome.notes)")
    }
}


/// 実測の転記: Safari で example.com を**表示したまま**「さらに表示」メニューを開くと、
/// 木はメニューの部分木 22 要素だけになり、ページ本文・アドレス欄・ツールバーが消える
/// (画面 390x844 / 上から 441pt = 52.3% に要素が1つも無い)。ここでは形が同じ骨だけを置く。
/// **アドレス欄が無いのが要点** —— 悪い形ほど検知が外れていた
func modalCollapsedBrowserTree(session: String? = "com.apple.mobilesafari") -> SnapshotResponse {
    func button(_ ref: Int, _ identifier: String?, _ label: String,
                _ frame: FTRect, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: identifier, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: depth)
    }
    let menu = ElementInfo(ref: 1, type: "collectionView", identifier: nil, label: nil,
                           value: nil, placeholder: nil, enabled: true,
                           frame: FTRect(x: 106, y: 441, width: 250, height: 844), depth: 7,
                           scrollable: true)
    return SnapshotResponse(
        sessionBundleID: session, screen: FTRect(x: 0, y: 0, width: 390, height: 844),
        elements: [
            menu,
            button(2, "ShareButton", "共有", FTRect(x: 106, y: 451, width: 250, height: 42), depth: 9),
            button(3, nil, "ブックマークに追加", FTRect(x: 106, y: 493, width: 250, height: 42), depth: 9),
            button(4, "NewTabButton", "新規タブ", FTRect(x: 106, y: 618, width: 250, height: 42), depth: 9),
            button(5, "SidebarButton", "ブックマーク", FTRect(x: 114, y: 733, width: 117, height: 77), depth: 9),
            button(6, "TabOverviewButton", "すべてのタブ", FTRect(x: 231, y: 733, width: 117, height: 77), depth: 9),
        ],
        truncatedCount: 0)
}
