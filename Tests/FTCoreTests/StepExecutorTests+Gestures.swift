import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FTCore

// StepExecutorTests のジェスチャ系(swipe/pinch/doubleTap/scroll探索・scrollFrame)

extension StepExecutorTests {
    // MARK: - ジェスチャのドライバフォールバック(Compose)

    /// 501(このエンジンでは未対応)なら swipe を typeDriver へ切り替え、driverFallback を記録すること
    func testSwipe501FallsBackToTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.swipeError = DriverError.badResponse(status: 501, body: "compose では swipe が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        guard case .passed = outcome.status else {
            XCTFail("501 からの切替で passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        // 末尾に続く primary.snapshot は swipe 後の静止待ち(settledSignature)
        XCTAssertEqual(Array(log.entries.prefix(2)), ["primary.swipe(throws)", "typedriver.swipe"])
        XCTAssertTrue(log.entries.dropFirst(2).allSatisfy { $0 == "primary.snapshot" },
                      "静止待ち以外が混ざっている: \(log.entries)")
    }

    /// 409(キーウィンドウ不在等の一時的な競合)ではジェスチャを切り替えないこと。
    /// 切り替えると「アプリが前面に無い」状況を隠して別画面を操作しかねない
    func testSwipe409DoesNotFallBack() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        primary.swipeError = DriverError.badResponse(status: 409, body: "キーウィンドウがありません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        guard case .failed = outcome.status else {
            XCTFail("409 は失敗のままを期待したが \(outcome.status) だった")
            return
        }
        XCTAssertNil(outcome.driverFallback)
        XCTAssertEqual(log.entries, ["primary.swipe(throws)"], "typeDriver を呼んではいけない")
    }

    /// typeDriverGestures に swipe が申告されていれば 501 を待たず最初から typeDriver で撃つこと
    func testTypeDriverGesturesRoutesSwipeUpfront() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    typeDriverGestures: ["swipe", "press"])

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(log.entries.first, "typedriver.swipe", "primary を無駄打ちしてはいけない")
        XCTAssertTrue(log.entries.dropFirst().allSatisfy { $0 == "primary.snapshot" },
                      "swipe 後は静止待ちの snapshot だけが続くはず: \(log.entries)")
    }

    /// **アクション別ルーティング**: press だけの申告(uikit)で swipe まで typeDriver へ回さないこと。
    /// 一括 Bool だった頃、press の申告だけで scrollTo の swipe が XCUITest 実スワイプ化し、
    /// バウンス由来の非決定性で下端の行タップが flake した(2026-07-23 実害)。
    func testPressOnlyDeclarationKeepsSwipeOnPrimary() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log)
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    typeDriverGestures: ["press"])

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        XCTAssertNil(outcome.driverFallback, "press だけの申告で swipe を typeDriver へ回さない")
        // swipe 後の snapshot は静止待ち(settledSignature)。ランナーが /swipe を整定対象から
        // 外したぶんをホスト側で持つため、swipe の**あとに** primary の snapshot が続くのが正
        XCTAssertEqual(log.entries.first, "primary.swipe", "swipe は primary(in-app)で実行するはず")
        XCTAssertTrue(log.entries.dropFirst().allSatisfy { $0 == "primary.snapshot" },
                      "静止待ち以外の呼び出しが混ざっている: \(log.entries)")
    }

    /// tap(holdSeconds:) の 501 切替は ref を typeDriver 側 snapshot で取り直すこと(ref はブリッジごとに別名前空間)
    func testTapHoldSeconds501FallsBackAndReresolvesRef() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        primary.pressError = DriverError.badResponse(status: 501, body: "compose では press が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 9, id: "btn_long")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "btn_long"), duration: 1.0)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("501 からの切替で passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(log.entries, [
            "primary.snapshot",
            "primary.press(throws)",
            "typedriver.snapshot",
            "typedriver.press(ref:9)",
        ], "typeDriver 側の ref(9)で press すべき")
    }

    /// FlowStep.duration(tap の holdSeconds)は主経路にもフォールバック経路にも届くこと(旧実装は両方 1.0 固定で、
    /// DSL の press(duration:)が黙って無効化されていた)
    func testTapHoldSecondsIsPassedThroughBothPaths() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        let executor = StepExecutor(driver: primary)
        _ = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_long"), duration: 3.5))
        XCTAssertEqual(primary.lastPressDuration, 3.5)

        let fallbackLog = CallLog()
        let failing = FakeAppDriver(name: "primary", log: fallbackLog,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        failing.pressError = DriverError.badResponse(status: 501, body: "compose では press が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: fallbackLog,
                                       snapshotElements: [[element(ref: 9, id: "btn_long")]])
        let fallbackExecutor = StepExecutor(driver: failing, typeDriver: typeDriver)
        _ = await fallbackExecutor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_long"), duration: 3.5))
        XCTAssertEqual(typeDriver.lastPressDuration, 3.5)
    }

    /// duration 未指定(既定 holdSeconds=0)は通常タップになり、press は呼ばれないこと
    /// (tap/press 統合の要点: 既定を境に呼び先が変わる)
    func testTapDurationDefaultsToPlainTapWhenUnset() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "btn_long")]])
        let executor = StepExecutor(driver: primary)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "btn_long")))
        XCTAssertNil(primary.lastPressDuration, "既定は通常タップで press を呼ばないはず")
        XCTAssertEqual(log.entries.last, "primary.tap(ref:1)")
    }

    /// 409(inapp が非 UIKit 入力欄で first responder を張れない)はリアクティブに typeDriver へ切り替えること。
    /// ドライバが変わっただけでセレクタは正しいので、ロケータの passedViaFallback ではなく
    /// driverFallback 注記になる(誤ったセレクタ更新提案を防ぐ)。
    func testType409FallsBackToTypeDriverReactively() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_email")]])
        primary.typeError = DriverError.badResponse(status: 409, body: "no first responder")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_email")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("409 からの typeDriver 切替による passed を期待したが \(outcome.status) だった")
            return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(log.entries, [
            "primary.snapshot",
            "primary.type(throws)",
            "typedriver.snapshot",
            "typedriver.type(ref:2)",
        ])
    }

    /// 409 以外のエラーは typeDriver へ切り替えず、そのまま失敗させること
    func testTypeNon409DoesNotUseTypeDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_email")]])
        primary.typeError = DriverError.badResponse(status: 500, body: "server error")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log,
                                       snapshotElements: [[element(ref: 2, id: "field_email")]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, preferTypeDriver: false)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("409 以外は失敗のままを期待したが \(outcome.status) だった")
            return
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("typedriver") },
                       "409 以外で typeDriver を照会してはいけない: \(log.entries)")
    }

    /// typeDriver が無い場合、409 はそのまま伝播して失敗させること
    func testType409WithoutTypeDriverPropagates() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element(ref: 1, id: "field_email")]])
        primary.typeError = DriverError.badResponse(status: 409, body: "no first responder")
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "type", locator: FlowLocator(id: "field_email"), text: "hi")

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("typeDriver 無しでの 409 失敗を期待したが \(outcome.status) だった")
            return
        }
    }

    // MARK: - swipeElementToElement

    /// 両要素の中心座標で drag が呼ばれること。duration 省略時は既定 1.5 秒が渡ること
    func testSwipeElementToElementDragsBetweenCenters() async throws {
        let log = CallLog()
        let from = framed(ref: 1, id: "handle_from", x: 0, y: 100, width: 20, height: 20)
        let to = framed(ref: 2, id: "handle_to", x: 200, y: 300, width: 40, height: 40)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[from, to]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "swipeElementToElement", locator: FlowLocator(id: "handle_from"),
                            endLocator: FlowLocator(id: "handle_to"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("swipeElementToElement の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(log.entries, ["primary.snapshot", "primary.drag"])
        XCTAssertEqual(primary.lastDragArgs?.fromX, 10)
        XCTAssertEqual(primary.lastDragArgs?.fromY, 110)
        XCTAssertEqual(primary.lastDragArgs?.toX, 220)
        XCTAssertEqual(primary.lastDragArgs?.toY, 320)
        XCTAssertEqual(primary.lastDragArgs?.durationSeconds, FlowStep.defaultSwipeDurationSeconds)
    }

    /// 終点が見つからないときは failed(メッセージに "end locator" を含む)
    func testSwipeElementToElementFailsWhenEndLocatorNotFound() async throws {
        let log = CallLog()
        let from = element(ref: 1, id: "handle_from")
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[from]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "swipeElementToElement", locator: FlowLocator(id: "handle_from"),
                            endLocator: FlowLocator(id: "handle_missing"))

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("終点未解決での失敗を期待したが \(outcome.status) だった"); return
        }
        XCTAssertTrue(msg.contains("end locator"), "失敗理由に end locator を含むこと: \(msg)")
    }

    /// in-app 相当(drag が 501)なら始点・終点の両方を typeDriver 側で取り直して drag すること
    func testSwipeElementToElementFallsBackToTypeDriverWhenEngineIncapable() async throws {
        let log = CallLog()
        let from = framed(ref: 1, id: "handle_from", x: 0, y: 100, width: 20, height: 20)
        let to = framed(ref: 2, id: "handle_to", x: 200, y: 300, width: 40, height: 40)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[from, to]])
        primary.dragError = DriverError.badResponse(status: 501, body: "in-app では drag が効きません")
        let typeFrom = framed(ref: 3, id: "handle_from", x: 0, y: 100, width: 20, height: 20)
        let typeTo = framed(ref: 4, id: "handle_to", x: 200, y: 300, width: 40, height: 40)
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [[typeFrom, typeTo]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)
        let step = FlowStep(action: "swipeElementToElement", locator: FlowLocator(id: "handle_from"),
                            endLocator: FlowLocator(id: "handle_to"))

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("501 からの typeDriver 切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertTrue(log.entries.contains("primary.drag(throws)"), "まず primary を試すこと: \(log.entries)")
        XCTAssertTrue(log.entries.contains("typedriver.drag"), "501 なら typeDriver へ回すこと: \(log.entries)")
        XCTAssertEqual(typeDriver.lastDragArgs?.fromX, 10)
        XCTAssertEqual(typeDriver.lastDragArgs?.toX, 220)
    }

    // MARK: - 探索直後に容器の外の ghost を掴む(Compose iOS の上流制約)

    /// 容器と交差しない子(ghost)を検出できること。**交差していれば ghost ではない**(通常の行)
    func testGhostDetectionFindsRowsReportedOutsideTheContainer() {
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 16, y: 300, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 16, y: 360, width: 370, height: 56, depth: 2)
        let ghost = framed(ref: 3, id: "row_30", x: 16, y: 783, width: 370, height: 56, depth: 2)
        let elements = [container, inside1, inside2, ghost]

        XCTAssertTrue(StepExecutor.isOutsideContainer(ghost, in: elements),
                      "容器の外に並ぶ行は ghost として検出すること")
        XCTAssertFalse(StepExecutor.isOutsideContainer(inside1, in: elements),
                       "容器と交差する行は通常の行(掴み直さない)")
    }

    /// **縁をまたぐ行は「掴み直し」の対象にしない**(2026-08-05 に試して撤回)。
    /// 掴み直しの対象を「容器に収まっていない要素」へ広げたら S0110 が **2/10 → 5/10 に悪化**した
    /// (縁で救済スワイプを撃つと数 pt 動き、その古い座標でタップして自傷する)。
    /// **またぎは探索ループの見切れ判定が担当する** —— あちらは掴む前に送るので座標が古くならない。
    /// 容器を返せること自体は必要(返せないと見切れ判定が画面基準に落ちる)
    func testStraddlingRowResolvesItsContainerButIsNotAGhost() {
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_31", x: 16, y: 249, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_32", x: 16, y: 305, width: 370, height: 56, depth: 2)
        // 実採取の値: 原点はクリップ前(206)・高さはクリップ後(43)= 中心 227.5 は容器の外
        let straddling = framed(ref: 3, id: "row_30", x: 16, y: 206, width: 370, height: 43, depth: 2)
        let elements = [container, inside1, inside2, straddling]

        XCTAssertEqual(StepExecutor.clippingContainer(of: straddling, in: elements), container.frame,
                       "またぐ行でも容器を特定できないと、見切れ判定が画面基準に落ちる")
        XCTAssertFalse(StepExecutor.isOutsideContainer(straddling, in: elements),
                       "またぐ行は ghost ではない(掴み直しの対象にすると自傷する)")
        XCTAssertTrue(StepExecutor.isClippedByViewport(straddling, screen: container.frame),
                      "容器基準なら見切れとして検出でき、探索ループがもう1回送る")
        XCTAssertFalse(StepExecutor.isClippedByViewport(straddling,
                                                        screen: FTRect(x: 0, y: 0, width: 402,
                                                                       height: 874)),
                       "画面基準では見えていることになってしまう = 旧実装が止まっていた理由")
    }

    /// **探索の直後に ghost を掴んだら掴み直す**。掴んだままタップすると容器の外を撃って
    /// 黙って飲まれる(値が変わらず、後段の検証だけが落ちて原因から遠い)
    func testTapAfterSearchReResolvesWhenItGrabsAGhostRow() async throws {
        let log = CallLog()
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 16, y: 300, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 16, y: 360, width: 370, height: 56, depth: 2)
        let target = framed(ref: 3, id: "row_30", x: 16, y: 420, width: 370, height: 56, depth: 2)
        let ghost = framed(ref: 4, id: "row_30", x: 16, y: 783, width: 370, height: 56, depth: 2)
        let settled = framed(ref: 5, id: "row_30", x: 16, y: 430, width: 370, height: 56, depth: 2)
        // **探索は2枚消費する**(見つけた周回 + 静止確認)。台本がズレると ghost が
        // 解決時点に届かず、この防波堤を素通りしたまま緑になる
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container, inside1, inside2, target],   // 探索: 容器の中で見つかる
            [container, inside1, inside2, target],   // 探索の静止確認
            [container, inside1, inside2, ghost],    // 探索直後の解決: 容器の外(ghost)
            [container, inside1, inside2, settled],  // 掴み直し: 容器の中
        ])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 2)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("掴み直して tap する想定だが \(outcome.status) だった"); return
        }
        XCTAssertTrue(log.entries.contains("primary.tap(ref:5)"),
                      "掴み直した容器内の行をタップすること: \(log.entries)")
        XCTAssertFalse(log.entries.contains("primary.tap(ref:4)"),
                       "ghost をタップしてはいけない: \(log.entries)")
        XCTAssertEqual(outcome.driverFallback?.contains("re-resolved"), true,
                       "掴み直したことを注記に残すこと: \(outcome.driverFallback ?? "nil") 呼び出し=\(log.entries)")
    }

    /// 掴み直しても ghost のままなら**注記を残す**(黙ってタップして飲まれるのが最悪)。
    /// **ghost の中心は画面内に置くこと**: 容器の外(= ghost)であることがこの経路の条件で、
    /// 中心まで画面外に出すと探索側のゲートが先に「届いていない」で落とし、この注記まで来ない
    func testTapAfterSearchNotesWhenTheGhostPersists() async throws {
        let log = CallLog()
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 16, y: 300, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 16, y: 360, width: 370, height: 56, depth: 2)
        let target = framed(ref: 3, id: "row_30", x: 16, y: 420, width: 370, height: 56, depth: 2)
        // 容器(230..692)の外・画面(高さ800)の中心内: 740..796 → 中心 768
        let ghost = framed(ref: 4, id: "row_30", x: 16, y: 740, width: 370, height: 56, depth: 2)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container, inside1, inside2, target],
            [container, inside1, inside2, ghost],    // 以降ずっと ghost(尽きたら最後を繰り返す)
        ])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 2)

        let outcome = await executor.execute(step)

        XCTAssertEqual(outcome.driverFallback?.contains("still reported outside"), true,
                       "救えなかったことを注記に残すこと: \(outcome.driverFallback ?? "nil") 呼び出し=\(log.entries)")
    }

    /// **救済で送った直後は、容器が次の1タッチを吸う**ので空打ちで肩代わりしてからタップする。
    /// 探索終端では以前からやっているが、救済経路には無かった —— 実測(S0110 を8並列):
    /// 救済が走った 18 件のうち 4 件が失敗、走らなかった 22 件は 0 件(p≈0.03)。
    /// 肩代わりを足すと **fix 0/48 対 base 8/48**(p≈0.006)。
    /// **iOS だけ**(releasesScrollTouch)。Android では 2pt のドラッグがクリックとして発火する。
    ///
    /// **台本は「救済スワイプまで到達する」形でなければ意味がない**(2026-08-05 に一度失敗した):
    /// 探索の中で解決できてしまうと `ghostSwipes` が 0 のままで、この経路自体を通らない
    func testRecoverySwipeIsFollowedByTheEmptyDrag() async throws {
        let log = CallLog()
        let container = framed(ref: 100, id: "list_rows", x: 16, y: 230, width: 370, height: 462,
                               depth: 1)
        let inside1 = framed(ref: 1, id: "row_28", x: 16, y: 300, width: 370, height: 56, depth: 2)
        let inside2 = framed(ref: 2, id: "row_29", x: 16, y: 360, width: 370, height: 56, depth: 2)
        let target = framed(ref: 3, id: "row_30", x: 16, y: 420, width: 370, height: 56, depth: 2)
        let ghost = framed(ref: 4, id: "row_30", x: 16, y: 783, width: 370, height: 56, depth: 2)
        let settled = framed(ref: 5, id: "row_30", x: 16, y: 430, width: 370, height: 56, depth: 2)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [container, inside1, inside2, target],   // 探索: 容器の中で見つかる
            [container, inside1, inside2, target],   // 探索の静止確認
            [container, inside1, inside2, ghost],    // 探索直後の解決: ghost
            [container, inside1, inside2, ghost],    // 掴み直し1回目: まだ ghost(= ここで救済が走る)
            [container, inside1, inside2, settled],  // 救済後: 容器の中
        ])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"),
                            direction: "up", maxSwipes: 2)

        _ = await executor.execute(step)

        // この台本では探索が attempt 0 で見つけるので**終端の空打ちは撃たれない** ——
        // 横のドラッグが出るなら、それは救済の後の肩代わりだけ
        let vertical = primary.dragCalls.filter { $0.fromY != $0.toY }
        XCTAssertFalse(vertical.isEmpty, "救済は距離ぶんの縦ドラッグで戻す: \(primary.dragCalls)")
        // 空打ちは**横へ抜ける**(縦だと容器がスクロールとして消費する。emptyDragEndX 参照)
        let horizontal = primary.dragCalls.filter { $0.fromY == $0.toY }
        XCTAssertFalse(horizontal.isEmpty,
                       "救済の後に容器の1タッチを肩代わりしていない: \(primary.dragCalls)")
    }

    // MARK: - マップ系ジェスチャ(pinchOut/pinchIn・doubleTap・swipeBy)

    /// 対象未指定のピンチは画面全体(frame = screen・identifier なし)で撃たれること
    func testPinchOutWithoutLocatorTargetsTheWholeScreen() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)

        let outcome = await executor.execute(FlowStep(action: "pinchOut", scale: 2.0))

        guard case .passed = outcome.status else {
            XCTFail("pinchOut の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(primary.lastPinch?.frame, FTRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertNil(primary.lastPinch?.identifier)
        XCTAssertEqual(primary.lastPinch?.scale, 2.0)
        XCTAssertEqual(primary.lastPinch?.durationSeconds, FlowStep.defaultPinchDurationSeconds)
    }

    /// セレクタ付きは**要素の frame と identifier の両方**が渡ること
    /// (Android は frame の中心で合成し、XCUITest は identifier で要素を引くため。
    /// 片方でも落ちると、対象を指定したのに画面中心がピンチされる)
    func testPinchWithLocatorPassesFrameAndIdentifier() async throws {
        let log = CallLog()
        let map = framed(ref: 1, id: "map", x: 10, y: 40, width: 300, height: 200)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[map]])
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "pinchIn", locator: FlowLocator(id: "map"), scale: 0.5)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("pinchIn の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(primary.lastPinch?.frame, FTRect(x: 10, y: 40, width: 300, height: 200))
        XCTAssertEqual(primary.lastPinch?.identifier, "map")
        XCTAssertEqual(primary.lastPinch?.scale, 0.5)
    }

    /// 向きと倍率が食い違ったら**撃たずに失敗**(撃つと「pinchOut と書いたのに縮小」が緑になる)
    func testPinchRejectsScaleThatContradictsDirection() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)

        let outOutcome = await executor.execute(FlowStep(action: "pinchOut", scale: 0.5))
        let inOutcome = await executor.execute(FlowStep(action: "pinchIn", scale: 2.0))

        guard case .failed(let outMsg) = outOutcome.status else {
            XCTFail("pinchOut(scale<1) は failed を期待したが \(outOutcome.status) だった"); return
        }
        guard case .failed = inOutcome.status else {
            XCTFail("pinchIn(scale>1) は failed を期待したが \(inOutcome.status) だった"); return
        }
        XCTAssertTrue(outMsg.contains("scale > 1"), "何が期待値かを述べること: \(outMsg)")
        XCTAssertFalse(log.entries.contains("primary.pinch"), "撃たないこと: \(log.entries)")
    }

    /// in-app 相当(501)なら typeDriver へ回すこと。**座標・identifier はそのまま**渡る
    /// (ref と違いブリッジ間で意味が変わらないので取り直しが要らない)
    func testPinchFallsBackToTypeDriverWhenEngineIncapable() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        primary.pinchError = DriverError.badResponse(status: 501, body: "in-app では pinch が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver)

        let outcome = await executor.execute(FlowStep(action: "pinchOut", scale: 3.0))

        guard case .passed = outcome.status else {
            XCTFail("501 からの切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertEqual(typeDriver.lastPinch?.scale, 3.0)
    }

    /// ダブルタップは要素の中心座標で撃たれること
    func testDoubleTapUsesElementCenter() async throws {
        let log = CallLog()
        let map = framed(ref: 1, id: "map", x: 100, y: 200, width: 40, height: 60)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[map]])
        let executor = StepExecutor(driver: primary)

        let outcome = await executor.execute(FlowStep(action: "doubleTap",
                                                      locator: FlowLocator(id: "map")))

        guard case .passed = outcome.status else {
            XCTFail("doubleTap の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(primary.lastDoubleTap?.x, 120)
        XCTAssertEqual(primary.lastDoubleTap?.y, 230)
    }

    /// swipeBy は**斜め**(dx/dy とも非 0)の経路を、対象領域の中心を挟んで対称に作ること
    func testSwipeByBuildsDiagonalPathAroundTheCenter() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        // 画面 400x800 の中心 (200, 400) から、幅の -0.5・高さの -0.25 ぶん指を動かす
        let step = FlowStep(action: "swipeBy", dxRatio: -0.5, dyRatio: -0.25)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("swipeBy の passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(primary.lastDragArgs?.fromX, 300)
        XCTAssertEqual(primary.lastDragArgs?.fromY, 500)
        XCTAssertEqual(primary.lastDragArgs?.toX, 100)
        XCTAssertEqual(primary.lastDragArgs?.toY, 300)
        XCTAssertEqual(primary.lastDragArgs?.durationSeconds, FlowStep.defaultSwipeDurationSeconds)
    }

    /// 移動量が小さすぎて指が動かないときは**成功にしない**(比率の書き間違いに気付けなくなる)
    func testSwipeByFailsWhenTheOffsetIsTooSmallToMove() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)

        let outcome = await executor.execute(FlowStep(action: "swipeBy",
                                                      dxRatio: 0.001, dyRatio: 0))

        guard case .failed = outcome.status else {
            XCTFail("動かない swipeBy は failed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertNil(primary.lastDragArgs, "撃たないこと")
    }

    // MARK: - スクロール探索終端の空打ち可否(pointIsTakenByFrontElement)

    func framed(ref: Int, id: String, x: Double, y: Double,
                        width: Double, height: Double, depth: Int = 0) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: width, height: height), depth: depth)
    }

    /// 対象の中心が**後ろに並ぶ(=手前寄りの)要素**に入るなら空打ちしない。
    /// 実害: タブバーの帯に出た要素へ空打ちしてホームタブが反応した(docs/verification.md)
    func testPointTakenByFrontElement() {
        let target = framed(ref: 1, id: "txt", x: 16, y: 815, width: 111, height: 20)
        let tabBar = framed(ref: 2, id: "tab_home", x: 0, y: 778, width: 134, height: 62)
        XCTAssertTrue(StepExecutor.pointIsTakenByFrontElement(
            x: 71, y: 825, of: target, in: [target, tabBar]))

        // 手前に何も無ければ打ってよい
        let apart = framed(ref: 3, id: "other", x: 300, y: 0, width: 50, height: 50)
        XCTAssertFalse(StepExecutor.pointIsTakenByFrontElement(
            x: 71, y: 825, of: target, in: [target, apart]))

        // 対象より**前**(奥)にある要素は数えない(pre-order で後 = 手前寄りの規約)
        XCTAssertFalse(StepExecutor.pointIsTakenByFrontElement(
            x: 71, y: 825, of: target, in: [tabBar, target]))

        // 対象自身の子孫(内側の Text 等)は同じ見た目の一部なので数えない
        let child = framed(ref: 4, id: "txt_inner", x: 20, y: 818, width: 60, height: 14, depth: 1)
        XCTAssertFalse(StepExecutor.pointIsTakenByFrontElement(
            x: 71, y: 825, of: target, in: [target, child]))
    }

    /// 空打ちドラッグは in-app が未対応(501)なら typeDriver(XCUITest)へ回すこと。
    /// 回さないと Compose のスクロール容器がタッチを1回吸ったままになり直後の tap が空振りする
    func testEmptyDragFallsBackToTypeDriverWhenEngineIncapable() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_40", x: 16, y: 300, width: 370, height: 56)
        // **1周目は静止確認で2枚撮る**(プログラム的スクロールの取りこぼし対策)。
        // 空の2枚で静止 → スワイプ → 3枚目で発見、の並びにする
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], [row]])
        primary.dragError = DriverError.badResponse(status: 501, body: "未対応")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    releasesScrollTouch: true)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("スワイプ後の snapshot で見つかるので pass のはず"); return
        }
        XCTAssertTrue(log.entries.contains("primary.drag(throws)"), "まず primary を試すこと: \(log.entries)")
        XCTAssertTrue(log.entries.contains("typedriver.drag"),
                      "501 なら typeDriver へ回すこと: \(log.entries)")
    }

    /// uiFramework=="uikit"(RN 含む)は探索終端の空打ちをスキップすること。
    /// RN は Pressable の pressRetentionOffset(既定20pt)内に空打ちの終点が収まり onPress が
    /// 成立してしまい、`scrollTo` しただけで行が選択される(2026-08-08 E2E-RN S0100 実測)。
    /// shouldEmptyDrag のコメント参照
    func testEmptyDragSkippedWhenUIFrameworkIsUIKit() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_40", x: 16, y: 300, width: 370, height: 56)
        // 1周目は静止確認で2枚撮ってからスワイプで見つける(既存 testEmptyDragFallsBack... と同じ台本)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], [row]])
        let executor = StepExecutor(driver: primary, releasesScrollTouch: true, uiFramework: "uikit")
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("スワイプ後の snapshot で見つかるので pass のはず"); return
        }
        XCTAssertTrue(primary.dragCalls.isEmpty,
                      "uiFramework=uikit では終端の空打ちを撃たないこと: \(primary.dragCalls)")
    }

    /// uiFramework が "compose"、または判定できず nil(不明)のときは**従来どおり**空打ちを撃つこと。
    /// nil を skip 側へ倒すと、実機や AppBundleInspector が判定失敗した経路まで一括で挙動が変わる
    func testEmptyDragStillFiresForComposeAndUnknownFramework() async throws {
        let frameworks: [String?] = [nil, "compose"]
        for framework in frameworks {
            let log = CallLog()
            let row = framed(ref: 1, id: "row_40", x: 16, y: 300, width: 370, height: 56)
            let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [], [row]])
            let executor = StepExecutor(driver: primary, releasesScrollTouch: true, uiFramework: framework)
            let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2)

            guard case .passed = await executor.execute(step).status else {
                XCTFail("スワイプ後の snapshot で見つかるので pass のはず (\(String(describing: framework)))")
                continue
            }
            XCTAssertFalse(primary.dragCalls.isEmpty,
                           "uiFramework=\(String(describing: framework)) では空打ちを撃つこと: \(primary.dragCalls)")
        }
    }

    /// drag のラッチは swipe に波及しないこと。in-app は drag だけ不可・swipe は
    /// contentOffset 経路で効くため、共有すると全 swipe が XCUITest 実スワイプ化して flake る
    func testDragFallbackDoesNotLatchSwipeToTypeDriver() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_40", x: 16, y: 300, width: 370, height: 56)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[], [row]])
        primary.dragError = DriverError.badResponse(status: 501, body: "未対応")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log)
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver,
                                    releasesScrollTouch: true)
        _ = await executor.execute(
            FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), maxSwipes: 2))
        log.entries.removeAll()

        _ = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        XCTAssertEqual(log.entries.first, "primary.swipe",
                       "drag の 501 で swipe まで typeDriver へ回してはいけない: \(log.entries)")
        XCTAssertTrue(log.entries.dropFirst().allSatisfy { $0 == "primary.snapshot" },
                      "swipe 後は静止待ちの snapshot だけが続くはず: \(log.entries)")
    }

    // MARK: - scrollToEdge の端判定(静止署名)

    /// 静止画面なのにラベルだけが取得のたびに振れても、端に着いたと判定して止まること。
    /// 実機(E2E-iOS/ios-xcuitest・2026-07-31)の再現: SwiftUI List では画面外の再利用セルが
    /// 別の行のラベルを名乗り A↔B で交互に振れる(frame は 1pt も動かない)。署名にラベルを
    /// 入れていた頃はこれで永久に収束せず、scrollToTop が毎回 maxSwipes 上限まで回って 44〜55s
    /// かかっていた。**署名からラベルを外すと落ちる**ので、この防波堤を消さないこと
    func testScrollToEdgeStopsWhenOnlyLabelsFlapBetweenSnapshots() async throws {
        let log = CallLog()
        // frame は全スナップショットで同一。ラベルだけが1要素ぶん交互に入れ替わる
        func frame(_ label: String) -> [ElementInfo] {
            [ElementInfo(ref: 1, type: "cell", identifier: "row_01", label: label, value: nil,
                         placeholder: nil, enabled: true,
                         frame: FTRect(x: 16, y: 100, width: 370, height: 56), depth: 0)]
        }
        // 上限まで回った場合でも尽きない長さを与える(尽きると最後が繰り返され交互でなくなる)
        let flapping = (0..<200).map { frame($0.isMultiple(of: 2) ? "行 12" : "行 21") }
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: flapping)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 20)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { XCTFail("scrollToEdge は pass のはず"); return }
        XCTAssertNil(outcome.driverFallback,
                     "端に着いたと判定できていれば上限打ち切りの注記は付かない: \(outcome.driverFallback ?? "-")")
        let swipes = log.entries.filter { $0 == "primary.swipe" }.count
        XCTAssertLessThanOrEqual(swipes, 3,
                                 "連続2回不変で端と判定して止まるはず(実際は \(swipes) 回スワイプ)")
    }

    /// 端に着く前(スクロールで frame が動いている間)は止まらないこと。
    /// 上の防波堤を「常に即 break」で通してしまう実装を落とす対の検証
    func testScrollToEdgeKeepsSwipingWhileFramesStillMove() async throws {
        let log = CallLog()
        func frame(_ y: Double) -> [ElementInfo] {
            [ElementInfo(ref: 1, type: "cell", identifier: "row_01", label: "行 01", value: nil,
                         placeholder: nil, enabled: true,
                         frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 0)]
        }
        // 毎回 y が動き続ける = 端に着かない。上限まで回って注記が付く
        let moving = (0..<200).map { frame(Double($0) * 10) }
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: moving)
        let executor = StepExecutor(driver: primary)
        let step = FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3)

        let outcome = await executor.execute(step)

        XCTAssertEqual(log.entries.filter { $0 == "primary.swipe" }.count, 3,
                       "動き続ける間は上限まで送ること: \(log.entries)")
        let note = outcome.driverFallback ?? ""
        XCTAssertTrue(note.contains("stopped at the limit of 3 (may not have reached the edge yet)"),
                      "端に着いていないことを注記すること: \(note)")
        // 動き続ける画面なので整定の打ち切りも同時に申告される(両方出るのが正しい)
        XCTAssertTrue(note.contains("the screen did not settle (poll limit)"),
                      "静止を確認できなかったことも注記すること: \(note)")
    }

    // MARK: - scroll/scrollToEdge/flick(scrollFrame:) の fail-fast

    /// 明示 scrollFrame が解決できないなら、`scroll` は全画面スワイプへ黙って退化せず
    /// 1本も振らずに失敗する(A1 と同じ理由: 無関係な要素を誤発火させ得るため)
    func testScrollFailsWithoutSwipingWhenScrollFrameDoesNotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scroll", direction: "up", maxSwipes: 3)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else { XCTFail("失敗のはず: \(outcome.status)"); return }
        XCTAssertTrue(msg.contains("the swipe was not sent"), msg)
        XCTAssertFalse(log.entries.contains { $0.contains(".swipe") },
                       "scrollFrame が解決できないなら1本も振らないこと")
    }

    func testScrollToEdgeFailsWithoutSwipingWhenScrollFrameDoesNotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 3)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else { XCTFail("失敗のはず: \(outcome.status)"); return }
        XCTAssertTrue(msg.contains("the swipe was not sent"), msg)
        XCTAssertFalse(log.entries.contains { $0.contains(".swipe") },
                       "scrollFrame が解決できないなら1本も振らないこと")
    }

    func testFlickFailsWithoutSwipingWhenScrollFrameDoesNotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "flick", direction: "topToBottom", maxSwipes: 1)
        step.scrollFrame = FlowLocator(id: "no_such_container")

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else { XCTFail("失敗のはず: \(outcome.status)"); return }
        XCTAssertTrue(msg.contains("the flick was not sent"), msg)
        XCTAssertFalse(log.entries.contains { $0.contains(".swipe") || $0.contains(".drag") },
                       "scrollFrame が解決できないなら1本も振らないこと")
    }

    // MARK: - scrollFrameRect(MCP の ref 経由スクロール容器。2026-08-10)
    //
    // id の重複・欠落でセレクタが書けない容器のため、MCPServer が ref から起こした矩形を
    // そのまま渡す経路。DSL は使わない(scrollFrame は文字列のまま)。

    /// **rect は locator を経ずにそのまま容器になる**
    func testScrollContainerReturnsScrollFrameRectDirectly() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"))
        let rect = FTRect(x: 10, y: 20, width: 300, height: 400)
        step.scrollFrameRect = rect
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [], truncatedCount: 0)
        XCTAssertEqual(executor.scrollContainer(step: step, in: snapshot, vertical: true), rect)
    }

    /// **rect があれば scrollFrame(セレクタ)の解決失敗を無視する** —— rect は「常に解決済み」
    /// 扱いなので、id が重複・欠落した容器を指すための逃げ道が fail-fast に巻き込まれない
    func testScrollContainerPrefersRectEvenWhenTheLocatorCannotResolve() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"))
        step.scrollFrame = FlowLocator(id: "no_such_container")
        let rect = FTRect(x: 10, y: 20, width: 300, height: 400)
        step.scrollFrameRect = rect
        let snapshot = SnapshotResponse(sessionBundleID: nil,
                                        screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                        elements: [], truncatedCount: 0)
        XCTAssertEqual(executor.scrollContainer(step: step, in: snapshot, vertical: true), rect)
    }

    /// rect だけを指定した(scrollFrame セレクタ無しの)`scrollTo` は、対象が最初から画面に
    /// 居るとき fail-fast にも掛からず素直に成功すること(rect 経路の配線確認)
    func testScrollToSucceedsWithScrollFrameRectAndNoLocator() async throws {
        let log = CallLog()
        let row = framed(ref: 1, id: "row_40", x: 16, y: 100, width: 370, height: 40)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[row]])
        let executor = StepExecutor(driver: primary)
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), direction: "up")
        step.scrollFrameRect = FTRect(x: 0, y: 0, width: 400, height: 800)

        guard case .passed = await executor.execute(step).status else {
            XCTFail("画面に既に居るので見つかるはず"); return
        }
    }

}
