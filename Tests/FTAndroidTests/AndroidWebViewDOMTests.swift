// Android の web コンテンツを DOM から読む経路の純粋ロジック(`AndroidWebViewDOM`)。
// 対象は**ブラウザ本体**と**テスト対象アプリ自身の WebView**。
//
// I/O(adb / CDP)はデバイスが要るのでここでは触らない。守るのは
// **ソケット/タブを取り違えないこと**(別アプリ・別プロセス・別タブの DOM を読まない)と
// **門の違い**(ブラウザは a11y で足りれば読まない / 自作アプリは足りて見えても読む)。
// 座標の写し・WebView 選択・木への差し込みは `FTCore.WebViewDOM`(iOS と共有)へ移設済みで、
// そちらは `Tests/FTCoreTests/WebViewDOMSnapshotTests.swift` が守る。

import XCTest
import FTCore
@testable import FTAndroid

final class AndroidWebViewDOMTests: XCTestCase {

    // MARK: - ブラウザの判定(既知集合の外はソケット名を持たない = a11y のまま)

    func testKnowsTheChromeSocket() {
        XCTAssertEqual(AndroidWebViewDOM.browserSocketName(packageID: "com.android.chrome"),
                       "chrome_devtools_remote")
    }

    /// 未実測のパッケージには推測で名前を付けない(誤った名前より「対象外」のほうが安全)
    func testUnknownPackageHasNoSocket() {
        XCTAssertNil(AndroidWebViewDOM.browserSocketName(packageID: "com.example.myapp"))
        XCTAssertNil(AndroidWebViewDOM.browserSocketName(packageID: "com.chrome.beta"))
    }

    // MARK: - 自作アプリのソケット名(pid 規則。ブラウザの固定名と混ぜない)

    func testAppSocketNameCarriesThePID() {
        XCTAssertEqual(AndroidWebViewDOM.appSocketName(pid: 5142), "webview_devtools_remote_5142")
    }

    /// 自作アプリのパッケージは**ブラウザの固定名を持たない**(規則が混線すると別プロセスを覗く)
    func testAppPackagesDoNotGetABrowserSocket() {
        XCTAssertNil(AndroidWebViewDOM.browserSocketName(packageID: "com.ftester.e2e"))
    }

    // MARK: - 経路の判定(門はブラウザと自作アプリで違う)

    func testBrowserReadsDOMOnlyWhenA11yIsNotEnough() {
        XCTAssertEqual(AndroidWebViewDOM.route(packageID: "com.android.chrome", hasWebViewNode: true,
                                               a11yLooksSufficient: false, browserDOMEnabled: true,
                                               appWebViewDOMEnabled: true),
                       .browser(socket: "chrome_devtools_remote"))
        XCTAssertEqual(AndroidWebViewDOM.route(packageID: "com.android.chrome", hasWebViewNode: true,
                                               a11yLooksSufficient: true, browserDOMEnabled: true,
                                               appWebViewDOMEnabled: true),
                       .a11y, "a11y で足りているブラウザに DOM の 6〜20 倍のコストを払わない")
    }

    /// **`webView` ノードが無くてもブラウザは読む**(2026-08-14 の監査。Chrome は本文非公開の
    /// 画面でノードごと出さず、そこがまさに DOM の要る場面だった)
    func testBrowserRouteDoesNotRequireAWebViewNode() {
        XCTAssertEqual(AndroidWebViewDOM.route(packageID: "com.android.chrome", hasWebViewNode: false,
                                               a11yLooksSufficient: false, browserDOMEnabled: true,
                                               appWebViewDOMEnabled: true),
                       .browser(socket: "chrome_devtools_remote"))
    }

    /// **この経路の存在理由そのもの**: a11y は版で属性を入れ替える(124=placeholder のみ /
    /// 150=#id のみ)ので、**足りて見えても DOM を正とする**。ここを a11y の充足度で
    /// 切り替えると版差がそのまま残り、混在フリートでセレクタが端末ごとに割れる
    func testAppWebViewIgnoresWhetherA11yLooksSufficient() {
        for sufficient in [true, false] {
            XCTAssertEqual(AndroidWebViewDOM.route(packageID: "com.ftester.e2e", hasWebViewNode: true,
                                                   a11yLooksSufficient: sufficient,
                                                   browserDOMEnabled: true, appWebViewDOMEnabled: true),
                           .appWebView, "a11y の充足度で切り替えてはいけない")
        }
    }

    /// `webView` ノードが無い画面では pid 引きと forward を払わない(自作アプリ側の唯一の門)
    func testAppWithoutAWebViewNodeStaysOnA11y() {
        XCTAssertEqual(AndroidWebViewDOM.route(packageID: "com.ftester.e2e", hasWebViewNode: false,
                                               a11yLooksSufficient: false, browserDOMEnabled: true,
                                               appWebViewDOMEnabled: true),
                       .a11y)
    }

    /// **殺しスイッチは2つで、互いに独立**(束ねると「ブラウザだけ止めて A/B」が取れない)
    func testTheTwoKillSwitchesAreIndependent() {
        // FT_BROWSER_DOM=off はブラウザだけを止める
        XCTAssertEqual(AndroidWebViewDOM.route(packageID: "com.android.chrome", hasWebViewNode: true,
                                               a11yLooksSufficient: false, browserDOMEnabled: false,
                                               appWebViewDOMEnabled: true),
                       .a11y)
        XCTAssertEqual(AndroidWebViewDOM.route(packageID: "com.ftester.e2e", hasWebViewNode: true,
                                               a11yLooksSufficient: false, browserDOMEnabled: false,
                                               appWebViewDOMEnabled: true),
                       .appWebView, "ブラウザ側のスイッチが自作アプリまで止めてはいけない")
        // FT_WEBVIEW_DOM=off は自作アプリだけを止める
        XCTAssertEqual(AndroidWebViewDOM.route(packageID: "com.ftester.e2e", hasWebViewNode: true,
                                               a11yLooksSufficient: false, browserDOMEnabled: true,
                                               appWebViewDOMEnabled: false),
                       .a11y)
        XCTAssertEqual(AndroidWebViewDOM.route(packageID: "com.android.chrome", hasWebViewNode: true,
                                               a11yLooksSufficient: false, browserDOMEnabled: true,
                                               appWebViewDOMEnabled: false),
                       .browser(socket: "chrome_devtools_remote"),
                       "自作アプリ側のスイッチがブラウザまで止めてはいけない")
    }

    // MARK: - pid → ソケットの解決(**推測で選ばない**。外すと別プロセスの DOM を木へ差し込む)

    /// `/proc/net/unix` の抜粋(実際の桁数・並びに合わせた形)
    private func procNetUnix(_ sockets: [String]) -> String {
        sockets.enumerated().map { index, name in
            "0000000000000000: 00000002 00000000 00010000 0001 01 4509\(index) @\(name)"
        }.joined(separator: "\n")
    }

    private func probe(pids: [Int], sockets: [String]) -> String {
        pids.map(String.init).joined(separator: " ") + "\n"
            + AndroidWebViewDOM.probeMarker + "\n" + procNetUnix(sockets)
    }

    /// **自分の pid と厳密一致する名前だけ**を採る(他アプリの WebView も Chrome も並んでいる)
    func testPicksOnlyTheSocketBelongingToTheApp() {
        let output = probe(pids: [5142], sockets: [
            "chrome_devtools_remote",
            "webview_devtools_remote_9001",
            "webview_devtools_remote_5142",
            "webview_devtools_remote_51420",
        ])
        XCTAssertEqual(AndroidWebViewDOM.resolveAppSocket(probeOutput: output),
                       .socket("webview_devtools_remote_5142"))
    }

    func testAppNotRunning() {
        XCTAssertEqual(AndroidWebViewDOM.resolveAppSocket(probeOutput: probe(pids: [], sockets: [
            "webview_devtools_remote_9001",
        ])), .appNotRunning)
    }

    /// WebView がまだ生成されていない(= ソケットが開いていない)。**黙って a11y へ落とす形**
    func testNoWebViewSocketYet() {
        XCTAssertEqual(AndroidWebViewDOM.resolveAppSocket(probeOutput: probe(pids: [5142], sockets: [
            "chrome_devtools_remote", "webview_devtools_remote_9001",
        ])), .noWebView)
        XCTAssertEqual(AndroidWebViewDOM.resolveAppSocket(probeOutput: probe(pids: [5142], sockets: [])),
                       .noWebView)
    }

    /// 同名プロセスが複数(マルチユーザ等)。**1つに決め打ちしない**
    func testAmbiguousWhenSeveralPidsHaveASocket() {
        let output = probe(pids: [5142, 6100], sockets: [
            "webview_devtools_remote_6100", "webview_devtools_remote_5142",
        ])
        XCTAssertEqual(AndroidWebViewDOM.resolveAppSocket(probeOutput: output),
                       .ambiguous(["webview_devtools_remote_5142", "webview_devtools_remote_6100"]))
    }

    /// 区切りが無い = 端末へ問い合わせられていない。**pid の切れ目が分からない出力を読まない**
    func testUnavailableWithoutTheMarker() {
        XCTAssertEqual(AndroidWebViewDOM.resolveAppSocket(probeOutput: "error: device offline"),
                       .unavailable)
    }

    /// `/proc/net/unix` 自体を読めない端末では pid の規則から名前を組み立て、実在の判定は
    /// 続く HTTP に任せる。**pid が複数なら組み立てない**(確かめられないまま別プロセスを覗かない)
    func testDerivesTheNameWhenTheListingCannotBeRead() {
        let denied = "5142\n" + AndroidWebViewDOM.probeMarker
            + "\ncat: /proc/net/unix: Permission denied"
        XCTAssertEqual(AndroidWebViewDOM.resolveAppSocket(probeOutput: denied),
                       .socket("webview_devtools_remote_5142"))
        let manyPids = "5142 6100\n" + AndroidWebViewDOM.probeMarker
            + "\ncat: /proc/net/unix: Permission denied"
        XCTAssertEqual(AndroidWebViewDOM.resolveAppSocket(probeOutput: manyPids),
                       .ambiguous(["webview_devtools_remote_5142", "webview_devtools_remote_6100"]))
    }

    func testParsesTheSocketListing() {
        let text = procNetUnix(["webview_devtools_remote_5142", "chrome_devtools_remote"])
            + "\n0000000000000000: 00000002 00000000 00010000 0001 01 45099 /dev/socket/logdw"
            + "\n0000000000000000: 00000002 00000000 00010000 0001 01 45100 @android:foo"
        XCTAssertEqual(AndroidWebViewDOM.devtoolsSockets(inProcNetUnix: text),
                       ["webview_devtools_remote_5142", "chrome_devtools_remote"],
                       "devtools 以外の口を候補にしない")
    }

    func testParsesPidofOutput() {
        XCTAssertEqual(AndroidWebViewDOM.pidList("5142 6100\n"), [5142, 6100])
        XCTAssertEqual(AndroidWebViewDOM.pidList("\n"), [])
        XCTAssertEqual(AndroidWebViewDOM.pidList("error: not found\n5142"), [5142],
                       "stderr の語を pid と読み違えない")
    }

    // MARK: - 端末への問い合わせ(素のシェル文字列に埋めるので綴りを検める)

    func testProbeAsksForBothThePidAndTheSockets() throws {
        let command = try XCTUnwrap(AndroidWebViewDOM.probeCommand(packageID: "com.ftester.e2e"))
        let script = command.joined(separator: " ")
        XCTAssertTrue(script.contains("pidof com.ftester.e2e"))
        XCTAssertTrue(script.contains(AndroidWebViewDOM.probeMarker), "pid とソケットの切れ目が無い")
        XCTAssertTrue(script.contains("/proc/net/unix"))
    }

    /// **端末上で別コマンドにならないこと**(パッケージ名は素で埋めている)
    func testProbeRefusesShellMetacharacters() {
        XCTAssertNil(AndroidWebViewDOM.probeCommand(packageID: "com.x; rm -rf /"))
        XCTAssertNil(AndroidWebViewDOM.probeCommand(packageID: "com.x`id`"))
        XCTAssertNil(AndroidWebViewDOM.probeCommand(packageID: "com.x $(id)"))
        XCTAssertNil(AndroidWebViewDOM.probeCommand(packageID: ""))
    }

    // MARK: - 能動タブの候補順(**1つに決め打ちしない**。応答で決めるのは read の責務)

    private func target(_ title: String, _ url: String, ws: String, type: String = "page") -> [String: Any] {
        ["type": type, "title": title, "url": url, "webSocketDebuggerUrl": ws]
    }

    /// **実測した罠そのもの**: 同じページを2タブ開くと題名が一致するので、題名だけでは
    /// 背面タブを掴む。アドレス欄と**正規化して一致**するほうを先に試す
    func testPrefersTheTabWhoseUrlMatchesTheAddressBarExactly() {
        let ranked = AndroidWebViewDOM.rankedTabs(
            webViewLabel: "気象庁 | 天気予報", urlBarValue: "jma.go.jp/bosai/forecast/",
            targets: [
                target("Example Domain", "https://example.com/", ws: "ws://ex"),
                target("気象庁 | 天気予報", "https://www.jma.go.jp/bosai/forecast/#area_type=x", ws: "ws://bg"),
                target("気象庁 | 天気予報", "https://www.jma.go.jp/bosai/forecast/", ws: "ws://fg"),
            ])
        XCTAssertEqual(ranked.first, "ws://fg", "フラグメント付きの背面タブを先に試してはいけない")
    }

    /// アドレス欄はスキームと `www.` を隠す(実測)
    func testNormalizesSchemeAndWww() {
        XCTAssertEqual(AndroidWebViewDOM.normalizedURL("https://www.jma.go.jp/a/"), "jma.go.jp/a/")
        XCTAssertEqual(AndroidWebViewDOM.normalizedURL("http://jma.go.jp/a/#b"), "jma.go.jp/a/#b",
                       "フラグメントは残す(2タブを分ける唯一の材料になる)")
    }

    /// アドレス欄が一致しなければ題名を使う(手掛かりは複数)
    func testFallsBackToTheTitle() {
        let ranked = AndroidWebViewDOM.rankedTabs(
            webViewLabel: "Example Domain", urlBarValue: nil,
            targets: [target("Other", "https://o.test/", ws: "ws://o"),
                      target("Example Domain", "https://example.com/", ws: "ws://e")])
        XCTAssertEqual(ranked.first, "ws://e")
    }

    /// **候補は捨てない**(全部返す)。1つ目が背面で応答しないとき次を試すのは read の役目
    func testKeepsEveryCandidateSoTheCallerCanRetry() {
        let ranked = AndroidWebViewDOM.rankedTabs(
            webViewLabel: nil, urlBarValue: "example.com",
            targets: [target("A", "https://a.test/", ws: "ws://a"),
                      target("E", "https://example.com/", ws: "ws://e")])
        XCTAssertEqual(ranked, ["ws://e", "ws://a"])
    }

    /// 手掛かりが無ければ元の並びのまま(順序に意味は無いが、決定的であること)
    func testWithoutHintsTheOriginalOrderIsKept() {
        // **候補を多く並べる**(2026-08-13 のレビュー指摘)。2件だと `sorted` から
        // index キーを外す変異でも順序が保たれて生き残る
        let targets = (0..<24).map { target("T\($0)", "https://t\($0).test/", ws: "ws://\($0)") }
        let ranked = AndroidWebViewDOM.rankedTabs(webViewLabel: nil, urlBarValue: nil, targets: targets)
        XCTAssertEqual(ranked, (0..<24).map { "ws://\($0)" }, "同順位は元の並びを保つこと")
    }

    func testAboutBlankIsAValidPage() {
        XCTAssertEqual(AndroidWebViewDOM.rankedTabs(webViewLabel: nil, urlBarValue: nil,
            targets: [target("blank", "about:blank", ws: "ws://x")]), ["ws://x"])
    }

    func testSkipsDevtoolsOwnPagesAndNonPageTargets() {
        XCTAssertTrue(AndroidWebViewDOM.rankedTabs(webViewLabel: nil, urlBarValue: nil, targets: [
            target("devtools", "devtools://devtools/x", ws: "ws://d"),
            ["type": "service_worker", "webSocketDebuggerUrl": "ws://sw"],
            target("no socket", "http://a", ws: ""),
        ]).isEmpty)
    }

    /// **試行回数に上限がある**(外した候補1つにつき締切ぶん待つ)
    func testTabAttemptsAreBounded() {
        XCTAssertLessThanOrEqual(AndroidWebViewDOM.maxTabAttempts, 4)
        XCTAssertGreaterThan(AndroidWebViewDOM.maxTabAttempts, 1, "1つだけだと外したとき諦めてしまう")
    }

    /// 締切が無いと背面タブで snapshot ごと固まる(実測 183 秒)
    func testEvaluateHasADeadline() {
        XCTAssertGreaterThan(AndroidWebViewDOM.evaluateTimeout, 0)
        XCTAssertLessThanOrEqual(AndroidWebViewDOM.evaluateTimeout, 5)
    }

    /// **生死の判定は評価よりずっと短いこと**。凍ったタブは待っても答えないので、
    /// ここを評価と同じ 3 秒にしていたとき snapshot の中央値が 9.5 秒になった(実測)
    func testLivenessProbeIsMuchCheaperThanTheEvaluation() {
        XCTAssertGreaterThan(AndroidWebViewDOM.livenessTimeout, 0)
        XCTAssertLessThan(AndroidWebViewDOM.livenessTimeout * 3, AndroidWebViewDOM.evaluateTimeout,
                          "候補を全部外しても評価1回ぶんに収まること")
    }

    /// **定数の値だけでは守れない**(2026-08-13 のレビュー指摘)。番犬ごと消す変異も
    /// `prefix` を外す変異も、値のテストは素通しする。使われていることをソースで見る
    /// (`SwipeForScrollForwardingTests` と同じ作法)
    func testTheDeadlineAndTheCapAreActuallyApplied() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/FTAndroid/AndroidWebViewDOM.swift"), encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // **`task.cancel` の有無では見分けられない**(`defer` 側にも在るため)。
        // 番犬そのもの = 締切ぶん眠ってから閉じる Task を名指しで見る
        XCTAssertTrue(code.contains("Task.sleep(nanoseconds: UInt64(timeout"),
                      "番犬が締切ぶん眠っていない = 受信が無期限になる")
        XCTAssertTrue(code.contains("prefix(maxTabAttempts)"), "試行回数の上限が掛かっていない")
        // **生死の判定を評価と同じ締切でやらない**(凍ったタブに 3 秒 × 候補数を払っていた)
        XCTAssertTrue(code.contains("timeout: livenessTimeout"),
                      "生死の判定に安い締切が使われていない")
        // **自作アプリのソケットは解決器を通すこと**。pid から名前を組み立てて直に forward すると、
        // 「一致するソケットが実在するか」「候補が複数でないか」の判定を丸ごと飛ばす
        XCTAssertTrue(code.contains("case .socket(let name) = resolveAppSocket(probeOutput:"),
                      "自作アプリのソケット解決が read から外れている")
    }

    // MARK: - 座標の写し・WebView 選択・差し込みは `FTCore.WebViewDOM` へ移設
    // (`Tests/FTCoreTests/WebViewDOMSnapshotTests.swift` に集約。ここは Android 固有の
    // density 倍・ソケット選択・url_bar 供給だけを守る)

    /// `#url_bar` の value を拾う(能動タブの手掛かり②の供給源)
    func testReadsTheUrlBarValue() {
        let bar = ElementInfo(ref: 1, type: "textField", identifier: "url_bar", label: nil,
                              value: "example.com", placeholder: nil, enabled: true,
                              frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        XCTAssertEqual(AndroidWebViewDOM.urlBarValue(in: [bar]), "example.com")
    }

    // MARK: - 注入用の ref 対応表(ブリッジは自分の ref しか受けない)

    private func element(_ ref: Int, _ type: String, x: Double, y: Double,
                         w: Double = 100, h: Double = 40) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
    }

    /// 対応表が無いと `type` / `clearInput` が 404 になる(タップは座標なので通る = 入力だけ落ちる)
    func testInputFieldsMapToTheA11yRef() {
        let dom = [element(90, "textField", x: 10, y: 100), element(91, "button", x: 10, y: 200)]
        let dropped = [element(7, "textField", x: 8, y: 98), element(8, "staticText", x: 8, y: 200)]
        XCTAssertEqual(AndroidWebViewDOM.bridgeRefMap(dom: dom, droppedA11y: dropped), [90: 7],
                       "入力欄だけ対応付ける(他は座標で操作する)")
    }

    /// **1つの a11y 欄を2つの DOM ノードで取り合わない**(同じ欄へ2回書き込む形になる)
    func testEachA11yFieldIsMappedOnlyOnce() {
        let dom = [element(90, "textField", x: 10, y: 100), element(91, "textField", x: 12, y: 102)]
        let dropped = [element(7, "textField", x: 8, y: 98)]
        XCTAssertEqual(AndroidWebViewDOM.bridgeRefMap(dom: dom, droppedA11y: dropped), [90: 7])
    }

    /// 決まらないときは対応付けない(**取り違えは沈黙する誤り**。404 のほうが気付ける)
    func testAmbiguousOverlapIsNotMapped() {
        let dom = [element(90, "textField", x: 10, y: 100)]
        let dropped = [element(7, "textField", x: 0, y: 90, w: 300, h: 60),
                       element(8, "textField", x: 5, y: 95, w: 300, h: 60)]
        XCTAssertEqual(AndroidWebViewDOM.bridgeRefMap(dom: dom, droppedA11y: dropped), [:],
                       "同じ大きさで重なる2つのどちらかを当てずっぽうで選ばない")
    }

    /// 入れ子(欄と、それを包む容器の両方が入力型)なら**内側**を採る
    func testPrefersTheSmallestCoveringField() {
        let dom = [element(90, "textField", x: 10, y: 100)]
        let dropped = [element(7, "textField", x: 0, y: 0, w: 400, h: 400),
                       element(8, "textField", x: 5, y: 95, w: 120, h: 50)]
        XCTAssertEqual(AndroidWebViewDOM.bridgeRefMap(dom: dom, droppedA11y: dropped), [90: 8])
    }

    /// a11y 側に入力欄が無い(版によっては出ない)なら空 = 呼び出し側は今までどおり素の ref を送る
    func testWithoutAnA11yFieldNothingIsMapped() {
        let dom = [element(90, "textField", x: 10, y: 100)]
        XCTAssertEqual(AndroidWebViewDOM.bridgeRefMap(dom: dom, droppedA11y: [
            element(7, "staticText", x: 8, y: 98),
        ]), [:])
    }

    /// 離れた欄には引っ掛からない(中心点が中に入ることが条件)
    func testAFieldElsewhereOnTheScreenIsNotMapped() {
        let dom = [element(90, "textField", x: 10, y: 100)]
        let dropped = [element(7, "textField", x: 10, y: 600)]
        XCTAssertEqual(AndroidWebViewDOM.bridgeRefMap(dom: dom, droppedA11y: dropped), [:])
    }

    // MARK: - forward port(pid が無いブラウザ経路の代替。並列 run での host port 衝突回避)

    func testStablePortIsDeterministicForTheSameSeed() {
        XCTAssertEqual(AndroidWebViewDOM.stablePort(seed: "emulator-5554"),
                       AndroidWebViewDOM.stablePort(seed: "emulator-5554"))
    }

    func testStablePortStaysWithinTheReservedRange() {
        let port = AndroidWebViewDOM.stablePort(seed: "192.168.1.23:5555")
        XCTAssertGreaterThanOrEqual(port, 10000)
        XCTAssertLessThan(port, 30000)
    }

    /// **ブラウザの port は従来のまま**(種は serial だけ)。自作アプリを足したついでに
    /// 動かすと、稼働中の forward と食い違って切り分けが難しくなる
    func testBrowserPortSeedIsStillJustTheSerial() {
        XCTAssertEqual(AndroidWebViewDOM.portSeed(serial: "emulator-5554", appSocket: nil),
                       "emulator-5554")
    }

    /// 同じ端末でブラウザ経路と自作アプリ経路が別プロセスから同時に forward されうる
    func testAppPortDiffersFromTheBrowserPortOnTheSameDevice() {
        let browser = AndroidWebViewDOM.stablePort(
            seed: AndroidWebViewDOM.portSeed(serial: "emulator-5554", appSocket: nil))
        let app = AndroidWebViewDOM.stablePort(
            seed: AndroidWebViewDOM.portSeed(serial: "emulator-5554",
                                             appSocket: "webview_devtools_remote_5142"))
        XCTAssertNotEqual(browser, app)
    }

    func testStablePortDiffersAcrossSerials() {
        // 決定論の要件を破らない範囲での実用上の確認(衝突しても機能は壊れないが、
        // 分散していないと並列 run での forward 競合が増える)
        XCTAssertNotEqual(AndroidWebViewDOM.stablePort(seed: "emulator-5554"),
                          AndroidWebViewDOM.stablePort(seed: "emulator-5556"))
    }
}
