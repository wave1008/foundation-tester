import XCTest
@testable import FTDSL
import FTCore

/// 型付きセレクタ(Sel)。**文字列版と同じ FlowLocator に畳まれること**が唯一の合格条件で、
/// ここが崩れると型付き経路だけ解決規則が違うという最悪の分岐になる(記法の意味は
/// FTSelectorTests が持ち、この場では「一致」だけを見る)。
final class SelTests: XCTestCase {

    /// 型付き版と文字列版が同じ主ロケータ・同じフォールバック連鎖になること
    private func assertSame(_ sel: Sel, _ expression: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let typed = sel.ftSelector
        let parsed = FTSelector.parse(expression)
        XCTAssertEqual(typed.primary, parsed.primary, expression, file: file, line: line)
        XCTAssertEqual(typed.fallbacks, parsed.fallbacks, expression, file: file, line: line)
    }

    func testFilters() {
        assertSame(.id("login_btn"), "#login_btn")
        assertSame(.id("login", .startsWith), "#login*")
        assertSame(.id("login", .contains), "#*login*")
        assertSame(.id("login", .endsWith), "#*login")
        assertSame(.id("^p_\\d+$", .matches), "idMatches=^p_\\d+$")
        assertSame(.text("ログイン"), "ログイン")
        assertSame(.text("ログイン", .contains), "*ログイン*")
        assertSame(.text("ログイン", .startsWith), "ログイン*")
        assertSame(.text("ログイン", .endsWith), "*ログイン")
        assertSame(.text("^ログイン.*$", .matches), "textMatches=^ログイン.*$")
        assertSame(.type(.button), ".button")
        assertSame(.type(.button).nth(2), ".button[2]")
        assertSame(.type(.switch).id("PHOTOS_UPLOAD"), ".switch#PHOTOS_UPLOAD")
        assertSame(.type(.switch).id("PHOTOS", .startsWith), ".switch&&#PHOTOS*")
        assertSame(.type(.switch).text("Resource Upload"), ".switch&&Resource Upload")
        assertSame(.type(.button).value("太郎").enabled(true), ".button&&value=太郎&&enabled=true")
        assertSame(.placeholder("メールアドレス"), "placeholder=メールアドレス")
        assertSame(.checked(), "checked=true")
        assertSame(.type(.input).checked(false), ".input&&checked=false")
    }

    /// nth は 1 オリジン(内部 index は 0 オリジン)。1 番目は「指定なし」と同じ形に畳む
    func testNthIsOneOrigin() {
        XCTAssertEqual(Sel.type(.button).nth(1).ftSelector.primary, FlowLocator(type: "button"))
        XCTAssertEqual(Sel.type(.button).nth(3).ftSelector.primary,
                       FlowLocator(type: "button", index: 2))
    }

    func testFallbackChain() {
        assertSame(.id("login_btn").or(.text("ログイン")), "#login_btn||ログイン")
        assertSame(.id("a").or(.id("b")).or(.text("c")), "#a||#b||c")
    }

    func testScope() {
        assertSame(.id("list").find(.type(.clickable).nth(2)), "#list >> .clickable[2]")
        assertSame(.id("outer").find(.id("inner")).find(.type(.button)),
                   "#outer >> #inner >> .button")
        // スコープは相対セレクタの基準・対象の双方に効く(文字列版と同じ構造になること)
        assertSame(.id("row").find(.text("数量").right(.button)), "#row >> <数量>:rightButton")
    }

    func testRelative() {
        assertSame(.text("通知").right(.switch), "通知:rightSwitch")
        assertSame(.text("通知").right(), "通知:right")
        assertSame(.text("通知").right(nth: 2), "通知:right(2)")
        assertSame(.text("通知").right(.button, nth: 2), "通知:rightButton(2)")
        assertSame(.text("通知").right().below(.button), "通知:right:belowButton")
        assertSame(.text("見出し").below(matching: .id("list").find(.type(.button))),
                   "見出し:below(#list >> .button)")
        assertSame(.text("変更").type(.button).right(matching: .text("数量")),
                   "<変更&&.button>:right(数量)")
    }

    /// フィルタ系メソッドは相対ステップの**後**なら対象(=ステップの filter)に効く
    func testFilterAfterRelativeAppliesToTarget() {
        assertSame(.text("通知").right().type(.switch), "通知:rightSwitch")
        assertSame(.text("通知").right().nth(2), "通知:right(2)")
        assertSame(.text("通知").right(.button).nth(2), "通知:rightButton(2)")
    }

    /// 表示テキストは再パース可能な正規形(レポート表示とヒールキャッシュのキーになる)
    func testTextIsReparseableCanonicalForm() {
        let cases: [Sel] = [
            .id("login_btn"),
            .id("login", .startsWith),
            .type(.button).nth(2),
            .id("list").find(.type(.clickable).nth(2)),
            .text("通知").right(.switch),
            .id("a").or(.text("b")),
        ]
        for sel in cases {
            let text = sel.ftSelector.text
            XCTAssertNil(FTSelector.validationError(text), text)
            XCTAssertEqual(FTSelector.parse(text).primary, sel.ftSelector.primary, text)
            XCTAssertEqual(FTSelector.parse(text).fallbacks, sel.ftSelector.fallbacks, text)
        }
    }

    /// 型付き経路は構文検証を通さない印が立つ。記法の予約文字を含むラベルでも
    /// 「再パースしたら別物」にならないための逃げ道(FTRuntime.perform の validateSelector)
    func testStructuredSkipsValidation() {
        let sel = Sel.text("A >> B").ftSelector
        XCTAssertTrue(sel.structured)
        XCTAssertEqual(sel.primary, FlowLocator(label: "A >> B"))
        XCTAssertFalse(FTSelector.parse("A >> B").structured)
    }

    func testCustomTypeIsNormalized() {
        XCTAssertEqual(SelType.custom("Cell").name, "cell")
        XCTAssertEqual(SelType.custom("cell").name, "cell")
    }

    /// 否定は記法(`text!=`)と同じ構造を作り、往復もする
    func testNotBuildsSameLocatorAsNotation() {
        let sel = Sel.type(.button).not(.text("キャンセル"))
        XCTAssertEqual(sel.ftSelector.primary,
                       FTSelector.parse(".button&&text!=キャンセル").primary)
        XCTAssertEqual(sel.ftSelector.text, ".button&&text!=キャンセル")
    }

    /// id の否定も同じ構造(idContains!=)になる
    func testNotBuildsSameLocatorAsNotationForId() {
        let sel = Sel.type(.button).not(.id("save", .contains))
        XCTAssertEqual(sel.ftSelector.primary,
                       FTSelector.parse(".button&&idContains!=save").primary)
        XCTAssertEqual(sel.ftSelector.text, ".button&&idContains!=save")
    }

    /// 相対ステップの後に書いた否定は**対象**に効く(他のフィルタ系メソッドと同じ規律)
    func testNotAppliesToRelativeTarget() {
        let sel = Sel.text("通知").right(.button).not(.text("編集"))
        let step = sel.ftSelector.primary.relative?.first
        XCTAssertEqual(step?.filter?.first?.not, [FlowLocator(label: "編集")])
        XCTAssertNil(sel.ftSelector.primary.not)
    }

    // MARK: - or の後の合成は全節へ配る(2026-08-02。以前は primary だけに掛かって黙って条件が消えていた)

    /// **`or` は文字列版の `(a|b)` グループと同じ**: 後から足したフィルタは全節に掛かる。
    /// primary だけに掛けると第2節が無条件で残り、書いた `.button` が黙って効かない
    func testFilterAfterOrAppliesToEveryClause() {
        XCTAssertEqual(Sel.text("a").or(.text("b")).type(.button).ftSelector.text,
                       ".button&&a||.button&&b")
    }

    /// 序数も同じ。文字列版の `(a|b)&&[2]` = 「各節の2番目」に揃える(design.md の既知の非対応と同義)
    func testOrdinalAfterOrAppliesToEveryClause() {
        XCTAssertEqual(Sel.text("a").or(.text("b")).nth(2).ftSelector.text, "a&&[2]||b&&[2]")
    }

    /// 相対ステップも全節へ。primary だけに足すと第2節が「基準そのもの」のまま別要素を掴む
    func testRelativeStepAfterOrAppliesToEveryClause() {
        XCTAssertEqual(Sel.text("a").or(.text("b")).right(.switch).ftSelector.text,
                       "a:rightSwitch||b:rightSwitch")
    }

    /// **`find` はどちらの側の `or` も落とさない**(祖先 × 子孫の全組み合わせ)。
    /// 以前はレシーバの fallbacks が丸ごと消え、書いたヒール連鎖が片方だけになっていた
    func testFindKeepsAlternativeAncestors() {
        XCTAssertEqual(Sel.id("a").or(.id("b")).find(.text("x")).ftSelector.text,
                       "#a >> x||#b >> x")
    }

    /// 祖先が先(ヒール連鎖の優先順位)・子孫が後。両側に or があるときの順序を固定する
    func testFindOrdersAncestorMajor() {
        XCTAssertEqual(Sel.id("a").or(.id("b")).find(Sel.text("x").or(.text("y"))).ftSelector.text,
                       "#a >> x||#a >> y||#b >> x||#b >> y")
    }

    /// **`not` は引数側の全節を除外する**(`not` の各要素は「どれかに当たれば除く」)。
    /// 以前は other.fallbacks が捨てられ、除外したいものの半分だけが効いていた
    func testNotExcludesEveryClauseOfTheArgument() {
        XCTAssertEqual(Sel.type(.button).not(Sel.text("c").or(.text("d"))).ftSelector.text,
                       ".button&&text!=c&&text!=d")
    }

    // MARK: - 1オリジンでない序数はプロセスを落とさず失敗ステップにする

    /// `Sel.nth(0)` は**crash させない**(1プロセス=1シナリオなので落とすとレポートごと消える)。
    /// 文字列版の `"[0]"` が validationError で失敗ステップになるのと同じ扱いに揃える
    func testNonPositiveOrdinalIsReportedInsteadOfCrashing() {
        XCTAssertNotNil(Sel.text("a").nth(0).ftSelector.preflightError)
        XCTAssertNotNil(Sel.text("a").right(.button, nth: 0).ftSelector.preflightError)
        XCTAssertNil(Sel.text("a").nth(1).ftSelector.preflightError, "正当な序数は素通りすること")
    }

    /// 誤りは合成をまたいで運ばれる(途中で握り潰すと実行前に落とせない)
    func testInvalidOrdinalSurvivesComposition() {
        XCTAssertNotNil(Sel.id("list").find(Sel.text("a").nth(0)).ftSelector.preflightError)
        XCTAssertNotNil(Sel.text("a").nth(0).or(.text("b")).ftSelector.preflightError)
    }
}

/// tapWithScrollDown/Up/Right/Left・tapWithoutScroll・existWithScrollDown/Up・existWithoutScroll の
/// Sel オーバーロード。実装は String 版と同じ経路(tap(_:Sel,scroll:)/exist(_:Sel,scroll:))へ
/// 委譲するだけなので、ここでは「委譲そのものが正しいか」(スクロール方向の転記ミス等)を、
/// 実際にドライバまで実行して確認する(SelTests 本体は FlowLocator 比較だけで済むが、
/// これらはコマンド分岐そのものが検証対象なので CommandDispatchTests と同じ実行スタイルを取る)。
final class SelScrollVariantDispatchTests: XCTestCase {

    /// 初期スナップショットには対象が無く、`revealDirection` と同じ向きにスワイプされて初めて現れる。
    /// 違う方向にスワイプされ続けても maxSwipes まで現れないので、方向の転記ミスは即座に見つかる
    /// (対象が見つからずタイムアウト/未タップのまま終わる)
    private final class ScrollRevealDriver: AppDriver {
        private(set) var tapped: [Int] = []
        private(set) var swipes: [FTSwipeDirection] = []
        private var revealed = false
        private let revealDirection: FTSwipeDirection

        init(revealDirection: FTSwipeDirection) { self.revealDirection = revealDirection }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            let elements = revealed
                ? [ElementInfo(ref: 1, type: "button", identifier: "target", label: "対象",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)]
                : []
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws { tapped.append(ref) }
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {
            swipes.append(direction)
            if direction == revealDirection { revealed = true }
        }
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(driver: AppDriver) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0030", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-sel-scroll-test.json"),
                    emit: { _ in })
    }

    private func run(driver: AppDriver, _ body: () -> Void) {
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
    }

    /// tapWithScrollDown はコンテンツ `.down` = 指を上へ動かす(FTScrollDirection.swipe 参照)
    func testTapWithScrollDownSelUsesSameDirectionAsStringVersion() {
        let byString = ScrollRevealDriver(revealDirection: .up)
        run(driver: byString) { tapWithScrollDown("#target") }
        XCTAssertEqual(byString.tapped, [1], "String 版が正しい方向で見つけられていない")

        let bySel = ScrollRevealDriver(revealDirection: .up)
        run(driver: bySel) { tapWithScrollDown(.id("target")) }
        XCTAssertEqual(bySel.tapped, [1], "Sel 版がString版と異なる方向でスクロールしている")
    }

    func testTapWithScrollUpSelUsesSameDirectionAsStringVersion() {
        let byString = ScrollRevealDriver(revealDirection: .down)
        run(driver: byString) { tapWithScrollUp("#target") }
        XCTAssertEqual(byString.tapped, [1])

        let bySel = ScrollRevealDriver(revealDirection: .down)
        run(driver: bySel) { tapWithScrollUp(.id("target")) }
        XCTAssertEqual(bySel.tapped, [1], "Sel 版がString版と異なる方向でスクロールしている")
    }

    func testTapWithScrollRightSelUsesSameDirectionAsStringVersion() {
        let byString = ScrollRevealDriver(revealDirection: .left)
        run(driver: byString) { tapWithScrollRight("#target") }
        XCTAssertEqual(byString.tapped, [1])

        let bySel = ScrollRevealDriver(revealDirection: .left)
        run(driver: bySel) { tapWithScrollRight(.id("target")) }
        XCTAssertEqual(bySel.tapped, [1], "Sel 版がString版と異なる方向でスクロールしている")
    }

    func testTapWithScrollLeftSelUsesSameDirectionAsStringVersion() {
        let byString = ScrollRevealDriver(revealDirection: .right)
        run(driver: byString) { tapWithScrollLeft("#target") }
        XCTAssertEqual(byString.tapped, [1])

        let bySel = ScrollRevealDriver(revealDirection: .right)
        run(driver: bySel) { tapWithScrollLeft(.id("target")) }
        XCTAssertEqual(bySel.tapped, [1], "Sel 版がString版と異なる方向でスクロールしている")
    }

    /// withScroll* の外側文脈があっても tapWithoutScroll は一切スワイプしない
    /// (String 版・Sel 版とも、対象が現在画面に無ければタップされないまま終わる)
    func testTapWithoutScrollSelDoesNotScrollEvenInsideOuterScrollContext() {
        let stringDriver = ScrollRevealDriver(revealDirection: .up)
        run(driver: stringDriver) {
            withScrollDown { tapWithoutScroll("#target", timeout: 0) }
        }
        XCTAssertTrue(stringDriver.swipes.isEmpty, "String 版がスクロールしてしまった")
        XCTAssertTrue(stringDriver.tapped.isEmpty)

        let selDriver = ScrollRevealDriver(revealDirection: .up)
        run(driver: selDriver) {
            withScrollDown { tapWithoutScroll(.id("target"), timeout: 0) }
        }
        XCTAssertTrue(selDriver.swipes.isEmpty, "Sel 版がスクロールしてしまった")
        XCTAssertTrue(selDriver.tapped.isEmpty)
    }

    func testExistWithScrollDownSelUsesSameDirectionAsStringVersion() {
        let byString = ScrollRevealDriver(revealDirection: .up)
        var stringElement: FTElement!
        run(driver: byString) { stringElement = existWithScrollDown("#target") }
        XCTAssertEqual(stringElement.id, "target")

        let bySel = ScrollRevealDriver(revealDirection: .up)
        var selElement: FTElement!
        run(driver: bySel) { selElement = existWithScrollDown(.id("target")) }
        XCTAssertEqual(selElement.id, "target", "Sel 版がString版と異なる方向でスクロールしている")
    }

    func testExistWithScrollUpSelUsesSameDirectionAsStringVersion() {
        let byString = ScrollRevealDriver(revealDirection: .down)
        var stringElement: FTElement!
        run(driver: byString) { stringElement = existWithScrollUp("#target") }
        XCTAssertEqual(stringElement.id, "target")

        let bySel = ScrollRevealDriver(revealDirection: .down)
        var selElement: FTElement!
        run(driver: bySel) { selElement = existWithScrollUp(.id("target")) }
        XCTAssertEqual(selElement.id, "target", "Sel 版がString版と異なる方向でスクロールしている")
    }

    /// withScroll* の外側文脈があっても existWithoutScroll は一切スワイプせず、
    /// 現在画面に無ければ「空の FTElement」(id も nil)を返す
    func testExistWithoutScrollSelDoesNotScrollEvenInsideOuterScrollContext() {
        let stringDriver = ScrollRevealDriver(revealDirection: .up)
        var stringElement: FTElement!
        run(driver: stringDriver) {
            withScrollDown { stringElement = existWithoutScroll("#target", timeout: 0) }
        }
        XCTAssertTrue(stringDriver.swipes.isEmpty, "String 版がスクロールしてしまった")
        XCTAssertNil(stringElement.id)

        let selDriver = ScrollRevealDriver(revealDirection: .up)
        var selElement: FTElement!
        run(driver: selDriver) {
            withScrollDown { selElement = existWithoutScroll(.id("target"), timeout: 0) }
        }
        XCTAssertTrue(selDriver.swipes.isEmpty, "Sel 版がスクロールしてしまった")
        XCTAssertNil(selElement.id, "Sel 版のフォールバック FTElement が空でない")
    }

    /// 実行時: 失敗ステップとして記録され、シナリオが中断すること(crash しない)。
    /// **失敗理由まで見る** — 「要素が見つからない」でも passed==false になるので、
    /// 理由を見ないと序数の防波堤が外れても緑のままで気付けない(2026-08-02 に実際に無力だった)
    func testInvalidOrdinalFailsTheStepWithTheOrdinalReason() {
        let driver = ScrollRevealDriver(revealDirection: .up)
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { scene(1, "s") { action { tap(Sel.text("a").nth(0)) } } }

        XCTAssertFalse(core.finalRecord.passed, "不正な序数は失敗として記録すること")
        let reasons = core.finalRecord.scenes.flatMap(\.steps).compactMap { step -> String? in
            if case .failed(let reason) = step.status { return reason }
            return nil
        }
        XCTAssertEqual(reasons.count, 1, "1ステップだけが失敗するはず: \(reasons)")
        XCTAssertTrue(reasons[0].contains("1-origin"),
                      "序数の誤りとして落とすこと(要素未検出に化けていない): \(reasons[0])")
        XCTAssertTrue(driver.tapped.isEmpty, "デバイスに触る前に落とすこと")
    }
}
