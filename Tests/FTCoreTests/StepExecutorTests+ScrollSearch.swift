import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FTCore

// StepExecutorTests のスクロール探索系(notExist探索・スクロールヒント・注記・逆走査・failureKind)

extension StepExecutorTests {
    // MARK: - notExist(scroll:) の内蔵探索(exist(scroll:) の裏返し)

    /// スクロール探索を尽くしても見つからなければ、現在のビューポート(最終フレーム)でも
    /// 不在なので pass すること
    func testNotExistWithScrollPassesWhenNeverFoundDuringSearch() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], []])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "row_99"),
                            direction: "up", timeout: 0, maxSwipes: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("スクロール探索で見つからなければ pass のはず"); return
        }
    }

    /// スクロール探索中に見つかったら、現在ビューポートでの消滅待ち(通常のポーリング)には進まず
    /// 即座に不在検証を失敗させること(exist(scroll:) の裏返しなので判定は逆)
    func testNotExistWithScrollFailsWhenFoundDuringSearch() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_99", x: 16, y: 300, width: 370, height: 56)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [row]])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(id: "row_99"),
                            direction: "up", timeout: 0, maxSwipes: 2)

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("スクロール探索で見つかったら失敗のはず"); return
        }
        XCTAssertTrue(msg.contains("found via scroll search"), msg)
    }

    /// **`!result.found` を成功材料にしない**: 明示 scrollFrame が解決できず1本も振らずに
    /// 打ち切った場合も found=false になるが、それは「無いことを確認した」ではなく
    /// 探索していないだけ。notExist(scroll:) は exist(scroll:) と同じ文言で失敗する
    func testNotExistWithScrollFailsWhenScrollFrameDoesNotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(assert: "notExists", locator: FlowLocator(id: "row_99"),
                            direction: "up", timeout: 0, maxSwipes: 2)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        guard case .failed(let msg) = await executor.execute(step).status else {
            XCTFail("scrollFrame 未解決は失敗のはず"); return
        }
        XCTAssertTrue(msg.contains("search was not run"), msg)
        XCTAssertFalse(log.entries.contains { $0.contains(".swipe") },
                       "scrollFrame が解決できないなら1本も振らないこと")
    }

    /// フォールバック判定は 501 と「ルート不明の 404」だけ。409(一時的競合)と
    /// ref 不明の 404 を含めると、前面不在や古い ref を隠して別画面を操作しかねない
    func testIsEngineIncapableClassification() {
        XCTAssertTrue(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 501, body: "in-app エンジンでは press が効きません")))
        XCTAssertTrue(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 404, body: "not found: POST /drag")))
        XCTAssertFalse(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 404, body: "参照番号 [3] は未知です")))
        XCTAssertFalse(DriverError.isEngineIncapable(
            DriverError.badResponse(status: 409, body: "キーウィンドウがありません")))
        XCTAssertFalse(DriverError.isEngineIncapable(DriverError.bridgeUnreachable("timeout")))
    }

    /// 画面下端の a11y 空白帯(タブ frame の下〜画面下端)では空打ちしない。
    /// 実測座標(2026-07-28・E2E-iOS): タブ frame 下端 840・画面高 874 のとき、帯内 y=841.8 は
    /// a11y 上どの要素にも覆われないが実タブが反応した(07/16 の間欠フレークの根因)
    func testEmptyDragAvoidsBottomUncoveredBand() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let tabBar = framed(ref: 2, id: "tab_home", x: 0, y: 778, width: 134, height: 62)

        // 失敗の実測ケース: 中心 y=841.8 はタブ frame(〜840)の外だが下端帯の中 → 打たない
        let low = framed(ref: 1, id: "txt", x: 16, y: 831.7, width: 111.3, height: 20.3)
        XCTAssertFalse(StepExecutor.emptyDragIsSafe(
            x: 71.7, y: 841.8, of: low, in: [low, tabBar], screen: screen))

        // タブ frame 内は従来どおり pointIsTakenByFrontElement が拒否する
        let inBand = framed(ref: 1, id: "txt", x: 16, y: 815.7, width: 111.3, height: 20.3)
        XCTAssertFalse(StepExecutor.emptyDragIsSafe(
            x: 71.7, y: 825.8, of: inBand, in: [inBand, tabBar], screen: screen))

        // 帯より上で手前要素も無ければ打ってよい(通常のリスト内)
        let mid = framed(ref: 1, id: "row", x: 16, y: 700, width: 370, height: 56)
        XCTAssertTrue(StepExecutor.emptyDragIsSafe(
            x: 201, y: 728, of: mid, in: [mid, tabBar], screen: screen))
    }

    /// **全幅の行では空打ちの終点が作れない**ので撃たない。左右どちらへも 4pt 出られないとき、
    /// 以前は開始点をそのまま返しており、始点=終点の 0.30 秒プレスは**タップとして成立する**
    /// —— emptyDragEndX の doc が禁じている「矩形の中で離す」を実装自身が踏んでいた。
    /// 実機(iPhone 実機・SmartNews の全幅セル)で `ft_scroll_to` が記事を開く形で 2/2 再現(2026-08-14)
    func testEmptyDragEndXRefusesWhenItCannotLeaveTheElement() {
        let screen = FTRect(x: 0, y: 0, width: 393, height: 852)

        let fullBleed = framed(ref: 1, id: "cell", x: 0, y: 103, width: 393, height: 116)
        XCTAssertNil(StepExecutor.emptyDragEndX(of: fullBleed, from: 196.5, screen: screen),
                     "全幅の行は抜けられないので撃たないこと")

        // インセットの行(自前 SUT の形)は従来どおり右へ抜ける
        let inset = framed(ref: 2, id: "row_30", x: 16, y: 270, width: 330, height: 56)
        XCTAssertEqual(StepExecutor.emptyDragEndX(of: inset, from: 181, screen: screen), 350)
        // 右端に貼り付いた行は左へ抜ける
        let atRight = framed(ref: 3, id: "row", x: 200, y: 270, width: 193, height: 56)
        XCTAssertEqual(StepExecutor.emptyDragEndX(of: atRight, from: 296, screen: screen), 196)

        // 返す点は必ず矩形の外(この不変条件が破れた瞬間にタップになる)
        for element in [inset, atRight] {
            let end = StepExecutor.emptyDragEndX(of: element, from: element.frame.centerX,
                                                 screen: screen)
            XCTAssertNotNil(end)
            if let end {
                XCTAssertFalse(end > element.frame.x && end < element.frame.x + element.frame.width,
                               "終点が矩形の中に留まるとクリックとして成立する: \(end)")
            }
        }
    }

    /// 配線: 探索終端の空打ちが**全幅の行では1本も撃たれない**こと。純粋関数だけを固定すると
    /// 「呼び出しを外す」変異が生き残るので、同じ台本をインセット行でも回して
    /// **陽性対照を同じテストの中に置く**(空打ちに到達しない台本だと無条件に緑になる)
    func testSearchTerminalDoesNotEmptyDragAFullBleedRow() async throws {
        /// 台本: 1回目は対象が無く、スワイプ後に出現する(= 終端の空打ちが掛かる周回)
        func horizontalDrags(targetX: Double, width: Double) async -> [(fromX: Double,
                                                                       fromY: Double,
                                                                       toX: Double, toY: Double)] {
            let log = CallLog()
            let container = framed(ref: 100, id: "list", x: 0, y: 0, width: 400, height: 700,
                                   depth: 1)
            let filler = framed(ref: 1, id: "cell_01", x: targetX, y: 100, width: width,
                                height: 116, depth: 2)
            let target = framed(ref: 2, id: "cell_40", x: targetX, y: 300, width: width,
                                height: 116, depth: 2)
            // 先頭を対象なしで数枚埋める(1周が何枚読むかに依存せず、必ず attempt > 0 で
            // 見つかるようにする = 終端の空打ちが掛かる周回に入る)
            let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
                [container, filler],
                [container, filler],
                [container, filler],
                [container, filler, target],
            ])
            let executor = StepExecutor(driver: primary, releasesScrollTouch: true)
            _ = await executor.execute(FlowStep(action: "tap",
                                                locator: FlowLocator(id: "cell_40"),
                                                direction: "up", maxSwipes: 6))
            return primary.dragCalls.filter { $0.fromY == $0.toY }
        }

        // 陽性対照: インセット(画面 400 幅に対し 16..386)なら従来どおり空打ちが出る
        let inset = await horizontalDrags(targetX: 16, width: 370)
        XCTAssertFalse(inset.isEmpty, "台本が終端の空打ちに到達していない(この検査は無力)")

        // 本題: 全幅(0..400)では1本も出ない
        let fullBleed = await horizontalDrags(targetX: 0, width: 400)
        XCTAssertTrue(fullBleed.isEmpty,
                      "全幅の行に空打ちを撃ってはいけない(矩形から出られずタップになる): \(fullBleed)")
    }

    /// 掃討: 空打ちの呼び出しは**2箇所**(探索終端と救済の後)。救済側も全幅の行では撃たない。
    /// 陽性対照は `testRecoverySwipeIsFollowedByTheEmptyDrag`(同じ台本のインセット版で
    /// 横ドラッグが出ることを固定している)
    func testRecoveryEmptyDragIsSkippedForAFullBleedRow() async throws {
        let log = CallLog()
        let container = framed(ref: 100, id: "list_rows", x: 0, y: 230, width: 400, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 0, y: 300, width: 400, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 0, y: 360, width: 400, height: 56, depth: 2)
        let target = framed(ref: 3, id: "row_30", x: 0, y: 420, width: 400, height: 56, depth: 2)
        let ghost = framed(ref: 4, id: "row_30", x: 0, y: 783, width: 400, height: 56, depth: 2)
        let settled = framed(ref: 5, id: "row_30", x: 0, y: 430, width: 400, height: 56, depth: 2)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container, inside1, inside2, target],
            [container, inside1, inside2, target],
            [container, inside1, inside2, ghost],
            [container, inside1, inside2, ghost],
            [container, inside1, inside2, settled],
        ])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 2)

        _ = await executor.execute(step)

        let horizontal = primary.dragCalls.filter { $0.fromY == $0.toY }
        XCTAssertTrue(horizontal.isEmpty,
                      "救済後の空打ちも全幅の行では撃たないこと: \(primary.dragCalls)")
    }

    /// 要素数の上限で打ち切られたスナップショットは「見つかりません」と区別が付かない。
    /// 失敗文言に必ず打ち切りを添える(WebView 画面は要素が多く最も当たりやすい)
    func testTruncationHint() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        func snapshot(_ elements: [ElementInfo], truncated: Int) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: screen,
                             elements: elements, truncatedCount: truncated)
        }
        let button = framed(ref: 1, id: "btn", x: 0, y: 0, width: 10, height: 10)

        XCTAssertEqual(StepExecutor.truncationHint(nil), "")
        XCTAssertEqual(StepExecutor.truncationHint(snapshot([button], truncated: 0)), "",
                       "打ち切られていなければ何も足さない")

        let hint = StepExecutor.truncationHint(snapshot([button], truncated: 30))
        XCTAssertTrue(hint.contains("30"), hint)
        XCTAssertFalse(hint.contains("WebView"), "WebView が無い画面で WebView の話をしない")

        let webView = ElementInfo(ref: 2, type: "WebView", identifier: nil, label: nil, value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: screen, depth: 0)
        let webHint = StepExecutor.truncationHint(snapshot([button, webView], truncated: 30))
        XCTAssertTrue(webHint.contains("WebView"), webHint)
    }

    /// WebView 画面の失敗には**どの経路で読んだか**を添える。DOM 経路の未検出は
    /// 「無反応タップが成功として記録され、2ステップ先で別の文言で落ちる」形で出るため、
    /// 落ちた側に経路が書いていないと原因まで辿れない。
    /// **経路はドライバの申告(webViewPath)だけで決める**。要素の形から推測すると
    /// Android(webView 型は出るが web フラグは持たない)が XCUITest 委譲を名乗る
    func testWebViewPathHint() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let webView = ElementInfo(ref: 1, type: "WebView", identifier: nil, label: nil, value: nil,
                                  placeholder: nil, enabled: true, frame: screen, depth: 0)
        let content = ElementInfo(ref: 2, type: "StaticText", identifier: nil, label: "本文",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
        func snapshot(_ path: String?) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [webView, content],
                             truncatedCount: 0, webViewPath: path)
        }

        XCTAssertEqual(StepExecutor.webViewPathHint(nil), "")

        let dom = StepExecutor.webViewPathHint(snapshot("dom"))
        XCTAssertTrue(dom.contains("DOM path"), dom)
        XCTAssertTrue(dom.contains("nothing responds"), "無反応タップの可能性まで書くこと: \(dom)")

        let delegated = StepExecutor.webViewPathHint(snapshot("delegated"))
        XCTAssertTrue(delegated.contains("XCUITest"), delegated)
        XCTAssertFalse(delegated.contains("無反応"), "委譲側は合成タッチを使わないので警告しない")

        // dom-interop: DOM は読めるが操作は実タッチ(XCUITest)で行う第三のモード。
        // "dom" と違い DOM-tap の無反応な成功記録という弱点を持たないので、その警告は出さない
        let domInterop = StepExecutor.webViewPathHint(snapshot("dom-interop"))
        XCTAssertTrue(domInterop.contains("XCUITest"), domInterop)
        XCTAssertTrue(domInterop.lowercased().contains("real") || domInterop.lowercased().contains("touch"),
                      domInterop)
        XCTAssertFalse(domInterop.contains("無反応"), "実タッチを使うので無反応警告は出さない: \(domInterop)")
        XCTAssertFalse(domInterop.contains("nothing responds"), "DOM-tap の弱点は無い: \(domInterop)")

        // **Android**: WebView 要素は出るが経路の申告は無い。XCUITest を名乗ってはいけない
        // (Android に XCUITest は存在せず、デバッグ中の人を誤誘導する)
        let android = StepExecutor.webViewPathHint(snapshot(nil))
        XCTAssertEqual(android, "", "申告が無ければ何も足さない: \(android)")

        // 通常画面(WebView 要素すら無い)も当然そのまま
        let plain = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [content],
                                     truncatedCount: 0)
        XCTAssertEqual(StepExecutor.webViewPathHint(plain), "")
    }

    // MARK: - スクロールヒント(WebView の画面外ノードによる長距離ドラッグ)

    private func hintSnapshot(screen: FTRect, elements: [ElementInfo] = [],
                              hints: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements,
                         truncatedCount: 0, offscreen: hints)
    }

    private func hint(_ label: String, y: Double, height: Double = 100) -> ElementInfo {
        ElementInfo(ref: 0, type: "StaticText", identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 42, y: y, width: 1000, height: height), depth: 0)
    }

    private func scrollStep(_ label: String) -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(label: label), direction: "up", maxSwipes: 15)
    }

    /// 下方向のヒント一致 → 正のジャンプ(指を上へ)。目標は要素上端が画面の 40% 位置
    func testOffscreenJumpTowardsBelow() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let snapshot = hintSnapshot(screen: screen, hints: [hint("画面外テキスト", y: 7000)])
        let jump = StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                              snapshot: snapshot, finger: .up)
        XCTAssertEqual(jump ?? -1, 7000 - 2400 * 0.4, accuracy: 0.5)
    }

    /// 方向が合わないヒントは使わない(逆向きに引き返して往復しない)
    func testOffscreenJumpIgnoresWrongDirection() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let above = hintSnapshot(screen: screen, hints: [hint("画面外テキスト", y: -3000)])
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                                snapshot: above, finger: .up))
        XCTAssertNotNil(StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                                   snapshot: above, finger: .down))
    }

    /// ヒントに無いラベル・水平方向・ヒント無しは nil(従来のスワイプへ)
    func testOffscreenJumpFallsBackToSwipe() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let snapshot = hintSnapshot(screen: screen, hints: [hint("別の要素", y: 7000)])
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                                snapshot: snapshot, finger: .up))
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("別の要素"),
                                                snapshot: snapshot, finger: .left))
        let empty = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [],
                                     truncatedCount: 0)
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("別の要素"),
                                                snapshot: empty, finger: .up))
    }

    /// もう画面のすぐ近く(30% 以内)なら跳ばない(通常ループの1スワイプで足りる。
    /// 近距離のドラッグはフリング過走で行き過ぎるリスクの方が大きい)
    func testOffscreenJumpSkipsNearTargets() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let near = hintSnapshot(screen: screen, hints: [hint("画面外テキスト", y: 2400 * 0.4 + 500)])
        XCTAssertNil(StepExecutor.offscreenJump(step: scrollStep("画面外テキスト"),
                                                snapshot: near, finger: .up))
    }

    /// 端までの残り: 下端はヒント最下端まで、上端はヒント最上端まで
    func testOffscreenEdgeJump() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let below = hintSnapshot(screen: screen,
                                 hints: [hint("a", y: 5000), hint("b", y: 7000, height: 200)])
        XCTAssertEqual(StepExecutor.offscreenEdgeJump(snapshot: below, finger: .up) ?? -1,
                       7200 - 2400, accuracy: 0.5)
        XCTAssertNil(StepExecutor.offscreenEdgeJump(snapshot: below, finger: .down),
                     "上方向にヒントが無ければ跳ばない")
        // 端の閾値は 100px(過走が端でクランプされるため scrollTo の 30% より攻められる)
        let close = hintSnapshot(screen: screen, hints: [hint("a", y: 2400 + 50, height: 100)])
        XCTAssertNotNil(StepExecutor.offscreenEdgeJump(snapshot: close, finger: .up))
        let above = hintSnapshot(screen: screen, hints: [hint("a", y: -2510)])
        XCTAssertEqual(StepExecutor.offscreenEdgeJump(snapshot: above, finger: .down) ?? 1,
                       -2510, accuracy: 0.5)
    }

    /// ドラッグの始点・終点: コンテナ内・上下 15% マージン・距離は 0.9 掛けと可動域でクランプ
    func testDragGestureGeometry() {
        let container = FTRect(x: 0, y: 332, width: 1080, height: 1900)
        // 指を上へ: 下端マージンから上へ
        let up = StepExecutor.dragGesture(jump: 1000, container: container)
        XCTAssertNotNil(up)
        XCTAssertEqual(up!.fromX, 540)
        XCTAssertEqual(up!.fromY, 332 + 1900 - 285, accuracy: 0.5)   // マージン 15% = 285
        XCTAssertEqual(up!.fromY - up!.toY, 900, accuracy: 0.5)      // 1000 * 0.9
        // 長距離は可動域(70%)でクランプ
        let far = StepExecutor.dragGesture(jump: 10000, container: container)
        XCTAssertEqual(far!.fromY - far!.toY, 1900 * 0.7, accuracy: 0.5)
        // 指を下へ: 上端マージンから下へ
        let down = StepExecutor.dragGesture(jump: -1000, container: container)
        XCTAssertEqual(down!.toY - down!.fromY, 900, accuracy: 0.5)
        // 潰れたコンテナ・極小距離は nil
        XCTAssertNil(StepExecutor.dragGesture(jump: 1000,
                                              container: FTRect(x: 0, y: 0, width: 100, height: 120)))
        XCTAssertNil(StepExecutor.dragGesture(jump: 40, container: container))
    }

    /// 見切れ回収の必要距離(符号は dragGesture 規約: + = 指を上/左)。
    /// 全幅フリングの往復振動(RN 横カルーセルで maxSwipes 使い切り)を距離指定で置き換える根拠
    func testClipRecoveryJumpPerEdge() {
        let vp = FTRect(x: 16, y: 690, width: 370, height: 60)
        func el(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
            ElementInfo(ref: 1, type: "button", identifier: "tag", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
        }
        // 右へはみ出し(右端 500 > 386)→ 指を左(+)・量 = 114 + 24
        XCTAssertEqual(StepExecutor.clipRecoveryJump(for: el(380, 690, 120, 60), viewport: vp,
                                                     finger: .left) ?? 0, 138, accuracy: 0.5)
        // 左へはみ出し → 指を右(−)
        XCTAssertEqual(StepExecutor.clipRecoveryJump(for: el(-40, 690, 120, 60), viewport: vp,
                                                     finger: .right) ?? 0, -80, accuracy: 0.5)
        // 下へはみ出し → 指を上(+)
        XCTAssertEqual(StepExecutor.clipRecoveryJump(for: el(16, 740, 120, 56), viewport: vp,
                                                     finger: .up) ?? 0, 70, accuracy: 0.5)
        // 完全に見えている → nil(回収不要)
        XCTAssertNil(StepExecutor.clipRecoveryJump(for: el(20, 692, 120, 56), viewport: vp,
                                                   finger: .left))
    }

    /// 横方向のドラッグ(逆走査の横対応。2026-08-08: RN 横 FlatList の飛び越し救済が動機)。
    /// jump > 0 = 指を左(縦の「+ = 上」と同じ「進む向き」規約)・y は容器の中心線
    func testDragGestureHorizontalGeometry() {
        let container = FTRect(x: 16, y: 690, width: 370, height: 60)
        // 指を左へ: 右端マージンから左へ
        let left = StepExecutor.dragGesture(jump: 200, container: container, vertical: false)
        XCTAssertNotNil(left)
        XCTAssertEqual(left!.fromY, 720)                              // y = 中心線
        XCTAssertEqual(left!.toY, 720)
        XCTAssertEqual(left!.fromX, 16 + 370 - 370 * 0.15, accuracy: 0.5)
        XCTAssertEqual(left!.fromX - left!.toX, 180, accuracy: 0.5)   // 200 * 0.9
        // 指を右へ: 左端マージンから右へ
        let right = StepExecutor.dragGesture(jump: -200, container: container, vertical: false)
        XCTAssertEqual(right!.toX - right!.fromX, 180, accuracy: 0.5)
        // 幅が細い容器は nil(縦と同じ下限規則が幅に掛かる)
        XCTAssertNil(StepExecutor.dragGesture(
            jump: 200, container: FTRect(x: 0, y: 0, width: 120, height: 800), vertical: false))
    }

    /// **容器は画面と交差させる**(scrollFrame 側と同じ規則)。交差を取らないと画面外の座標を撃つ
    func testDragGestureClipsTheContainerToTheViewport() {
        // 画面(高さ 2400)より下へはみ出した容器
        let container = FTRect(x: 0, y: 332, width: 1080, height: 3000)
        let viewport = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let clipped = StepExecutor.dragGesture(jump: 5000, container: container, viewport: viewport)
        XCTAssertNotNil(clipped)
        // 交差は y 332..2400(高さ 2068)。始点は下端マージン(15%)の内側 = 画面内
        XCTAssertLessThanOrEqual(clipped!.fromY, 2400)
        XCTAssertEqual(clipped!.fromY, 332 + 2068 - 2068 * 0.15, accuracy: 0.5)
        // viewport を渡さなければ従来どおり(既存の呼び出しを壊さない)
        let raw = StepExecutor.dragGesture(jump: 5000, container: container)
        XCTAssertGreaterThan(raw!.fromY, 2400, "交差を取らないと画面外を撃つ = これが直した対象")
    }

    /// 探索終端の静止待ちを**打ち切ったら注記にする**。黙って返すと「まだ動いている画面で
    /// 掴んだ座標」を後段がタップし、失敗が沈黙(誤った成功)として現れる
    func testScrollSearchNoteReportsAnUnsettledSearch() {
        let capped = StepExecutor.ScrollSearchResult(found: true, fallback: nil, viaXCUITest: false,
                                                     hintJumps: 0, settleCapped: true)
        XCTAssertEqual(StepExecutor.scrollSearchNote(capped),
                       "the screen did not settle after the search (poll limit)")
        // 静止できていれば無言(通常運転で注記を出さない = 出たときに意味がある)
        let settled = StepExecutor.ScrollSearchResult(found: true, fallback: nil, viaXCUITest: false,
                                                      hintJumps: 0)
        XCTAssertNil(StepExecutor.scrollSearchNote(settled))
    }

    /// 飛び越しの拾い直しは**指定すべき容器の名前まで**返す。総称のままだと、読み手は
    /// 名前を探すためにスナップショットを撮り直すことになる
    func testScrollSearchNoteNamesTheContainerToSpecify() {
        var named = StepExecutor.ScrollSearchResult(found: true, fallback: nil, viaXCUITest: false,
                                                    hintJumps: 0)
        named.reverseSweeps = 1
        named.suggestedScrollFrame = "#list_rows"
        XCTAssertEqual(StepExecutor.scrollSearchNote(named),
                       "found by sweeping back after overshooting it"
                       + " (specify scrollFrame: #list_rows to step within the container instead)")
        // 名指しできない容器(id もラベルも無い)では総称のまま = 存在しない名前を勧めない
        var unnamed = named
        unnamed.suggestedScrollFrame = nil
        XCTAssertEqual(StepExecutor.scrollSearchNote(unnamed),
                       "found by sweeping back after overshooting it"
                       + " (specify scrollFrame: to step within the container instead)")
    }

    // MARK: - 機械可読な注記(StepNote)

    // MARK: - 半開きシートの逆走査の後回し(defersPartialSheetRecovery)

    /// 半開きシート(部分高の容器)で停滞する台本。1周目だけ動かして scrolledContainer を
    /// 立て、以後は同一ツリー(最後の要素が繰り返される規約で停滞になる)
    private func partialSheetStallScript() -> [[ElementInfo]] {
        func tree(offset: Double) -> [ElementInfo] {
            // 移動後も**2つ以上の行が容器の中に残る**こと(clippingContainer の推測条件)。
            // 残りが1つだと容器が特定できず、逆走査の前段で黙って諦めてしまい台本にならない
            [ElementInfo(ref: 1, type: "scrollView", identifier: "sheet_list", label: nil,
                         value: nil, placeholder: nil, enabled: true,
                         frame: FTRect(x: 0, y: 500, width: 400, height: 250), depth: 0,
                         scrollable: true),
             framed(ref: 2, id: "row_a", x: 16, y: 520 - offset, width: 368, height: 40, depth: 1),
             framed(ref: 3, id: "row_b", x: 16, y: 590 - offset, width: 368, height: 40, depth: 1),
             framed(ref: 4, id: "row_c", x: 16, y: 660 - offset, width: 368, height: 40, depth: 1)]
        }
        return [tree(offset: 0), tree(offset: 0), tree(offset: 60)]
    }

    /// defersPartialSheetRecovery=true(MCP の1回目)は、半開きシートの停滞で
    /// **逆走査を掛けずに** sheetCollapsed で即返すこと(実測 7.8s の丸損を払わない。
    /// 救済は呼び手の「展開して再試行」側の全画面高の逆走査が引き継ぐ)
    func testPartialSheetStallSkipsReverseSweepWhenDeferred() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: partialSheetStallScript())
        let executor = StepExecutor(driver: primary, defersPartialSheetRecovery: true)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_target"),
                            maxSwipes: 6)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else { XCTFail("見つからないので failed のはず"); return }
        XCTAssertTrue(executor.noteCodesThisStep.contains(.sheetCollapsed),
                      "シート展開の合図は従来どおり出すこと")
        XCTAssertTrue(primary.dragCalls.isEmpty,
                      "後回し指定では逆走査のドラッグを撃たないこと: \(primary.dragCalls)")
    }

    /// 既定(DSL・MCP の再試行)は従来どおり逆走査で拾い直しに行くこと。
    /// 上のテストと対(「常に逆走査を切る」変異はこちらが落とす)
    func testPartialSheetStallStillReverseSweepsByDefault() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: partialSheetStallScript())
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_target"),
                            maxSwipes: 6)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else { XCTFail("見つからないので failed のはず"); return }
        XCTAssertFalse(primary.dragCalls.isEmpty,
                       "既定では逆走査のドラッグで拾い直しに行くこと(DSL の唯一の救済)")
    }

    /// 探索の打ち切りは文言が別(「after the search」)でも同じコードで数えること
    func testScrollSearchNoteRecordsTheSameCode() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog()))
        var capped = StepExecutor.ScrollSearchResult(found: true, fallback: nil,
                                                     viaXCUITest: false, hintJumps: 0)
        capped.settleCapped = true

        let note = executor.recordedScrollSearchNote(capped)

        XCTAssertEqual(note, "the screen did not settle after the search (poll limit)")
        XCTAssertTrue(executor.noteCodesThisStep.contains(.settleCapped),
                      "文言を出したのにコードを立てないと集計に乗らない")
    }

    /// **シート展開の判定を機械可読でも出す**: MCP はこのコードで
    /// 「グラバーを引いて1度だけ再試行」へ分岐する。文言(scrollNotFoundMessage の
    /// half-open bottom sheet)と**同じ条件**であること —— 片方だけ変わると、
    /// 案内は出るのに自動展開が黙って効かなくなる
    func testSheetCollapsedCodeFollowsTheSameConditionAsTheHint() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog()))
        var stopped = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                      viaXCUITest: false, hintJumps: 0)
        stopped.stoppedUnmoving = true
        stopped.containerIsPartialHeight = true

        _ = executor.recordedScrollSearchNote(stopped)

        XCTAssertTrue(executor.noteCodesThisStep.contains(.sheetCollapsed))
    }

    /// 全画面リストの末尾到達では立てない(毎回シートを広げにいかせない)
    func testSheetCollapsedCodeIsNotSetForAFullHeightContainer() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog()))
        var stopped = StepExecutor.ScrollSearchResult(found: false, fallback: nil,
                                                      viaXCUITest: false, hintJumps: 0)
        stopped.stoppedUnmoving = true
        stopped.containerIsPartialHeight = false

        _ = executor.recordedScrollSearchNote(stopped)

        XCTAssertFalse(executor.noteCodesThisStep.contains(.sheetCollapsed))
    }

    /// 打ち切っていないときは何も立てないこと(上の検証を「常に立てる」実装で通さないための対)
    func testScrollSearchNoteRecordsNothingWhenSettled() {
        let executor = StepExecutor(driver: FakeAppDriver(name: "primary", log: CallLog()))
        let settled = StepExecutor.ScrollSearchResult(found: true, fallback: nil,
                                                      viaXCUITest: false, hintJumps: 0)

        XCTAssertNil(executor.recordedScrollSearchNote(settled))
        XCTAssertTrue(executor.noteCodesThisStep.isEmpty)
    }

    /// 動き続ける画面で打ち切ったとき、注記の文言とコードが**両方**出ること
    /// (片方だけだと「レポートには出ているのに集計に乗らない」が起きる)
    func testSettleCapIsReportedAsBothTextAndCode() async throws {
        let log = CallLog()
        let moving = (0..<200).map { movingRow(y: Double($0) * 10) }
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: moving)
        let executor = StepExecutor(driver: primary)

        let outcome = await executor.execute(
            FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3))

        XCTAssertTrue(outcome.driverFallback?.contains(StepNote.settleCapped.text) == true,
                      "表示: \(outcome.driverFallback ?? "-")")
        XCTAssertEqual(outcome.notes, [.settleCapped])
    }

    /// 注記は**ステップごとに捨てる**こと(前ステップの打ち切りを次ステップへ持ち越さない)
    func testNotesAreResetBetweenSteps() async throws {
        let log = CallLog()
        let moving = (0..<200).map { movingRow(y: Double($0) * 10) }
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: moving)
        let executor = StepExecutor(driver: primary)
        let capped = await executor.execute(
            FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3))
        XCTAssertEqual(capped.notes, [.settleCapped], "前提: 1本目は打ち切られていること")

        // 以降は同じフレームを返し続ける(尽きたら最後を繰り返す規約)= 静止した画面
        primary.snapshotElements = [movingRow(y: 100)]

        let settled = await executor.execute(
            FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3))

        XCTAssertEqual(settled.notes, [], "静止した画面のステップに前ステップの注記が残っている")
    }

    /// 「なぜ撮り直すか」→「実際に迂回するか」の対応。**ソース走査の guard では届かない**
    /// (方針が1箇所に寄ったので、call site の字面を見ても分からない)。
    /// とくに `.afterSearch(swiped: false)` が false になることが要 —— ここが true に倒れると
    /// 探索が1度もスワイプしていない場合まで毎回撮り直し、計測済みの所要が静かに増える
    func testBypassPolicyTruthTable() {
        let driver = FakeAppDriver(name: "primary", log: CallLog())
        let executor = StepExecutor(driver: driver)

        driver.bypassSupported = true
        XCTAssertTrue(executor.bypassesCache(.afterOwnMove))
        XCTAssertTrue(executor.bypassesCache(.afterSearch(swiped: true)))
        XCTAssertFalse(executor.bypassesCache(.afterSearch(swiped: false)),
                       "探索がスワイプしていないなら木は古くならない(撮り直しは無駄)")

        // 対応していないドライバでは理由によらず迂回しない(フラグを送っても意味が無い)
        driver.bypassSupported = false
        XCTAssertFalse(executor.bypassesCache(.afterOwnMove))
        XCTAssertFalse(executor.bypassesCache(.afterSearch(swiped: true)))
    }

    /// 理由が実際に driver まで届くこと(helper が握り潰していないこと)
    func testFreshSnapshotForwardsTheDecisionToTheDriver() async throws {
        let driver = FakeAppDriver(name: "primary", log: CallLog())
        driver.bypassSupported = true
        let executor = StepExecutor(driver: driver)

        _ = try await executor.freshSnapshot(.afterSearch(swiped: false))
        XCTAssertEqual(driver.bypassedSnapshotCount, 0)

        _ = try await executor.freshSnapshot(.afterOwnMove)
        XCTAssertEqual(driver.bypassedSnapshotCount, 1)
    }

    private func movingRow(y: Double) -> [ElementInfo] {
        [ElementInfo(ref: 1, type: "cell", identifier: "row_01", label: "行 01", value: nil,
                     placeholder: nil, enabled: true,
                     frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 0)]
    }

    // MARK: - 失敗の素性(結果 JSON の failureKind)

    /// 解決できないロケータは `not-found`。**「画面が違う」と「セレクタが古い」は区別しない**
    /// (どちらもこの経路。事実だけを言う)
    func testUnresolvableLocatorIsMarkedNotFound() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[element(ref: 1, id: "other")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "missing"), timeout: 1)

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.failureKind, .notFound)
    }

    /// 掴めたが期待値と違うのは `assertion`(見つからない・到達できないと分けられること)
    func testValueMismatchIsMarkedAssertion() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"), timeout: 1)
        step.expected = "さようなら"

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.failureKind, .assertion)
    }

    /// 同じ assert でも**要素が居ない**なら not-found(assertion で塗り潰さない)
    func testMissingElementInAnAssertIsStillNotFound() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"), timeout: 1)
        step.expected = "なんでも"

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.failureKind, .notFound)
    }

    /// ブリッジへ到達できない失敗は `driver-unreachable`(ステップの内容と独立に起きる形)
    func testUnreachableDriverIsMarkedDriverUnreachable() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[element(ref: 1, id: "btn")]])
        primary.swipeError = DriverError.bridgeUnreachable("connection reset")
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "swipe", direction: "up")

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.failureKind, .driverUnreachable)
    }

    /// 成功したステップに素性は付かない(「失敗の内訳」に成功が混ざらない)
    func testSuccessfulStepsCarryNoFailureKind() async throws {
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[element(ref: 1, id: "btn")]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn"), timeout: 1)

        let outcome = await executor.execute(step)

        XCTAssertNil(outcome.failureKind)
    }

}
