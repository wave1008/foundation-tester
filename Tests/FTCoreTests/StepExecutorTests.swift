import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FTCore

final class StepExecutorTests: XCTestCase {
    /// 白ベタ = BlankFrameDetector が凍結と判定する画像
    static let blankPNG: Data = makePNG { context in
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    /// 市松模様 = サンプル点が割れるので凍結と判定されない画像
    static let nonBlankPNG: Data = makePNG { context in
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for row in 0..<8 where row.isMultiple(of: 2) {
            for col in 0..<8 where col.isMultiple(of: 2) {
                context.fill(CGRect(x: col * 8, y: row * 8, width: 8, height: 8))
            }
        }
    }

    private static func makePNG(_ draw: (CGContext) -> Void) -> Data {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("テスト用 CGContext 生成に失敗")
        }
        draw(context)
        guard let image = context.makeImage() else { fatalError("テスト用 CGImage 生成に失敗") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("テスト用 PNG destination 生成に失敗")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("テスト用 PNG 書き出しに失敗") }
        return output as Data
    }

    /// occlusion-guard 対象になり得るテキスト要素(StaticText + 文字を含む label)
    func textElement(id: String, label: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
    }

    // MARK: - 見切れ判定(スクロール探索が「見えた瞬間」で止まらないための条件)

    /// 縁で見切れた要素は frame がクランプされてタップが外れる(Compose iOS の上流制約)。
    /// **見つけた = 十分ではない**ことをここで固定する
    func testClippedByViewportDetectsEachEdge() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        func at(_ x: Double, _ y: Double, _ w: Double = 370, _ h: Double = 56) -> ElementInfo {
            ElementInfo(ref: 1, type: "clickable", identifier: "row", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
        }
        XCTAssertFalse(StepExecutor.isClippedByViewport(at(16, 400), screen: screen))
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(16, 829), screen: screen), "下端で見切れ")
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(16, -1), screen: screen), "上端で見切れ")
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(-1, 400), screen: screen), "左で見切れ")
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(40, 400, 370), screen: screen), "右で見切れ")
        // ちょうど収まっているものは見切れではない(境界)
        XCTAssertFalse(StepExecutor.isClippedByViewport(at(16, 818), screen: screen))
        // **幅がビューポートと同じ要素も判定対象**(リストの行は容器と同じ幅を持つ)
        XCTAssertTrue(StepExecutor.isClippedByViewport(at(0, 829, 402), screen: screen),
                      "幅一致の行が漏れるとタップが容器の外へ落ちる")
    }

    /// ビューポートより大きい要素はどう送っても収まらない。true にすると maxSwipes を
    /// 使い切って「見つけたのに失敗」になる
    func testElementLargerThanViewportIsNotTreatedAsClipped() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let tall = ElementInfo(ref: 1, type: "other", identifier: "long", label: nil, value: nil,
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: -100, width: 402, height: 1200), depth: 1)
        XCTAssertFalse(StepExecutor.isClippedByViewport(tall, screen: screen))
    }

    func element(ref: Int, id: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    /// SpringBoard の木に載るアラート本体(題名を持つ)
    private func alertTitled(_ title: String) -> ElementInfo {
        ElementInfo(ref: 100, type: "alert", identifier: nil, label: title, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 300, height: 200), depth: 0)
    }

    func labeled(ref: Int, label: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: nil, label: label, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    /// clearInput の事後検証テスト用の入力欄。value/placeholder/focused を個別に指定できる
    func inputField(ref: Int, id: String? = nil, value: String? = nil,
                            placeholder: String? = nil, focused: Bool? = nil,
                            frame: FTRect = FTRect(x: 0, y: 0, width: 100, height: 20)) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: id, label: nil, value: value,
                   placeholder: placeholder, enabled: true, frame: frame, depth: 0,
                   focused: focused)
    }

    /// occlusionGuard 付き exists(exist の既定): delegate が「隠れ」を返すと偽陽性として失敗へ反転する
    func testOcclusionGuardFlipsWhenOccluded() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("occlusion 反転で失敗を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "失敗理由に occlusion を含むこと: \(msg)")
        // poll-until-visible: 覆われ続ける間は timeout まで繰り返し照合する(1回とは限らない)
        XCTAssertGreaterThanOrEqual(delegate.visibleCalls, 1)
    }

    /// occlusionGuard 付き exists: delegate が「見える」を返せば通常どおり pass
    func testOcclusionGuardPassesWhenVisible() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: true), isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("可視判定で pass を期待"); return
        }
    }

    /// スクショ再利用: 操作を挟まない連続ガードでは 1 回のスクショを使い回す
    func testGuardReusesScreenshotAcrossConsecutiveAsserts() async throws {
        let log = CallLog()
        let el = textElement(id: "msg", label: "こんにちは")
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el]])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: true), isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        _ = await executor.execute(step)
        _ = await executor.execute(step)

        XCTAssertEqual(primary.screenshotCallCount, 1, "連続ガードはスクショ1回に集約されるはず")
    }

    /// スクショ再利用: 間に操作(tap)が入るとキャッシュを捨てて取り直す
    func testGuardScreenshotInvalidatedByAction() async throws {
        let log = CallLog()
        let el = textElement(id: "msg", label: "こんにちは")
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el]])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: true), isAndroid: false)
        let assertStep = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                  timeout: 1, occlusionGuard: true)

        _ = await executor.execute(assertStep)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "msg")))
        _ = await executor.execute(assertStep)

        XCTAssertEqual(primary.screenshotCallCount, 2, "操作を挟んだら取り直すはず")
    }

    /// [StaleFrameDetector] 新規撮影のスクショが「木は変わったのに画像はバイト同一」を示したら
    /// 1回だけ撮り直す。撮り直しで画像が変われば(=もう凍結していない)通常どおり判定を続ける
    func testStaleScreenshotRetriesOnceThenProceedsWithFreshCapture() async throws {
        let log = CallLog()
        let stuckPNG = Data([0x01])
        let freshPNG = Data([0x02])
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "A")],
                                                       [textElement(id: "msg", label: "B")]],
                                    screenshots: [stuckPNG, stuckPNG, freshPNG])
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        _ = await executor.execute(step)   // baseline: 木 "A"・画像 stuckPNG
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "msg")))
        let outcome = await executor.execute(step)   // 木 "B"(変化)・初回捕捉は stuckPNG のまま → stale → 撮り直し → freshPNG

        guard case .passed = outcome.status else {
            XCTFail("撮り直しで凍結が解消されたので通常どおり pass するはず: \(outcome.status)"); return
        }
        XCTAssertEqual(primary.screenshotCallCount, 3, "2回目の assert は初回捕捉+撮り直しの2回スクショを払うはず")
        // baseline(1回目の assert)自体も stale ではないので通常どおり FM を呼ぶ+今回の撮り直し後
        // の1回 = 計2回
        XCTAssertEqual(delegate.visibleCalls, 2, "baseline 1回+撮り直した新しい画像で1回、計2回 FM 照合するはず")
        XCTAssertFalse(outcome.notes.contains(.staleScreenshot), "凍結は解消されたので stale 注記は付かないはず")
    }

    /// 撮り直してもなお画像がバイト同一(=木は変わったのに絵が固まったまま)なら、
    /// 古い絵を根拠に偽陽性反転を宣言せず flip しない。FM も呼ばない。
    /// **delegate は visible:true**(false にすると baseline 自体が本物の occlusion で
    /// timeout まで poll してしまい、その間の追加 snapshot/screenshot 呼び出しが
    /// スクリプトした木/画像の対応関係を狂わせる —— stale 判定だけを切り分けるため)
    func testStaleScreenshotSkipsFlipWhenRetakeStillStale() async throws {
        let log = CallLog()
        let stuckPNG = Data([0x01])
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "A")],
                                                       [textElement(id: "msg", label: "B")]],
                                    screenshots: [stuckPNG])
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        _ = await executor.execute(step)   // baseline: not stale → 通常どおり FM を1回呼んで pass
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "msg")))
        let callsBeforeStep2 = delegate.visibleCalls
        let outcome = await executor.execute(step)   // 木は変わったが、画像は撮り直しても不変のまま

        guard case .passed = outcome.status else {
            XCTFail("flip しないのでツリー一致のまま pass するはず: \(outcome.status)"); return
        }
        XCTAssertEqual(delegate.visibleCalls, callsBeforeStep2, "stale が解消しないうちは FM を呼ばないはず")
        XCTAssertTrue(outcome.notes.contains(.staleScreenshot), "stale-screenshot 注記が付くはず: \(outcome.notes)")
    }

    /// #2 修正: textEquals の期待値(ユーザーリテラル)は結合 `, ` 規則を外す(句読点入りテキストを守る)
    func testEligibilityAllowsCommaInUserText() {
        // 実 label(exist)では `, ` を結合セマンティクスとして除外
        XCTAssertFalse(OcclusionEligibility.eligible(type: "staticText", label: "A, B",
                                                      value: nil, placeholder: nil, web: nil).ok)
        // ユーザー期待値(textEquals)では除外しない
        XCTAssertTrue(OcclusionEligibility.eligible(type: "staticText", label: "Hello, World",
                                                    isUserText: true, value: nil, placeholder: nil,
                                                    web: nil).ok)
        // 型・絵文字の規則は isUserText でも維持
        XCTAssertFalse(OcclusionEligibility.eligible(type: "button", label: "x", isUserText: true,
                                                      value: nil, placeholder: nil, web: nil).ok)
        XCTAssertFalse(OcclusionEligibility.eligible(type: "staticText", label: "📱",
                                                     isUserText: true, value: nil, placeholder: nil,
                                                     web: nil).ok)
    }

    /// placeholder が値で置き換わって隠れている(=画面に描画されていない)ときは対象外(ガード素通り)。
    /// 2026-09-02 の ios-fm 実行での偽陽性実例: WebView 入力欄の placeholder="WebView 入力" に
    /// "hello123" を type した直後の exist("placeholder=WebView 入力") が誤って覆い扱いされ反転した。
    /// (a11y 経路: label がそのまま placeholder になる形。web ではない = web: nil)
    func testEligibilityExcludesPlaceholderHiddenByEnteredValue() {
        XCTAssertFalse(OcclusionEligibility.eligible(type: "textField", label: "WebView 入力",
                                                      value: "hello123", placeholder: "WebView 入力",
                                                      web: nil).ok)
    }

    /// 値が空の入力欄では placeholder が現に描画されているので、ガードは効き続ける(ok=true)。
    /// ここが抜けると「入力型は常に素通り」に退化した実装がテストを通ってしまう。
    func testEligibilityKeepsEmptyPlaceholderEligible() {
        XCTAssertTrue(OcclusionEligibility.eligible(type: "textField", label: "WebView 入力",
                                                     value: "", placeholder: "WebView 入力", web: nil).ok)
        XCTAssertTrue(OcclusionEligibility.eligible(type: "textField", label: "WebView 入力",
                                                     value: nil, placeholder: "WebView 入力", web: nil).ok)
    }

    /// Web(DOM)経路の入力欄は label が常に aria-label(WebViewDOMSnapshot.swift の
    /// `role === "textField"/"secureTextField"/"textView"` 分岐)で、aria-label は
    /// 値の有無に関わらず画面に一切描画されない。placeholder と aria-label が別文字列でも
    /// (= 上の placeholder 規則が発火しない、ごく普通のフォームでも)対象外にする。
    /// 2026-09-02 コーディネータ指摘: aria-label と placeholder が偶然同一だった SUT でだけ
    /// 直った状態で残っていた同型の穴。
    func testEligibilityExcludesWebInputAriaLabelWithValue() {
        XCTAssertFalse(OcclusionEligibility.eligible(type: "textField", label: "検索",
                                                      value: "hello123", placeholder: "キーワードを入力",
                                                      web: true).ok)
    }

    /// 同じ Web 入力欄で値が空でも、aria-label は値の有無に関わらず描画されないので ok=false のまま。
    /// **ここを true にする実装は穴が残る**(placeholder 規則の「値が空なら素通り」を
    /// この型にまで広げてしまう誤り)。
    func testEligibilityExcludesWebInputAriaLabelEvenWhenEmpty() {
        XCTAssertFalse(OcclusionEligibility.eligible(type: "textField", label: "検索",
                                                      value: nil, placeholder: "キーワードを入力",
                                                      web: true).ok)
        XCTAssertFalse(OcclusionEligibility.eligible(type: "textField", label: "検索",
                                                      value: "", placeholder: nil, web: true).ok)
    }

    /// Web だからといって一律に素通しする退化を落とす最重要の陰性テスト:
    /// Web の staticText は labelOf() の textContent フォールバックで実際に描画された本文なので、
    /// 型で絞らず web フラグだけで足切りすると壊れる
    func testEligibilityKeepsWebStaticTextEligible() {
        XCTAssertTrue(OcclusionEligibility.eligible(type: "staticText", label: "こんにちは",
                                                     value: nil, placeholder: nil, web: true).ok)
    }

    /// 2026-09-02 コーディネータ指摘: aria-label の無条件除外は広すぎた。valueIs/valueContains 経路
    /// (StepExecutor+Assert.swift ~566行目)は element.value 由来の期待文字列を渡してくるので、
    /// 期待文字列がその value そのものなら aria-label ではなく**現に描画されている値**を見ている。
    /// この砦(「入力した値が実際に見えているか」)まで潰すと検証が黙って無効化される。
    func testEligibilityKeepsWebInputEligibleWhenExpectedEqualsValue() {
        XCTAssertTrue(OcclusionEligibility.eligible(type: "textField", label: "hello123",
                                                     value: "hello123", placeholder: "キーワードを入力",
                                                     web: true).ok)
    }

    /// valueContains は部分一致で期待文字列を渡すので、等号ではなく包含で判定する必要がある
    func testEligibilityKeepsWebInputEligibleWhenExpectedIsSubstringOfValue() {
        XCTAssertTrue(OcclusionEligibility.eligible(type: "textField", label: "hello",
                                                     value: "hello123", placeholder: "キーワードを入力",
                                                     web: true).ok)
    }

    /// 期待文字列が value に含まれない(= aria-label のケース。上の
    /// testEligibilityExcludesWebInputAriaLabelWithValue と同条件だが、value に部分一致すらしない
    /// ことを明示的に固定する)ときは従来どおり対象外
    func testEligibilityExcludesWebInputWhenExpectedNotInValue() {
        XCTAssertFalse(OcclusionEligibility.eligible(type: "textField", label: "検索",
                                                      value: "hello123", placeholder: "キーワードを入力",
                                                      web: true).ok)
    }

    /// #1 修正: フォールバックドライバ(システムUI)由来の textEquals 一致は座標系が食い違うためガードしない
    func testTextEqualsSkipsGuardForFallbackDriverMatch() async throws {
        let log = CallLog()
        let match = ElementInfo(ref: 1, type: "staticText", identifier: "msg", label: "OK",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])   // 常に空
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[match]])
        let delegate = SequenceVisibilityDelegate([false])   // ガードが走れば覆いで失敗させる
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "OK", timeout: 2, occlusionGuard: true)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("fsnap 一致はガード無しで pass のはず"); return
        }
        XCTAssertEqual(delegate.calls, 0, "フォールバックドライバ一致では FM を呼ばない")
    }

    /// #5 修正: 覆い観測後にテキストが不一致へ変わったら、stale な occlusion でなく不一致失敗を返す
    func testTextEqualsClearsStaleOcclusionOnMismatch() async throws {
        let log = CallLog()
        func el(_ label: String) -> ElementInfo {
            ElementInfo(ref: 1, type: "staticText", identifier: "msg", label: label, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
        }
        // 1周目: 一致(覆い)→ 2周目以降: 不一致
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[el("OK")], [el("NG")]])
        let executor = StepExecutor(driver: primary, delegate: SequenceVisibilityDelegate([false]), isAndroid: false)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "OK", timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("timeout で失敗するはず"); return
        }
        XCTAssertTrue(msg.contains("does not equal"), "テキスト不一致を返すこと: \(msg)")
        XCTAssertFalse(msg.contains("occlusion"), "stale な occlusion を返さないこと: \(msg)")
    }

    /// #4 修正: label セレクタの exist("Hello, World")はユーザー期待値。結合 `, ` 規則でガードを
    /// スキップせず、覆われていれば occlusion 失敗へ反転する(修正前は素通り pass していた)。
    func testExistsWithCommaLabelStillGuards() async throws {
        let log = CallLog()
        let el = ElementInfo(ref: 1, type: "staticText", identifier: nil, label: "Hello, World",
                             value: nil, placeholder: nil, enabled: true,
                             frame: FTRect(x: 0, y: 0, width: 100, height: 20), depth: 0)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(label: "Hello, World"),
                            timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("ユーザーラベルの句読点でガードがスキップされ pass してしまった"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "occlusion 失敗を返すこと: \(msg)")
        XCTAssertGreaterThanOrEqual(delegate.visibleCalls, 1, "ガードが実行されること")
    }

    /// #5 修正: exist で覆い観測後に要素が消失したら、stale な occlusion でなく未発見を返す。
    func testExistsClearsStaleOcclusionOnDisappearance() async throws {
        let log = CallLog()
        let el = textElement(id: "msg", label: "こんにちは")
        // 1周目: 覆われて存在 → 2周目以降: 消失(空)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el], []])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: false), isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("timeout で失敗するはず"); return
        }
        XCTAssertTrue(msg.contains("not found"), "未発見を返すこと: \(msg)")
        XCTAssertFalse(msg.contains("occlusion"), "stale な occlusion を返さないこと: \(msg)")
    }

    /// timeout==0 の exist は「初回照会のみ・リトライなし」。0回照会で必ず失敗する回帰を防ぐ
    /// (存在する要素は 1 回の照会で pass する)。
    func testExistsTimeoutZeroChecksOnce() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"), timeout: 0)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("timeout==0 でも初回照会で存在すれば pass のはず(0回照会の回帰)"); return
        }
        XCTAssertEqual(primary.snapshotCallCount, 1, "初回照会は1回だけ")
    }

    /// scrollTo に負の maxSwipes が来ても 0...(-1) で trap せず、初回照会で存在すれば pass する。
    func testScrollToNegativeMaxSwipesDoesNotTrap() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "msg"), maxSwipes: -1)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("負の maxSwipes でも trap せず初回発見で pass のはず"); return
        }
    }

    /// textIs(occlusionGuard 既定)も同じガードを通る: 一致しても覆われていれば失敗へ反転
    func testOcclusionGuardOnTextEquals() async throws {
        let log = CallLog()
        let el = textElement(id: "msg", label: "合致")
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[el]])
        let executor = StepExecutor(driver: primary, delegate: SequenceVisibilityDelegate([false]), isAndroid: false)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "合致", timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("一致かつ覆われ=occlusion 失敗のはず"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "occlusion 失敗を返すこと: \(msg)")
    }

    /// occlusionGuardEnabled=false(実行プロファイルの falsePositiveCheck:false)は per-step の
    /// occlusionGuard:true より優先して occlusion-guard 自体を止める(FM を呼ばず pass)
    func testOcclusionGuardMasterSwitchOffSkipsGuard() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionGuardEnabled: false, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("マスタースイッチ OFF ならツリー一致だけで pass のはず"); return
        }
        XCTAssertEqual(delegate.visibleCalls, 0, "マスタースイッチ OFF で FM を呼んではいけない")
    }

    // MARK: - 可視性照合の幾何 Tier-0 と、FM が答えないときの注記

    /// 幾何 Tier-0 の witness: 中心が画面(400x800)の外にある要素。横軸は収まる(幅234)
    /// ので、その軸で中心 x=518 が画面外 = 「木に居るが見えていない」形(iOS の木は画面外の
    /// 要素も frame ごと残す)
    private func offscreenTextElement() -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: "msg", label: "こんにちは", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 401, y: 300, width: 234, height: 20), depth: 0)
    }

    /// **FM に訊いたのに答えが無かった**ステップは、素通り(pass)のまま機械可読な注記を残す。
    /// シナリオ側からは「判定能力が欠けている」ことを観測できないので、知っているツールが言う
    func testVisibilityGuardNotesWhenTheFMGivesNoVerdict() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = NoVerdictVisibilityDelegate()
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("FM が答えないときは従来どおり素通りのはず: \(outcome.status)"); return
        }
        XCTAssertGreaterThanOrEqual(delegate.visibleCalls, 1, "FM まで到達していない(注記の前提が崩れる)")
        XCTAssertTrue(outcome.notes.contains(.visibilityGuardSkipped),
                      "FM が答えなかったのに注記が無い: \(outcome.notes)")
    }

    /// **答えが返った回には立てない**(毎回出る注記にしない)
    func testVisibilityGuardDoesNotNoteWhenTheFMAnswers() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        let outcome = await executor.execute(step)

        XCTAssertGreaterThanOrEqual(delegate.visibleCalls, 1)
        XCTAssertFalse(outcome.notes.contains(.visibilityGuardSkipped),
                       "FM が答えたのに skip の注記が立っている: \(outcome.notes)")
    }

    /// **中心が画面外の一致は、FM が「見える」と言う前に幾何で不可視にする**。FM は crop が
    /// 画像の外に落ちると nil(素通り)なので、この形は FM では塞がらない —— 幾何が先に答え、
    /// FM にもスクショにも触らない
    func testVisibilityGuardFailsAnOffscreenMatchBeforeAskingTheFM() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[offscreenTextElement()]])
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("中心が画面外の一致を可視と呼んでいる: \(outcome.status)"); return
        }
        XCTAssertTrue(msg.contains("offscreen"), "失敗理由に offscreen を含むこと: \(msg)")
        XCTAssertEqual(delegate.visibleCalls, 0, "幾何で決まる形で FM を呼んではいけない")
        XCTAssertEqual(primary.screenshotCallCount, 0, "幾何で決まる形でスクショを撮ってはいけない")
    }

    /// 幾何 Tier-0 は **FM が無くても効く**(delegate nil = FM 未配線/死亡と同じ入口)。
    /// これが無いと、FM の無いホストでは requireVisible が何も保証しない
    func testVisibilityGuardGeometryWorksWithoutAnFMDelegate() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[offscreenTextElement()]])
        let executor = StepExecutor(driver: primary, delegate: nil, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("delegate 無しでは幾何も効いていない"); return
        }
        XCTAssertTrue(msg.contains("offscreen"), "失敗理由に offscreen を含むこと: \(msg)")
    }

    /// 幾何 Tier-0 も `requireVisible` の一部なので、**マスタースイッチ OFF と per-step の
    /// requireVisible:false では素通り**(ツリー存在だけを見る従来の契約を変えない)
    func testOffscreenMatchPassesWhenTheVisibilityGuardIsOff() async throws {
        for (master, perStep) in [(false, true), (true, false)] {
            let log = CallLog()
            let primary = FakeAppDriver(name: "primary", log: log,
                                        snapshotElements: [[offscreenTextElement()]])
            let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: true),
                                        occlusionGuardEnabled: master, isAndroid: false)
            let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                timeout: 1, occlusionGuard: perStep)

            guard case .passed = await executor.execute(step).status else {
                XCTFail("ガード無効(master=\(master) perStep=\(perStep))で画面外を失敗にしている"); return
            }
        }
    }

    /// `select` は exist と同じ規律で見えていない要素を**空要素**として返す(失敗にしない)
    func testSelectReturnsAnEmptyElementForAnOffscreenMatch() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[offscreenTextElement()]])
        let executor = StepExecutor(driver: primary, delegate: nil, isAndroid: false)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("select は掴めなくても失敗にしない契約: \(outcome.status)"); return
        }
        XCTAssertNil(outcome.resolvedElement, "見えていない要素を掴んだことにしている")
        XCTAssertTrue(outcome.driverFallback?.contains("not visible") == true,
                      "空要素を返した理由が注記に無い: \(outcome.driverFallback ?? "nil")")
    }

    // MARK: - システム UI の覆い(SystemUIGate)

    /// **覆われている間は撃たない**。要素は木に居て解決できてしまうが、人手では触れないので
    /// 操作させてはいけない(受け手報告 2026-08-20 の症状そのもの)
    func testActionIsRefusedWhileSystemUICoversTheApp() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限",
                                                               buttons: ["許可"])]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "許可"))
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("覆われている間のタップは失敗にすること: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .systemUICovered, msg)
        XCTAssertTrue(msg.contains("権限"), "覆っているものを名指しすること: \(msg)")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.tap") },
                       "1回も撃ってはいけない: \(log.entries)")
    }

    // MARK: - 登録の無いシステムアラート(注記と題名。止めない)

    /// **登録が無くても黙らない**: launch 直後の最初の触る操作で1回だけ SpringBoard に聞き、
    /// 前面にあれば注記 system-alert-present と題名・ボタンを残す。操作自体は止めない
    /// (閉じるのはシナリオの責務。受け手報告 2026-08-22: 通知 → ATT の登録漏れで背面操作が緑)
    func testUnregisteredSystemAlertIsNotedOnTheFirstTouchAfterLaunch() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(
            present: true, title: "“App”は通知を送信します。よろしいですか？", buttons: ["許可しない", "許可"])]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.noteAppLaunched()
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        let first = await executor.execute(step)
        let second = await executor.execute(step)

        guard case .passed = first.status else {
            return XCTFail("登録が無いときは止めない(注記だけ): \(first.status)")
        }
        XCTAssertTrue(first.notes.contains(.systemAlertPresent), "\(first.notes)")
        XCTAssertTrue(first.driverFallback?.contains("通知を送信します") == true, first.driverFallback ?? "nil")
        XCTAssertTrue(first.driverFallback?.contains("許可しない") == true, first.driverFallback ?? "nil")
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.tap") }, "撃ってはいる: \(log.entries)")
        // 契機は launch 直後の1回だけ(常時監視にしない)
        XCTAssertEqual(fallback.systemAlertCallCount, 1, "2回目の操作で再び聞いている")
        XCTAssertFalse(second.notes.contains(.systemAlertPresent))
    }

    /// **失敗の原因がアラートなら題名を添える**: 時間切れ(not found)のとき、登録が無くても
    /// 1回だけ聞いて、失敗文言に題名とボタンを出す(仕分けが速くなる)
    func testTimeoutFailureNamesTheUnregisteredSystemAlert() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(
            present: true, title: "トラッキング", buttons: ["Appにトラッキングしないように要求", "許可"])]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "home"), timeout: 0)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(msg.contains("element not found"), msg)
        XCTAssertTrue(msg.contains("トラッキング"), "題名が無い: \(msg)")
        XCTAssertTrue(msg.contains("iosAlertHandler"), "次の一手(登録)を示していない: \(msg)")
        XCTAssertTrue(outcome.notes.contains(.systemAlertPresent), "\(outcome.notes)")
        XCTAssertEqual(outcome.failureKind, .notFound, "素性は最初の理由のまま(推測で上書きしない)")
    }

    /// 前面に何も無ければ文言も注記も変わらない(失敗時の1往復だけで、誤検知の余地を作らない)
    func testFailureIsUnchangedWhenNoSystemAlertIsPresent() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "home"), timeout: 0)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(msg.contains("iosAlertHandler"), msg)
        XCTAssertFalse(outcome.notes.contains(.systemAlertPresent))
    }

    /// 登録がある間は既存のゲート(SystemUIGate)が担う = 二重に聞かない・注記も system-alert-present
    /// ではなく waited-for-system-ui / system-ui-covered の側に出る
    func testRegisteredWatchlistKeepsTheExistingGateAndDoesNotDoubleProbe() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限",
                                                               buttons: ["許可"])]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "一致しない"))
        executor.noteAppLaunched()
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.failureKind, .systemUICovered)
        XCTAssertFalse(outcome.notes.contains(.systemAlertPresent), "登録がある間は既存ゲートの注記だけ")
    }

    /// 覆いが**消えれば普通に撃つ**(即失敗にしない = 過渡的なアラートで赤くしない)。
    /// 待ったことは注記に残す
    func testActionProceedsOnceTheSystemUIGoesAway() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "一致しないラベル"))
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("覆いが消えたら撃つこと: \(outcome.status)"); return
        }
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("primary.tap") }, "\(log.entries)")
        XCTAssertTrue(outcome.notes.contains(.waitedForSystemUI),
                      "待ったことを黙ってはいけない: \(outcome.notes)")
    }

    /// **登録が無い実行では1往復も払わない**。アラートが出る操作は書き手が知っているので
    /// 直前に登録でき、登録しない実行に毎ステップ約 73ms を負わせない
    func testNoProbeWithoutRegisteredHandlers() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限")]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)   // 登録なし
        let tap = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)
        let exists = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        guard case .passed = await executor.execute(tap).status,
              case .passed = await executor.execute(exists).status else {
            XCTFail("登録が無い実行は従来どおり通すこと"); return
        }
        XCTAssertFalse(log.entries.contains { $0.hasSuffix(".systemAlert") },
                       "登録が無いのに聞いてはいけない: \(log.entries)")
    }

    /// **ランナーが居ない構成でも1往復も払わない**。ここが止まると engine=inapp 固定と
    /// Android が全滅する
    func testActionCostsNothingWithoutAFallbackBridge() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let executor = StepExecutor(driver: primary, isAndroid: false)   // fallback 無し
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "許可"))
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("fallback が無いなら従来どおり撃つこと"); return
        }
        XCTAssertFalse(log.entries.contains { $0.hasSuffix(".systemAlert") },
                       "fallback が無いのに聞いてはいけない: \(log.entries)")
    }

    /// **シナリオ自身がアラートを操作しているときは奪わない**: 対象が fallback(SpringBoard)の
    /// 木で解決できるなら、覆われていても止めない
    func testActionOnTheAlertItselfIsNotBlocked() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "一致しないラベル"))
        let step = FlowStep(action: "tap", locator: FlowLocator(label: "許可"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("アラート自身への操作は止めてはいけない: \(outcome.status)"); return
        }
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("fallback.tap") }, "\(log.entries)")
    }

    /// **覆われている間の緑は取り消す**。木には居るが人手には見えていないので、
    /// 「見えた」と言うのは別ウィンドウのモーダルと同じ形の偽陽性になる
    func testPassingAssertIsRevokedWhileSystemUICoversTheApp() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限")]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "一致しないラベル"))
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("覆われている間に exist を通してはいけない: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .systemUICovered)
    }

    /// **ロケータを取らないアクション(swipe 等)も覆いの間は撃たない**(2026-08-22 レビュー指摘)。
    /// これらは executeAction の早期 return を通るので、門を先頭に置かないと素通りしていた
    func testLocatorlessActionIsAlsoRefusedWhileCovered() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限")]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*一致しない*", button: "許可"))
        // locator を一切取らない swipe。覆われている間は失敗すること
        let step = FlowStep(action: "swipe", direction: "up", timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("覆われている間の swipe は失敗にすること: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .systemUICovered)
        XCTAssertFalse(log.entries.contains { $0.contains("swipe") },
                       "1回もスワイプしてはいけない: \(log.entries)")
    }

    /// **値検証が覆いの下で赤になったら、閉じて判定し直す**(2026-08-22 レビュー指摘)。
    /// `tap(#request) → textIs(結果)` の自然な並びは、アラートを答えるまで値が更新されない ——
    /// 成功時の偽陽性取り消しだけでなく、この「誤った不一致」も門が拾う
    func testFailingValueAssertDismissesAndRejudges() async throws {
        let log = CallLog()
        // primary は**押されるまで none のまま**(覆いの下でいくら読んでも denied にならない)。
        // fallback の press で初めて denied へ切り替わる = アラートを答えた因果
        let primary = FakeAppDriver(name: "primary", log: log,
            snapshotElements: [[textElement(id: "result", label: "photos=none")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[alertTitled("写真ライブラリ"),
                                                         labeled(ref: 9, label: "許可しない")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "写真ライブラリ"),
                                      SystemAlertProbeResponse(present: false)]
        fallback.afterTap = { [weak primary] in
            primary?.snapshotElements = [[ElementInfo(
                ref: 1, type: "staticText", identifier: "result", label: "photos=denied",
                value: nil, placeholder: nil, enabled: true,
                frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)]]
        }
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*写真ライブラリ*", button: "許可しない"))
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "result"),
                            expected: "photos=denied", timeout: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("閉じて読み直したら通ること"); return
        }
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("fallback.tap") },
                      "アラートを閉じること: \(log.entries)")
    }

    /// **アラート自身の検証は取り消さない**(`exist("許可しない")` が書けなくなる)
    func testAssertOnTheAlertItselfStaysGreen() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[labeled(ref: 9, label: "許可しない")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "一致しないラベル"))
        let step = FlowStep(assert: "exists", locator: FlowLocator(label: "許可しない"), timeout: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("アラート自身の検証は通すこと"); return
        }
    }

    /// **覆われていない普通の失敗はそのまま失敗**。門は「覆いのせいで赤くなったのか」を
    /// 1往復で確かめるが、覆われていなければ元の失敗を返す(誤って緑にしない)。
    /// 登録が無ければその1往復も払わない(testNoProbeWithoutRegisteredHandlers)
    func testAGenuineUncoveredFailureStaysFailed() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        // 覆われていない(presentを返さない)
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "許可"))
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "missing"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("覆われていない要素なしは失敗のままにすること: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .notFound,
                       "覆いのせいにせず、本来の not-found を返すこと")
    }

    /// `許可` のような汎用ラベルを複数のアラートが使う場合は**枚数ぶん登録する**
    /// (位置情報 → ATT がどちらも「許可」の形)。登録が枚数ぶんあるので取り合いは起きない
    func testTheSameLabelRegisteredTwiceServesTwoDifferentAlerts() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        // 1枚目(位置情報)と2枚目(ATT)は別のアラートだが、押すラベルはどちらも「許可」
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[alertTitled("位置情報"),
                                                         labeled(ref: 9, label: "許可")],
                                                        [alertTitled("トラッキング"),
                                                         labeled(ref: 8, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "位置情報"),
                                      SystemAlertProbeResponse(present: true, title: "トラッキング"),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*位置情報*", button: "許可"))
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*トラッキング*", button: "許可"))
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("2枚とも閉じて進むこと"); return
        }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("fallback.tap") },
                       ["fallback.tap(ref:9)", "fallback.tap(ref:8)"],
                       "2枚目のアラートにも(2つ目の登録で)同じラベルを使えること: \(log.entries)")
    }

    /// **発火した登録は外れ、台帳が空になったら監視を止める**。以後は1往復も払わない
    func testMonitoringStopsOnceTheRegistrationHasFired() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[alertTitled("位置情報"),
                                                         labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "位置情報"),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*位置情報*", button: "許可"))
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("閉じたら進むこと"); return
        }
        let afterFirst = fallback.systemAlertCallCount
        XCTAssertGreaterThan(afterFirst, 0, "1ステップ目は見張ること")
        guard case .passed = await executor.execute(step).status else {
            XCTFail("2ステップ目も通ること"); return
        }
        XCTAssertEqual(fallback.systemAlertCallCount, afterFirst,
                       "発火して台帳が空になったら1往復も払わないこと")
    }

    /// **閉じても消えない画面でも予算内で終わる**。②(閉じる)が成功し続ける限りループが
    /// 回るので、予算の確認をループ先頭に置かないと**無限に回る**(変異テストで実際に
    /// ハングして見つけた defect の回帰)
    func testItGivesUpWithinTheBudgetEvenIfDismissingNeverClearsTheAlert() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        // 押せるボタンは常にあり、アラートも消えない(閉じたつもりで消えない画面)
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[alertTitled("消えない"),
                                                         labeled(ref: 9, label: "許可"),
                                                         labeled(ref: 8, label: "OK")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "消えない")]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*消えない*", button: "許可"))
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*消えない*", button: "OK"))
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        // **時間で縛る**: 予算の確認を外すとここは失敗ではなく**ハング**する。ハングは
        // 変異テストのハーネスからは「生き残り」と区別できず、SwiftPM のロックを掴んだまま
        // 後続の worktree まで止める(2026-08-21 に実際に踏んだ)ので、落ちる形にしておく。
        // 打ち切りは待機の `Task.sleep` が投げて伝わる
        let started = Date()
        let running = Task { await executor.execute(step) }
        let watchdog = Task { try? await Task.sleep(for: .seconds(15)); running.cancel() }
        let outcome = await running.value
        watchdog.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(started), 15,
                          "予算(1s)を大きく超えた = ループが予算を見ていない")

        guard case .failed = outcome.status else {
            XCTFail("消えないなら予算切れで落ちること: \(outcome.status)"); return
        }
        XCTAssertEqual(outcome.failureKind, .systemUICovered)
    }

    /// **名指し宣言(`.alert`)は処理したら消費され、全部処理し終えたら監視を解除する**
    /// (ユーザー決定の「宣言したアラートを処理したら監視を解除」は、待っている
    /// アラートの集合を言える名指し形でだけ成立する)。解除後は1往復も払わない
    func testNamedDeclarationsReleaseTheWatchOnceAllAreHandled() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[alertTitled("トラッキングの許可"),
                                                         labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "トラッキングの許可"),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*トラッキング*", button: "許可"))
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("名指しが当たったら閉じて進むこと"); return
        }
        XCTAssertTrue(log.entries.contains { $0.hasPrefix("fallback.tap") }, "\(log.entries)")
        let afterFirst = fallback.systemAlertCallCount
        XCTAssertGreaterThan(afterFirst, 0)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("2ステップ目も通ること"); return
        }
        XCTAssertEqual(fallback.systemAlertCallCount, afterFirst,
                       "名指しを全部処理したら監視を解除する(1往復も払わない): \(log.entries)")
    }

    /// 名指し宣言は**題名が部分一致するアラートにだけ**効く。別のアラートには
    /// (同じボタンがあっても)押さない —— 名指しは「このアラートが出る」という表明であって、
    /// どのアラートにでも押してよいという意味ではない
    func testANamedDeclarationDoesNotFireOnADifferentAlert() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[alertTitled("位置情報の利用"),
                                                         labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "位置情報の利用",
                                                               buttons: ["許可"])]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*トラッキング*", button: "許可"))
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("名指しと違うアラートには押さず、止まること: \(outcome.status)"); return
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("fallback.tap") },
                       "別のアラートを閉じてはいけない: \(log.entries)")
    }

    /// **未発火の登録が残る限り監視は続く**(1枚目を処理しても、まだ来ていない予告があるなら
    /// 見張りをやめない)
    func testTheWatchStaysAliveWhileAnotherRegistrationIsPending() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[alertTitled("トラッキングの許可"),
                                                         labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "トラッキングの許可"),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*トラッキング*", button: "許可"))
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "OK"))
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("閉じて進むこと"); return
        }
        let afterFirst = fallback.systemAlertCallCount
        guard case .passed = await executor.execute(step).status else {
            XCTFail("2ステップ目も通ること"); return
        }
        XCTAssertGreaterThan(fallback.systemAlertCallCount, afterFirst,
                             "未発火の予告が残っている限り見張り続けること")
    }

    /// **検証側も、発火して空になったら止まる**(操作側と同じ台帳を見る)
    func testAssertStopsProbingOnceTheRegistrationHasFired() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[alertTitled("位置情報"),
                                                         labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "位置情報"),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*位置情報*", button: "許可"))
        guard case .passed = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5)).status else {
            XCTFail("閉じたら進むこと"); return
        }
        let afterAction = fallback.systemAlertCallCount

        guard case .passed = await executor.execute(
            FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)).status else {
            XCTFail("検証も通ること"); return
        }
        XCTAssertEqual(fallback.systemAlertCallCount, afterAction,
                       "発火済みなら検証でも1往復も払わないこと")
    }

    /// screenLooksLikeEnabled=false(実行プロファイルの screenLooksLike:false)は screenMatches を skip し、
    /// delegate の verifyScreen を呼ばない
    func testScreenMatchesSkippedWhenScreenIsDisabled() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = CountingScreenDelegate()
        let executor = StepExecutor(driver: primary, delegate: delegate, screenLooksLikeEnabled: false, isAndroid: false)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .skipped(let msg) = await executor.execute(step).status else {
            XCTFail("screenLooksLike 無効なら skip のはず"); return
        }
        XCTAssertTrue(msg.contains("screenLooksLike is disabled"), "skip 理由に無効化を明示すること: \(msg)")
        XCTAssertEqual(delegate.verifyScreenCalls, 0, "無効時は verifyScreen を呼んではいけない")
        XCTAssertEqual(primary.screenshotCallCount, 0, "無効時はスクショも撮らないはず")
    }

    /// screenLooksLikeEnabled 既定(true)では screenMatches が delegate の判定どおりに動く(退行検知)
    func testScreenMatchesRunsWhenScreenIsEnabled() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = CountingScreenDelegate()
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .passed = await executor.execute(step).status else {
            XCTFail("delegate が pass を返せば pass のはず"); return
        }
        XCTAssertEqual(delegate.verifyScreenCalls, 1)
    }

    /// **screenLooksLike は不一致なら1回だけ撮り直す**(遷移直後のまだ描き終わっていない画面を救う)。
    /// 他の検証のような timeout ポーリングにしないのは、FM 照合がホスト全体で直列(約1回/秒)だから
    func testScreenMatchesRetriesOnceOnMismatch() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = ScriptedScreenDelegate([false, true])
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .passed = await executor.execute(step).status else {
            XCTFail("撮り直しで一致すれば pass のはず"); return
        }
        XCTAssertEqual(delegate.verifyScreenCalls, 2, "1回だけ撮り直すこと")
        XCTAssertEqual(primary.screenshotCallCount, 2, "撮り直しでは画像も取り直すこと")
    }

    /// 撮り直しても一致しなければ失敗。**再試行は1回で打ち切る**(FM を焼き続けない)
    func testScreenMatchesStopsAfterOneRetry() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = ScriptedScreenDelegate([false, false])
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .failed = await executor.execute(step).status else {
            XCTFail("2回とも不一致なら失敗のはず"); return
        }
        XCTAssertEqual(delegate.verifyScreenCalls, 2, "3回目を呼んではいけない")
    }

    /// **撮り直しも白フレーム検査を通す**。凍結した画面を FM に渡すと必ず不一致になるので、
    /// 素の screenshot() で撮り直すと「requeue すべき凍結」が「画面が一致しない」に化ける
    func testScreenMatchesRetryStillGuardsAgainstBlankFrames() async throws {
        let log = CallLog()
        // 1枚目は通常の画像、2枚目以降(撮り直し)は白フレーム
        let primary = FakeAppDriver(name: "primary", log: log,
                                    screenshots: [Self.nonBlankPNG] + Array(repeating: Self.blankPNG, count: 5))
        let delegate = ScriptedScreenDelegate([false])
        let frozen = CallLog()   // @Sendable クロージャからは参照型で数える
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        executor.onDeviceFrozen = { frozen.entries.append("frozen") }
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .skipped(let msg) = await executor.execute(step).status else {
            XCTFail("撮り直しが白フレームなら凍結として skip するはず"); return
        }
        XCTAssertTrue(msg.contains("frozen display"), "凍結として報告すること: \(msg)")
        XCTAssertEqual(frozen.entries.count, 1, "requeue のため onDeviceFrozen を呼ぶこと")
        XCTAssertEqual(delegate.verifyScreenCalls, 1, "白フレームを FM に渡してはいけない")
    }

    /// 一致した場合は撮り直さない(正常系のコストを増やさない)
    func testScreenMatchesDoesNotRetryWhenItPasses() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let delegate = ScriptedScreenDelegate([true])
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "screenMatches", expected: "ホーム画面")

        guard case .passed = await executor.execute(step).status else {
            XCTFail("1回目で一致すれば pass のはず"); return
        }
        XCTAssertEqual(delegate.verifyScreenCalls, 1, "正常系で撮り直してはいけない")
        XCTAssertEqual(primary.screenshotCallCount, 1)
    }

    /// 素の exist(occlusionGuard 未指定)は、隠れ判定 delegate が居ても FM を呼ばず pass(オプトイン)
    func testPlainExistsNeverInvokesGuard() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"), timeout: 1)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("ガード無効の exist は pass のはず"); return
        }
        XCTAssertEqual(delegate.visibleCalls, 0, "occlusionGuard 未指定で FM を呼んではいけない")
    }

    /// select は解決するだけでデバイス操作(tap/press 等)を一切呼ばないこと
    /// (exist と違い検証でもない = occlusionGuard も立たない。docs/design.md の select 契約)
    func testSelectResolvesWithoutDeviceOperation() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "target")]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "target"), timeout: 1)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("解決できれば select は pass するはず"); return
        }
        XCTAssertTrue(log.entries.allSatisfy { !$0.contains(".tap(") && !$0.contains(".press(") },
                     "select はデバイス操作を呼んではいけない: \(log.entries)")
    }

    /// select は**見えないとき失敗させず空要素を返す**(exist は失敗へ反転する = 意味が違う)。
    /// 呼び出し側は `.text == nil` で分岐できる
    func testSelectReturnsEmptyElementWhenNotVisible() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: false), isAndroid: false)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("select は覆われていても失敗させない。実際は \(outcome.status)"); return
        }
        XCTAssertNil(outcome.resolvedElement, "見えないなら空要素(掴めていない)を返すこと")
    }

    /// requireVisible: false 相当(occlusionGuard: false)なら照合せず掴む
    func testSelectSkipsVisibilityCheckWhenNotRequired() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: false)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("照合を外したら pass するはず。実際は \(outcome.status)"); return
        }
        XCTAssertNotNil(outcome.resolvedElement, "照合を外したら掴めていること")
        XCTAssertEqual(delegate.visibleCalls, 0, "requireVisible: false なら FM を呼ばない")
    }

    /// **select だけは掴めなくても失敗しない**(空要素を返す契約)。DSL の `.isEmpty` 分岐が
    /// 成立する前提なので、ここが failed に転ぶと利用者は掴めない要素を検知できなくなる
    func testSelectSkipsWithAnEmptyElementWhenNotFound() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "missing"), timeout: 0)

        let outcome = await executor.execute(step)

        guard case .skipped = outcome.status else {
            XCTFail("select は見つからなければ skip のはず。実際は \(outcome.status)"); return
        }
        XCTAssertNil(outcome.resolvedElement, "掴めていないので要素を返さないこと")
    }

    /// 対の検証: **select 以外は見つからなければ失敗**(シナリオ中断)。`optional:` 廃止で
    /// 「空振りを黙って許す」経路が tap/type に残っていないことを固定する
    func testTapFailsWhenNotFound() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "missing"), timeout: 0)

        guard case .failed = await executor.execute(step).status else {
            XCTFail("tap は見つからなければ失敗のはず"); return
        }
    }

    /// **申告 keyboardFrame はキー面だけ**(TapTargetGeometry.effectiveKeyboardFrame の doc)。
    /// MCP 側(MCPRefGuardTests.testTapWarnsWhenTheCentreIsOnlyUnderTheExpandedKeyboardChrome)と
    /// 同じ witness を DSL 側(StepExecutor+Actions.swift)でも固定する —— 呼び出し元が申告のまま
    /// 渡すよう後退すると、この注記が付かず落ちる
    func testTapNotesKeyboardCoverageUsingTheExpandedChromeFrame() async throws {
        let log = CallLog()
        let tabHome = ElementInfo(ref: 1, type: "button", identifier: "tab_home", label: "ホーム",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 548, width: 134, height: 62), depth: 1)
        let inputView = ElementInfo(ref: 2, type: "other", identifier: "inputView", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 546, width: 402, height: 328), depth: 1)
        let suggestBar = ElementInfo(ref: 3, type: "other", identifier: "SystemInputAssistantView",
                                     label: nil, value: nil, placeholder: nil, enabled: true,
                                     frame: FTRect(x: 0, y: 546, width: 402, height: 44), depth: 1)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[tabHome, inputView, suggestBar]])
        // 申告は 590..816 —— tab_home の中心 y=579 はこの外(修正前は無警告)
        primary.keyboardFrame = FTRect(x: 0, y: 590, width: 402, height: 226)
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "tab_home"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("tap 自体は passed のはず(警告であって拒否ではない): \(outcome.status)"); return
        }
        XCTAssertTrue(outcome.driverFallback?.contains("soft keyboard") == true,
                      "chrome で広げた実効矩形(546..874)なら中心 579 を拾って警告すること:"
                      + " \(outcome.driverFallback ?? "nil")")
    }

    /// **木に出ないオーバーレイ・ウィンドウ**の下を撃つときは注記に出す。MCP 側
    /// (MCPRefGuardTests.testTapWarnsWhenTheCentreIsUnderAnOverlayWindow)と同じ witness を
    /// DSL 側でも固定する —— 実機 Pixel 4a の Chrome で、テキスト選択のフローティング
    /// ツールバーの下にある段落へのタップが「Select all」に当たっていた
    func testTapNotesAnOverlayWindowCoveringTheCentre() async throws {
        let log = CallLog()
        let para = ElementInfo(ref: 1, type: "staticText", identifier: "content", label: "本文",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 22, y: 1062, width: 1036, height: 267), depth: 1)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[para]])
        // 実機の申告(x 88..1036 / y 1172..1304)。段落の中心 (540,1195) を含む
        primary.overlayWindowFrames = [FTRect(x: 88, y: 1172, width: 948, height: 132)]
        let executor = StepExecutor(driver: primary, isAndroid: false)

        let outcome = await executor.execute(FlowStep(action: "tap",
                                                      locator: FlowLocator(id: "content")))

        guard case .passed = outcome.status else {
            XCTFail("tap 自体は passed のはず(警告であって拒否ではない): \(outcome.status)"); return
        }
        XCTAssertTrue(outcome.driverFallback?.contains("overlay window") == true,
                      "申告された覆いを注記に出すこと: \(outcome.driverFallback ?? "nil")")
    }

    /// **中心が申告の外なら黙る**(部分的に重なっているだけの形。実機では段落の上端だけが
    /// ツールバーに掛かる形が普通に出るので、ここで喋ると毎ステップ注記が付く)
    func testTapStaysQuietWhenTheOverlayWindowMissesTheCentre() async throws {
        let log = CallLog()
        let para = ElementInfo(ref: 1, type: "staticText", identifier: "content", label: "本文",
                               value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 22, y: 732, width: 1036, height: 333), depth: 1)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[para]])
        primary.overlayWindowFrames = [FTRect(x: 88, y: 710, width: 948, height: 131)]
        let executor = StepExecutor(driver: primary, isAndroid: false)

        let outcome = await executor.execute(FlowStep(action: "tap",
                                                      locator: FlowLocator(id: "content")))

        XCTAssertFalse(outcome.driverFallback?.contains("overlay window") == true,
                       "中心が外なら黙ること: \(outcome.driverFallback ?? "nil")")
    }

    /// **chrome 自身の部品を撃つときはキーボード警告を出さない**。地球儀キーは
    /// 実効矩形の中に中心があるが chrome(`#inputView`)の子孫なので、覆っている側であって
    /// 覆われている側ではない。片方だけ生の keyboardFrame へ戻す変異(RefGuard 側は直ったが
    /// StepExecutor 側は据え置き、のような部分退行)をここで落とす
    func testTapOnTheKeyboardChromeItselfDoesNotWarnAboutTheKeyboard() async throws {
        let log = CallLog()
        let inputView = ElementInfo(ref: 1, type: "other", identifier: "inputView", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 546, width: 402, height: 328), depth: 1)
        let globeKey = ElementInfo(ref: 2, type: "button", identifier: "globe_key", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 806, width: 134, height: 68), depth: 2)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[inputView, globeKey]])
        primary.keyboardFrame = FTRect(x: 0, y: 590, width: 402, height: 226)
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "globe_key"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("tap 自体は passed のはず: \(outcome.status)"); return
        }
        XCTAssertFalse(outcome.driverFallback?.contains("soft keyboard") == true,
                       "chrome 自身の部品には keyboard 警告を出さないこと:"
                       + " \(outcome.driverFallback ?? "nil")")
    }

    /// poll-until-visible: 最初は覆われ(covered)、後で可視になる過渡的オーバーレイは、即失敗せず
    /// timeout まで待って pass する
    func testOcclusionGuardWaitsOutTransientOverlay() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let delegate = SequenceVisibilityDelegate([false, true])   // 覆い → 可視
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 3, occlusionGuard: true)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("過渡的な覆いは待って pass するはず"); return
        }
        XCTAssertGreaterThanOrEqual(delegate.calls, 2, "少なくとも covered→visible の 2 回照合すること")
    }

    /// poll-until-visible: 覆われ続ける場合は timeout で occlusion 失敗を返す
    func testOcclusionGuardFailsIfCoveredUntilTimeout() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary, delegate: SequenceVisibilityDelegate([false]), isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 1, occlusionGuard: true)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("覆われ続けたら失敗するはず"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "occlusion 失敗を返すこと: \(msg)")
    }

    /// exists のフォールバック照会は 2・4・6…回目の primary ミスでのみ発生する(間引き契約。
    /// StepExecutor+Assert.swift executeAssert "exists" 参照)
    func testExistsThrottlesFallbackQuery() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("要素なしでの timeout 切れを期待したが \(outcome.status) だった")
            return
        }
        let primaryCount = log.entries.filter { $0 == "primary.snapshot" }.count
        let fallbackCount = log.entries.filter { $0 == "fallback.snapshot" }.count
        XCTAssertGreaterThan(primaryCount, 0)
        XCTAssertLessThanOrEqual(fallbackCount, (primaryCount + 1) / 2)
        XCTAssertFalse(log.entries.prefix(2).contains("fallback.snapshot"),
                       "初回 primary ミス直後に fallback を照会してはいけない: \(log.entries)")
    }

    /// primary に無く fallback に最初から要素がある場合、primary の2回目のミス
    /// (間引きの最初の照会タイミング)で解決すること
    func testExistsResolvesViaFallbackOnSecondPrimaryMiss() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[element(ref: 1, id: "target")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "target"), timeout: 1)

        let outcome = await executor.execute(step)

        // id が step.locator(primary 位置)に一致するため resolve は fallback=nil を返し
        // .passed になる(.passedViaFallback は step.fallbacks 経由で解決した場合のみ)
        guard case .passed = outcome.status else {
            XCTFail("id 一致による解決を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(primary.snapshotCallCount, 2)
        XCTAssertEqual(fallback.snapshotCallCount, 1)
    }

    /// timeout: 0 ではロケータ再試行を行わないが、driver フォールバックの
    /// 1回照会(hybrid で解決するために必須)は timeout: 0 でも必ず行われる。
    /// 操作コマンド(tap)で解決の往復回数だけを観測する
    func testZeroTimeoutSkipsRetryButQueriesFallbackOnce() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 0)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("tap の空振りは失敗を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(primary.snapshotCallCount, 1)
        XCTAssertEqual(fallback.snapshotCallCount, 1)
        XCTAssertLessThanOrEqual(outcome.timing?.waitMs ?? 0, 5)
    }

    /// **select は driver フォールバックを照会しない**(掴むだけでデバイス操作が無く、
    /// 掴めないことが答えになり得るコマンド。fb.snapshot() は springboard セッションを張り、
    /// 同一デバイス1セッション制約でアプリ attach を潰す実害があった。StepExecutor 側の
    /// コメント参照)
    func testSelectDoesNotQueryDriverFallback() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[element(ref: 1, id: "target")]])
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "target"), timeout: 0)

        let outcome = await executor.execute(step)

        // fallback 側に要素が実在しても照会しない = 掴めず skip(空要素)になる
        guard case .skipped = outcome.status else {
            XCTFail("select の空振りは skip を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(fallback.snapshotCallCount, 0)
    }

    /// 回帰ガード: step.timeout が nil(省略)のときアクションは従来どおり
    /// 初回+3回リトライ(計4回スナップショット)のまま変わらないこと
    func testNilTimeoutKeepsLegacyThreeRetries() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(action: "select", locator: FlowLocator(id: "target"))

        let outcome = await executor.execute(step)

        guard case .skipped = outcome.status else {
            XCTFail("select の空振りは skip を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(primary.snapshotCallCount, 4)
    }

}
