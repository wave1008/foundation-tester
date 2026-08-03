import XCTest
@testable import FTDSL
import FTCore

/// **コンパイルも実行も通るのに何も検証していない/別のことをしている**シナリオを拾うガード。
/// 生成されたシナリオで頻出する誤りで、どれも放置すると緑のまま腐る。
final class AuthoringGuardTests: XCTestCase {

    /// 常に 1 要素(#field)を返し、type を記録するだけのドライバ
    private final class StubDriver: AppDriver {
        private(set) var typed: [String] = []
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func clearAppData(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(
                sessionBundleID: nil,
                screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                elements: [ElementInfo(ref: 1, type: "textField", identifier: "field", label: "ラベル",
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)],
                truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws { typed.append(text) }
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(driver: AppDriver = StubDriver(), dryRun: Bool = true,
                          platform: String = "ios",
                          inventoryURL: URL? = nil) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: platform, app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: dryRun,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-authoring-guard-test.json"),
                    selectorInventoryURL: inventoryURL,
                    emit: { _ in })
    }

    /// 使い捨ての台帳を作って URL を返す
    private func makeInventory(ids: [String], platform: String = "ios") -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-inv-\(UUID().uuidString)/inv.json")
        SelectorInventory.record(ids: ids, platform: platform, at: url)
        return url
    }

    private func suggestions(_ core: FTDriveCore) -> [String] {
        core.finalRecord.fixSuggestions.map(\.message)
    }

    private func isFailed(_ status: StepResult.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    // MARK: - expectation にアサーションが無い

    func testExpectationWithoutAssertionsIsReported() {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "何も検証していない") {
                action { tap("#field") }
                    .expectation { select("#field") }   // select は検証ではない
            }
        }
        XCTAssertTrue(suggestions(core).contains { $0.contains("contains no assertions") },
                      "アサーション0の expectation が素通りした")
    }

    func testExpectationWithAssertionIsNotReported() {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "検証している") {
                action { tap("#field") }
                    .expectation { exist("#field") }
            }
        }
        XCTAssertFalse(suggestions(core).contains { $0.contains("contains no assertions") },
                       "検証しているのに警告した")
    }

    /// thisIs 系(perform を通らない経路)も同じ計数に合流していること
    func testValueAssertionCountsAsAnAssertion() {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "計算結果だけ検証する") {
                action { tap("#field") }
                    .expectation { (10 * 3).thisIs(30) }
            }
        }
        XCTAssertFalse(suggestions(core).contains { $0.contains("contains no assertions") },
                       "thisIs がアサーションとして数えられていない")
    }

    /// 実行されなかった条件ブロックがあれば黙る(中に何が書いてあるか分からないため)。
    /// **これが無いと `expectation { android { notExist(…) } }` を iOS で回すたびに誤警告する**
    /// (E2E に実在する形。ifElse 側も対称に扱う)
    func testUnexecutedConditionalBlockSuppressesTheWarning() {
        for label in ["platform", "ifElse"] {
            let core = makeCore()   // platform: "ios"
            FTRuntime.bootstrap(core: core, dslThread: Thread.current)
            scenario {
                scene(1, label) {
                    action { tap("#field") }
                        .expectation {
                            if label == "platform" {
                                android { exist("#field") }         // iOS では実行されない
                            } else {
                                ifCanSelect("#field") { tap("#field") }
                                    .ifElse { exist("#field") }     // 成立側が走るので未実行
                            }
                        }
                }
            }
            FTRuntime.tearDown()
            core.warnAboutMissingAssertions()
            XCTAssertFalse(suggestions(core).contains { $0.contains("no assertions") },
                           "\(label): 実行されなかったブロックを根拠に誤警告した")
        }
    }

    // MARK: - シナリオ全体でアサーションが無い

    func testScenarioWithoutAnyAssertionIsReported() {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        scenario {
            scene(1, "操作しかしない") {
                action { tap("#field") }
            }
        }
        FTRuntime.tearDown()
        core.warnAboutMissingAssertions()
        XCTAssertTrue(suggestions(core).contains { $0.contains("no assertions at all") },
                      "検証が1本も無いシナリオが素通りした")
    }

    func testScenarioWithAnAssertionIsNotReported() {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        scenario {
            scene(1, "検証する") {
                action { tap("#field") }
                    .expectation { exist("#field") }
            }
        }
        FTRuntime.tearDown()
        core.warnAboutMissingAssertions()
        XCTAssertFalse(suggestions(core).contains { $0.contains("no assertions at all") },
                       "検証しているのに警告した")
    }

    /// **検証カテゴリのコマンドは1つ残らず noteAssertion に合流する**。
    /// `appIs` は FlowStep を持たない実装だったため数えられておらず、`verify` も expectation も
    /// 「検証0本」と誤判定していた(2026-08-03 に発見)。同じ型の再発をここで落とす。
    /// 期待値は索引から採るので、**検証コマンドを足すと索引 → このテストの順で追随が強制される**
    func testEveryAssertionCommandIsCounted() {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "全検証コマンドを1回ずつ") {
                FTDSL.expectation {
                    exist("#field")
                    waitForDisplay("#field")
                    waitForClose("#field")
                    notExist("#field")
                    countIs("#field", 1)
                    enabledIsTrue("#field")
                    enabledIsFalse("#field")
                    checkIsON("#field")
                    checkIsOFF("#field")
                    keyboardIsShown()
                    keyboardIsNotShown()
                    screenIs("何かの画面")
                    appIs("com.example.app")

                    textIs("#field", "x")
                    textIsNot("#field", "x")
                    textContains("#field", "x")
                    textContainsNot("#field", "x")
                    textStartsWith("#field", "x")
                    textStartsWithNot("#field", "x")
                    textEndsWith("#field", "x")
                    textEndsWithNot("#field", "x")
                    textMatches("#field", "x")
                    textMatchesNot("#field", "x")
                    textMatchesDateFormat("#field", "yyyy/MM/dd")
                    textIsEmpty("#field")
                    textIsNotEmpty("#field")

                    valueIs("#field", "x")
                    valueIsNot("#field", "x")
                    valueContains("#field", "x")
                    valueContainsNot("#field", "x")
                    valueStartsWith("#field", "x")
                    valueStartsWithNot("#field", "x")
                    valueEndsWith("#field", "x")
                    valueEndsWithNot("#field", "x")
                    valueMatches("#field", "x")
                    valueMatchesNot("#field", "x")
                    valueMatchesDateFormat("#field", "yyyy/MM/dd")
                    valueIsEmpty("#field")
                    valueIsNotEmpty("#field")
                }
            }
        }

        let assertionCategories: Set<String> = ["existence", "text", "value"]
        let expected = DSLCommandIndex.all.filter { assertionCategories.contains($0.category) }.count
        XCTAssertEqual(core.scenarioAssertionCount, expected,
                       "検証コマンドの一部が noteAssertion に合流していない"
                       + "(または上の呼び出し列が索引に追随していない)")
    }

    // MARK: - 台帳に無い #id(綴り誤り・でっち上げ)

    private func runWithInventory(_ url: URL?, platform: String = "ios",
                                  dryRun: Bool = true,
                                  _ body: @escaping () -> Void) -> [String] {
        let core = makeCore(dryRun: dryRun, platform: platform, inventoryURL: url)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        scenario { scene(1, "s") { action(body) } }
        FTRuntime.tearDown()
        core.warnAboutUnknownIDs()
        return suggestions(core)
    }

    func testUnknownIDIsReportedInDryRun() {
        let inventory = makeInventory(ids: ["field", "submit"])
        // 綴り誤りは「多数の正しい id に少数の誤り」という形で出る
        let messages = runWithInventory(inventory) { tap("#field"); tap("#submit"); tap("#feild") }
        XCTAssertTrue(messages.contains { $0.contains("`#feild`") },
                      "台帳に無い id が素通りした")
    }

    /// **薄い台帳では黙る**。1画面しか撮っていない状態で既存シナリオを回すと、
    /// 他画面の id が全部「綴り誤り」に見える(実測 44/47 シナリオが誤警告した)。
    /// そのシナリオが触る id の 2/3 以上が台帳に在るときだけ警告する
    func testThinInventoryStaysSilent() {
        let inventory = makeInventory(ids: ["nav_input"])   // 1画面ぶんだけ撮った状態
        let messages = runWithInventory(inventory) {
            tap("#nav_input")                                // 台帳に在る
            tap("#field_single"); tap("#btn_clear")          // まだ撮っていない画面の実在 id
            exist("#txt_echo")
        }
        XCTAssertTrue(messages.isEmpty, "薄い台帳を根拠に誤警告した: \(messages)")
    }

    func testKnownIDIsNotReported() {
        let inventory = makeInventory(ids: ["field", "submit"])
        let messages = runWithInventory(inventory) { tap("#field"); exist("#submit") }
        XCTAssertTrue(messages.isEmpty, "実在する id を警告した: \(messages)")
    }

    /// **台帳が無い/そのプラットフォームの記録が無いなら黙る**。
    /// 「知らない」を「間違い」と言うと、導入直後の全シナリオが警告まみれになって機能ごと無視される
    func testSilentWithoutInventory() {
        XCTAssertTrue(runWithInventory(nil) { tap("#anything") }.isEmpty,
                      "台帳が無いのに警告した")
        let iosOnly = makeInventory(ids: ["field"], platform: "ios")
        XCTAssertTrue(runWithInventory(iosOnly, platform: "android") { tap("#anything") }.isEmpty,
                      "別プラットフォームの記録を根拠に警告した")
    }

    /// 照合は dry-run 専用(実行では解決の成否そのものが答えを出すので二重に言わない)。
    /// **台帳に無い id で試す** —— 実在する id で試すと、照合が走っていても警告が出ず素通りする
    func testNotReportedInRealRun() {
        let inventory = makeInventory(ids: ["field"])
        let messages = runWithInventory(inventory, dryRun: false) { tap("#nope") }
        XCTAssertFalse(messages.contains { $0.contains("`#nope`") },
                       "実行時に台帳の照合が走っている(解決の失敗と二重に言うことになる)")
    }

    /// ワイルドカードは台帳に無くて当然なので照合しない
    func testWildcardIDIsNotReported() {
        let inventory = makeInventory(ids: ["row_01", "row_02"])
        XCTAssertTrue(runWithInventory(inventory) { tap("#row_*") }.isEmpty,
                      "ワイルドカードを完全一致で照合した")
    }

    // MARK: - type の引数落とし

    func testTypeWithSelectorLikeTextFails() {
        let driver = StubDriver()
        let core = makeCore(driver: driver, dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") { action { type("#field") } }
        }
        let recorded = core.finalRecord.scenes.flatMap(\.steps)
        XCTAssertTrue(isFailed(recorded[0].status), "セレクタを入力文字列として打ち込んだ")
        XCTAssertTrue(driver.typed.isEmpty, "落とすと言いながらデバイスへ送っている")
    }

    /// 誤検知しないこと(`#` で始まっても人が入力しうる文字列は通す)
    func testTypeWithOrdinaryTextPasses() {
        let core = makeCore(driver: StubDriver(), dryRun: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    type("a@b.c")
                    type("#1 は特価です")     // 空白を含む = セレクタではない
                    type("3.14")
                }
            }
        }
        let recorded = core.finalRecord.scenes.flatMap(\.steps)
        XCTAssertFalse(recorded.contains { isFailed($0.status) }, "通常の入力文字列を誤って落とした")
    }

    func testSelectorLikeInputDetection() {
        XCTAssertNotNil(FTSelector.selectorLikeInputError("#login_btn"))
        XCTAssertNotNil(FTSelector.selectorLikeInputError("#btn||ログイン"))
        XCTAssertNotNil(FTSelector.selectorLikeInputError("#list >> .cell"))
        XCTAssertNil(FTSelector.selectorLikeInputError("ログイン"))
        XCTAssertNil(FTSelector.selectorLikeInputError("#"))
        XCTAssertNil(FTSelector.selectorLikeInputError("#ハッシュタグ"))
        XCTAssertNil(FTSelector.selectorLikeInputError(""))
    }
}
