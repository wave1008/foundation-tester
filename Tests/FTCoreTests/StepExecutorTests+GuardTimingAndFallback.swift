// StepExecutorTests+GuardTimingAndFallback.swift
// StepExecutorTests の select/tap 周辺注記・occlusion-guard の時間管理(first-frame gate・
// guardCost 延長・VisibilityVerdictMemo)・exists のフォールバック間引きを分割
import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import FTCore

extension StepExecutorTests {

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
        // 覆いが消えれば**絵が変わる**ので、周回ごとに別のバイト列を返す(同じ絵なら控えが
        // 同じ答えを返すのが正しい = VisibilityVerdictMemo)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG, Self.nearBlankPNG])
        let delegate = SequenceVisibilityDelegate([false, true])   // 覆い → 可視
        // このテストが測るのは poll の意味論(覆い→可視で pass)なので OCR は通さない ——
        // 通すと合否が Vision の所要(並列テストの負荷で動く)に依存する
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, isAndroid: false)
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

    /// launch 直後(noteAppLaunched)に crop が全画素同一(launch storyboard 相当)なら、
    /// deadline を一度だけ延ばして待ち直す。timeout:0 でも「初回照会は必ず1回」+
    /// 「延長は1回だけ」で2周目には赤になる(=すぐ終わる。実時間のスリープは挟まない)
    func testFirstFrameGateExtendsDeadlineOnceWhenBlankAfterLaunch() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, isAndroid: false)
        executor.noteAppLaunched()   // launch 系コマンド直後と同じ arm
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("延長しても覆われ続ければ最終的に失敗するはず: \(outcome.status)"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "occlusion 失敗を返すこと: \(msg)")
        XCTAssertEqual(delegate.visibleCalls, 1, "同じ絵(バイト同一)の2周目は控えで済むはず(VisibilityVerdictMemo)")
        XCTAssertTrue(outcome.notes.contains(.firstFramePending),
                      "延長した回に first-frame-pending が付くはず: \(outcome.notes)")
        XCTAssertTrue(outcome.notes.contains(.firstFrameTimeout),
                      "延長しても赤になった回に first-frame-timeout が付くはず: \(outcome.notes)")
    }

    /// launch storyboard は厳密な一様色ではない(実測 min=253 / max=255)。量子化1段階未満の揺らぎは
    /// 「何も描かれていない」と読む —— 厳密 0 を要求すると本番の crop で猶予が一度も効かない
    func testFirstFrameGateTreatsSubLevelNoiseAsBlank() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.nearBlankPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, isAndroid: false)
        executor.noteAppLaunched()
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else { XCTFail("覆われ続けたら失敗するはず"); return }
        XCTAssertEqual(delegate.visibleCalls, 1, "同じ絵の2周目は控えで済むはず")
        XCTAssertTrue(outcome.notes.contains(.firstFramePending), "\(outcome.notes)")
    }

    /// 上限はリテラルで固定する(他のテストが差し替え口で値を明示すると既定を1度も通らない)
    func testFirstFrameBlankCeilingIsOneLuminanceLevel() {
        XCTAssertEqual(StepExecutor.firstFrameBlankStdDevCeiling, 1.0)
    }

    // MARK: - FM 判定の控え(VisibilityVerdictMemo)

    /// select→textIs の形: 同じスクショ・同じ要素・同じ期待文字列なら FM は1回
    func testVisibilityVerdictIsMemoizedForAnIdenticalScreenshot() async throws {
        let log = CallLog()
        let element = textElement(id: "msg", label: "こんにちは")
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element], [element]],
                                    screenshots: [Self.blankPNG])   // 以後も同じバイト列
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        _ = await executor.execute(step)
        _ = await executor.execute(step)

        XCTAssertEqual(delegate.visibleCalls, 1, "同じ入力に FM を2度訊いている")
        XCTAssertEqual(executor.visibilityVerdictMemo.count, 1)
    }

    /// 画面がバイト単位で変われば控えは捨てられ、FM に訊き直す
    func testVisibilityVerdictMemoIsDroppedWhenTheScreenshotChanges() async throws {
        let log = CallLog()
        let element = textElement(id: "msg", label: "こんにちは")
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element], [element]],
                                    screenshots: [Self.blankPNG, Self.nearBlankPNG])
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        _ = await executor.execute(step)
        executor.invalidateScreenshotCache()   // 次のステップで撮り直させる(200ms のキャッシュを跨がない)
        _ = await executor.execute(step)

        XCTAssertEqual(delegate.visibleCalls, 2, "画面が変わったのに控えを返している")
    }

    /// 期待文字列が違えば別の鍵(同じ要素でも textIs の期待値ごとに訊く)
    func testVisibilityVerdictMemoIsKeyedByExpectedText() {
        var memo = VisibilityVerdictMemo()
        let frame = FTRect(x: 1, y: 2, width: 30, height: 10), screen = FTRect(x: 0, y: 0, width: 100, height: 200)
        memo.store(imageHash: 7, key: VisibilityVerdictMemo.key(frame: frame, screen: screen, expectedText: "a"),
                   verdict: (true, "fullyVisible", "t", "a"))
        XCTAssertNotNil(memo.lookup(imageHash: 7, key: VisibilityVerdictMemo.key(frame: frame, screen: screen, expectedText: "a")))
        XCTAssertNil(memo.lookup(imageHash: 7, key: VisibilityVerdictMemo.key(frame: frame, screen: screen, expectedText: "b")))
        XCTAssertNil(memo.lookup(imageHash: 8, key: VisibilityVerdictMemo.key(frame: frame, screen: screen, expectedText: "a")),
                     "別のスクショに控えを返している")
        memo.store(imageHash: 8, key: VisibilityVerdictMemo.key(frame: frame, screen: screen, expectedText: "b"),
                   verdict: (false, "covered", "t", ""))
        XCTAssertEqual(memo.count, 1, "スクショが変わったのに古い控えが残っている")
    }

    /// 答え無し(nil)は控えない —— 次のステップは必ず訊き直す
    func testVisibilityVerdictNilIsNotMemoized() async throws {
        let log = CallLog()
        let element = textElement(id: "msg", label: "こんにちは")
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[element], [element]],
                                    screenshots: [Self.blankPNG])
        let delegate = FakeVisibilityDelegate(visible: true)
        delegate.answersNothing = true
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let first = await executor.execute(step)
        delegate.answersNothing = false
        let second = await executor.execute(step)

        XCTAssertTrue(first.notes.contains(.visibilityGuardSkipped))
        XCTAssertEqual(delegate.visibleCalls, 2, "nil を控えて訊き直していない")
        XCTAssertFalse(second.notes.contains(.visibilityGuardSkipped))
    }

    /// Tier-1 のインク足切りを通らない構成(occlusionInkThreshold = 0)でも門は効く。
    /// **足切り側で測った stdDev を使い回すだけの実装だと、この経路では未計算のまま
    /// 「一様色ではない」と読まれ、猶予が静かに消える**(幾何が疑い有りの回も同じ経路)
    func testFirstFrameGateExtendsEvenWhenInkFilterIsDisabled() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, isAndroid: false)
        executor.noteAppLaunched()
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else { XCTFail("覆われ続けたら失敗するはず"); return }
        XCTAssertEqual(delegate.visibleCalls, 1, "同じ絵の2周目は控えで済むはず")
        XCTAssertTrue(outcome.notes.contains(.firstFramePending), "\(outcome.notes)")
    }

    /// 門は**可視の判定でも消費する**(描画が済んでいるなら猶予は要らない)。launch 直後の
    /// 最初のアサーションが通ったあと、後段の本物の occlusion で猶予が復活してはいけない
    func testFirstFrameGateIsConsumedByAVisibleVerdict() async throws {
        let log = CallLog()
        // 2本目は**別の絵**(同じ絵なら控えが同じ答えを返すのが正しい = VisibilityVerdictMemo)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")],
                                                       [textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG, Self.nearBlankPNG])
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, isAndroid: false)
        executor.noteAppLaunched()
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        _ = await executor.execute(step)   // 可視で通る = ここで門を消費する
        executor.invalidateScreenshotCache()
        delegate.visible = false
        let callsBefore = delegate.visibleCalls
        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else { XCTFail("2本目は覆われて失敗するはず"); return }
        XCTAssertEqual(delegate.visibleCalls - callsBefore, 1, "門は消費済みなので延長しないはず")
        XCTAssertFalse(outcome.notes.contains(.firstFramePending), "\(outcome.notes)")
    }

    /// 門が armed でなければ(noteAppLaunched を呼んでいない)、crop が全画素同一でも延長しない
    /// (通常どおり1周で timeout を迎える)
    func testFirstFrameGateDoesNotExtendWithoutLaunch() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, isAndroid: false)
        // executor.noteAppLaunched() は呼ばない = 門は閉じたまま
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else { XCTFail("覆われ続けたら失敗するはず"); return }
        XCTAssertEqual(delegate.visibleCalls, 1, "門が閉じていれば延長せず1周で終わるはず")
        XCTAssertFalse(outcome.notes.contains(.firstFramePending), "門が閉じていれば延長注記は付かない")
        XCTAssertFalse(outcome.notes.contains(.firstFrameTimeout), "門が閉じていれば延長注記は付かない")
    }

    /// 門は armed でも、crop に明瞭なインクがあれば(=launch storyboard ではない)Tier-1 事前
    /// フィルタで FM 自体を呼ばずに pass する ——「全画素同一」でなければ延長の出番は無い
    func testFirstFrameGateDoesNotExtendWhenCropHasInk() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.inkedPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate, isAndroid: false)
        executor.noteAppLaunched()
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("明瞭なインクがあれば Tier-1 で素通り pass するはず: \(outcome.status)"); return
        }
        XCTAssertEqual(delegate.visibleCalls, 0, "インクが明瞭なら FM を呼ばずに pass するはず")
        XCTAssertFalse(outcome.notes.contains(.firstFramePending))
        XCTAssertFalse(outcome.notes.contains(.firstFrameTimeout))
    }

    /// textEquals 側(executeAssertTextComparison)も exists と同じ猶予を持つ
    func testFirstFrameGateExtendsDeadlineOnceForTextEqualsToo() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, isAndroid: false)
        executor.noteAppLaunched()
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "こんにちは", timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("延長しても覆われ続ければ最終的に失敗するはず: \(outcome.status)"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), "occlusion 失敗を返すこと: \(msg)")
        XCTAssertEqual(delegate.visibleCalls, 1, "同じ絵(バイト同一)の2周目は控えで済むはず(VisibilityVerdictMemo)")
        XCTAssertTrue(outcome.notes.contains(.firstFramePending))
        XCTAssertTrue(outcome.notes.contains(.firstFrameTimeout))
    }

    /// 門は launch につき一度きり: 1本目のアサーションで消費(+延長)した観測が、
    /// 門が既に閉じている2本目の無関係なアサーションへ持ち越されないこと
    /// (`firstFrameBlankObserved` は execute(_:) の入口で毎ステップ false に戻る)
    func testFirstFrameGateObservationDoesNotLeakAcrossSteps() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは"),
                                                        textElement(id: "msg2", label: "world")]],
                                    screenshots: [Self.blankPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, isAndroid: false)
        executor.noteAppLaunched()
        let step1 = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                             timeout: 0, occlusionGuard: true)
        let step2 = FlowStep(assert: "exists", locator: FlowLocator(id: "msg2"),
                             timeout: 0, occlusionGuard: true)

        _ = await executor.execute(step1)   // 門を消費し、延長も使い切る
        let callsBeforeStep2 = delegate.visibleCalls
        let outcome2 = await executor.execute(step2)

        guard case .failed = outcome2.status else { XCTFail("2本目も覆われ続けるので失敗するはず"); return }
        XCTAssertEqual(delegate.visibleCalls - callsBeforeStep2, 1,
                       "門は既に閉じているので2本目は延長せず1周だけ照合するはず")
        XCTAssertFalse(outcome2.notes.contains(.firstFramePending),
                       "1本目の観測が2本目へ漏れて延長してはいけない: \(outcome2.notes)")
        XCTAssertFalse(outcome2.notes.contains(.firstFrameTimeout), "\(outcome2.notes)")
    }

    // MARK: - [F22] ガード自身の所要による deadline 延長(guardCostExtended)

    /// ガード自身の所要(FM の直列化待ち+推論)だけでステップの待ち予算を使い切り、
    /// 1回もポーリングできないまま反転が確定するのを防ぐ。1番目の評価が deadline を跨いでいたら
    /// 一度だけ延ばして撮り直し、2番目の評価で可視と分かれば通る
    /// (2026-09-15 実測の再現: guardMs 6.3s > 既定 timeout 5s で1フレームだけの古い描画が
    /// 反転を確定させ、`select→textIs` の形で誤った赤になった)
    func testGuardCostExtendsDeadlineOnceAndPassesOnRetake() async throws {
        let log = CallLog()
        // 撮り直しごとに**違う絵**を返す(同じ絵は VisibilityVerdictMemo が前回の verdict を再利用し
        // FM を呼ばない = 描画が更新された実機の形にならない)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: (0..<8).map { Data("frame-\($0)".utf8) })
        // 1回の評価が 150ms かかる。ステップの timeout(50ms)を優に超えるので、
        // 1回目の評価だけで deadline を跨ぐ
        let delegate = SlowSequenceVisibilityDelegate(results: [false, true], delayMs: 150)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, occlusionOCRMode: .off, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0.05, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("撮り直しで可視と分かったので通るはず: \(outcome.status)"); return
        }
        XCTAssertEqual(delegate.calls, 2, "1回目の反転を撮り直して2回目で確かめているはず")
        XCTAssertTrue(outcome.notes.contains(.guardRetaken), "\(outcome.notes)")
    }

    /// 撮り直しても覆われたままなら本物の occlusion。延長は1回だけ(2回で打ち切る)で、
    /// 通らなかった回には `guardRetaken` は立たない(注記は撮り直しが通った事実の記録)
    func testGuardCostExtensionIsUsedOnceThenFailsNormally() async throws {
        let log = CallLog()
        // 撮り直しごとに**違う絵**を返す(同じ絵は VisibilityVerdictMemo が前回の verdict を再利用し
        // FM を呼ばない = 描画が更新された実機の形にならない)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: (0..<8).map { Data("frame-\($0)".utf8) })
        let delegate = SlowSequenceVisibilityDelegate(results: [false, false], delayMs: 150)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, occlusionOCRMode: .off, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0.05, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed(let msg) = outcome.status else {
            XCTFail("撮り直しても覆われ続ければ失敗するはず: \(outcome.status)"); return
        }
        XCTAssertTrue(msg.contains("occlusion"), msg)
        XCTAssertEqual(delegate.calls, 2, "延長は1回だけなので2回で打ち切るはず")
        XCTAssertFalse(outcome.notes.contains(.guardRetaken),
                       "撮り直しても通らなければ注記は立たないはず: \(outcome.notes)")
    }

    /// timeout==0(初回1回だけの意味)はガード所要による延長の対象外
    func testGuardCostExtensionDoesNotApplyWhenTimeoutIsZero() async throws {
        let log = CallLog()
        // 撮り直しごとに**違う絵**を返す(同じ絵は VisibilityVerdictMemo が前回の verdict を再利用し
        // FM を呼ばない = 描画が更新された実機の形にならない)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: (0..<8).map { Data("frame-\($0)".utf8) })
        let delegate = SlowSequenceVisibilityDelegate(results: [false, true], delayMs: 50)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, occlusionOCRMode: .off, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .failed = outcome.status else {
            XCTFail("timeout==0 は延長せず初回1回だけで失敗するはず: \(outcome.status)"); return
        }
        XCTAssertEqual(delegate.calls, 1, "timeout==0 は延長しないので1回で終わるはず")
        XCTAssertFalse(outcome.notes.contains(.guardRetaken), "\(outcome.notes)")
    }

    /// textEquals 側(executeAssertTextComparison)も exists と同じ延長を持つ
    func testGuardCostExtendsDeadlineOnceForTextEqualsToo() async throws {
        let log = CallLog()
        // 撮り直しごとに**違う絵**を返す(同じ絵は VisibilityVerdictMemo が前回の verdict を再利用し
        // FM を呼ばない = 描画が更新された実機の形にならない)
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: (0..<8).map { Data("frame-\($0)".utf8) })
        let delegate = SlowSequenceVisibilityDelegate(results: [false, true], delayMs: 150)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, occlusionOCRMode: .off, isAndroid: false)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "msg"),
                            expected: "こんにちは", timeout: 0.05, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("撮り直しで可視と分かったので通るはず: \(outcome.status)"); return
        }
        XCTAssertEqual(delegate.calls, 2)
        XCTAssertTrue(outcome.notes.contains(.guardRetaken), "\(outcome.notes)")
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
