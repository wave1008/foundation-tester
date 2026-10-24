// occlusion-guard: FM が判定を返さないとき(実呼び出しの失敗・陽性対照の注入)の代替判定
// (OCROnlyVisibility)を実際の StepExecutor.execute 経由で駆動する。ここで確定的に再現できるのは
// 「読みが無い(OCR が off・近道が撃たれていない)なら判定しない」側だけ(読みのある判定は Vision の
// 実読みが要り、本番の読みの経路には差し替え口が無いため、純関数テストは
// Tests/FTCoreTests/OCROnlyVisibilityTests.swift、配線は OCROnlyVisibilityWiringTests のソース走査で固定する)。
import XCTest
@testable import FTCore

extension StepExecutorTests {

    /// FM に実際に訊いたが答えが無く(NoVerdictVisibilityDelegate)、OCR の読みも無い(off)。
    /// **低インク(Self.blankPNG)でも不可視とは言わない** —— 読んでいないのにインク量だけで判定していた
    /// (E2E のコンパイル前のステップで実際に出た)。FM に訊いた回なので visibilityGuardSkipped は立つ
    func testNoVerdictFromFMWithoutOCRReadingDoesNotJudgeByInkAlone() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        let delegate = NoVerdictVisibilityDelegate()
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("実際は \(outcome.status)"); return
        }
        
        XCTAssertTrue(outcome.notes.contains(.visibilityGuardSkipped), "FM に訊いた回なので立つはず: \(outcome.notes)")
        XCTAssertEqual(delegate.visibleCalls, 1)
    }

    /// インク閾値 0(占ゲート無効。Tier-1 と同じ「0 なら疑わない」向き)では、ink がどれだけ
    /// あっても notVisible にはならず判定不能のまま。FM には訊いているので visibilityGuardSkipped は立つ
    func testInkThresholdZeroNeverFlipsToNotVisible() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        let delegate = NoVerdictVisibilityDelegate()
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionInkThreshold: 0, occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { XCTFail("実際は \(outcome.status)"); return }
        
        XCTAssertTrue(outcome.notes.contains(.visibilityGuardSkipped), "\(outcome.notes)")
    }

    /// 陽性対照の注入(FT_FAKE_FM_NO_VERDICT=1): FM を撃たずに OCR/インクだけの代替判定へ落ちる。
    /// **訊いてすらいない**ので visibilityGuardSkipped は立たない(macOS 26 と同じ契約)。
    /// OCR が off なので読みが無く、不可視とも言わない
    func testFMNoVerdictInjectionSkipsFMEntirely() async throws {
        let saved = ProcessInfo.processInfo.environment[FMNoVerdictInjection.environmentKey]
        setenv(FMNoVerdictInjection.environmentKey, "1", 1)
        defer {
            if let saved { setenv(FMNoVerdictInjection.environmentKey, saved, 1) }
            else { unsetenv(FMNoVerdictInjection.environmentKey) }
        }

        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        // visible: true でも呼ばれないことを確かめたいので、あえて可視で埋める
        let delegate = FakeVisibilityDelegate(visible: true)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { XCTFail("実際は \(outcome.status)"); return }
        XCTAssertEqual(delegate.visibleCalls, 0, "注入が効いていれば FM を一切呼ばないはず")
        
        XCTAssertFalse(outcome.notes.contains(.visibilityGuardSkipped),
                       "訊いてすらいないので立たないはず: \(outcome.notes)")
    }

    /// FM が空の転写で「見えない」と答え、要素の領域に構造がある(縦縞)ときは注記 `fm-empty-transcript-on-ink` と
    /// 失敗文の事実を足す。**判定は変えない**(赤のまま)。一様な絵(白紙)では立てない = 白紙の真陽性に混ぜない。
    /// インク閾値を上げて Tier-1 の素通りを止め、FM の段まで届かせる
    func testEmptyFMTranscriptOnInkedAreaIsNotedWithoutChangingTheVerdict() async throws {
        for (png, expectsNote) in [(Self.inkedPNG, true), (Self.blankPNG, false)] {
            let log = CallLog()
            let primary = FakeAppDriver(name: "primary", log: log,
                                        snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                        screenshots: [png])
            let delegate = FakeVisibilityDelegate(visible: false)
            let executor = StepExecutor(driver: primary, delegate: delegate, occlusionInkThreshold: 10_000,
                                        occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
            let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                                          timeout: 0, occlusionGuard: true))
            guard case .failed(let message) = outcome.status else {
                XCTFail("判定は変えないので赤のまま: \(outcome.status)"); continue
            }
            XCTAssertEqual(outcome.notes.contains(.fmEmptyTranscriptOnInk), expectsNote, "\(outcome.notes)")
            XCTAssertEqual(message.contains("FM transcribed nothing"), expectsNote, message)
        }
    }

    /// FM が空の転写で「見えない」と答え、OCR の近道が撃てなかった(起動時の探りが読めていない)とき、**OCR の段がオンなら**
    /// 同じ領域を OCR に読ませ、丸ごと読めれば緑(`ocr-read-what-fm-missed`)。**オフなら OCR を使わず赤のまま**
    /// (利用者が切った段を使わない)。実測: 負荷の下でプロセスの最初のガードが鮮明な `notify=off` を赤にした
    func testEmptyFMTranscriptIsConfirmedByOCROnlyWhenTheOCRStageIsOn() async throws {
        RegionText.modelReadyOverrideForTesting = false
        RegionText.modelCompileFinishOverrideForTesting = {}
        defer {
            RegionText.modelReadyOverrideForTesting = nil
            RegionText.modelCompileFinishOverrideForTesting = nil
        }
        for (mode, expectsPass) in [(RegionTextGateMode.on, true), (.off, false)] {
            let label = "こんにちは"
            let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                        snapshotElements: [[screenFillingTextElement(label: label)]],
                                        screenshots: [screenFillingTextPNG(label)])
            let delegate = FakeVisibilityDelegate(visible: false)
            let executor = StepExecutor(driver: primary, delegate: delegate,
                                        occlusionInkThreshold: 1000, isAndroid: false, tunables: RunTunables())
            executor.occlusionOCRMode = mode
            let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                                          timeout: 0, occlusionGuard: true))
            XCTAssertEqual(delegate.visibleCalls, 1, "\(mode): FM には訊く")
            if expectsPass {
                guard case .passed = outcome.status else { XCTFail("\(mode): 実際は \(outcome.status)"); continue }
                XCTAssertTrue(outcome.notes.contains(.ocrReadWhatFMMissed), "\(mode): \(outcome.notes)")
            } else {
                guard case .failed = outcome.status else { XCTFail("\(mode): 実際は \(outcome.status)"); continue }
                XCTAssertFalse(outcome.notes.contains(.ocrReadWhatFMMissed), "\(mode): \(outcome.notes)")
                XCTAssertTrue(outcome.notes.contains(.fmEmptyTranscriptOnInk), "\(mode): \(outcome.notes)")
            }
        }
    }

    /// 確かめの OCR が「読めた」以外を返したら、その答えを失敗文へ事実として添える(判定は赤のまま)
    func testEmptyTranscriptOCRFactStatesWhatOCRAnswered() {
        let misread = RegionText.Reading(lines: ["wV_resuit=-"], elapsedMs: 1)
        XCTAssertEqual(StepExecutor.emptyTranscriptOCRFact(.read(readable: false, reading: misread)),
                       "; OCR read \"wV_resuit=-\" there, not the expected text")
        XCTAssertEqual(StepExecutor.emptyTranscriptOCRFact(.read(readable: false, reading: RegionText.Reading(lines: [], elapsedMs: 1))),
                       "; OCR found no text there")
        XCTAssertEqual(StepExecutor.emptyTranscriptOCRFact(.unreadable),
                       "; OCR returned no reading (the crop could not be made or Vision failed)")
        XCTAssertTrue(StepExecutor.emptyTranscriptOCRFact(.budgetExhausted).hasPrefix("; OCR did not finish within"))
        XCTAssertEqual(StepExecutor.emptyTranscriptOCRFact(.read(readable: true, reading: misread)), "")
    }

    /// 読み直すのは「何も返さなかった」ときだけ(誤読は読めている Vision の答えなので読み直さない・予算切れも同じ)
    func testConfirmationSawNothingOnlyForEmptyOrNoReading() {
        XCTAssertTrue(StepExecutor.confirmationSawNothing(.read(readable: false, reading: RegionText.Reading(lines: [], elapsedMs: 1))))
        XCTAssertTrue(StepExecutor.confirmationSawNothing(.unreadable))
        XCTAssertFalse(StepExecutor.confirmationSawNothing(.read(readable: false, reading: RegionText.Reading(lines: ["x"], elapsedMs: 1))))
        XCTAssertFalse(StepExecutor.confirmationSawNothing(.read(readable: true, reading: RegionText.Reading(lines: [], elapsedMs: 1))))
        XCTAssertFalse(StepExecutor.confirmationSawNothing(.budgetExhausted))
    }

    /// 配線: OCR の段がオンで、文字の無い縞模様(インクはある)を確かめた回は、失敗文に OCR の答えが載る
    func testEmptyFMTranscriptFailureCarriesTheOCRConfirmationAnswer() async throws {
        RegionText.modelReadyOverrideForTesting = false
        RegionText.modelCompileFinishOverrideForTesting = {}
        defer {
            RegionText.modelReadyOverrideForTesting = nil
            RegionText.modelCompileFinishOverrideForTesting = nil
        }
        // 確かめの読みが空(縞模様に文字は無い)なので、Vision が読めるようになるのを待ってから読み直す(読み直しの配線)
        let waits = LockedCallCount()
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.inkedPNG])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: false),
                                    occlusionInkThreshold: 10_000, isAndroid: false, tunables: RunTunables())
        executor.occlusionOCRMode = .on
        executor.awaitReadableVision = { waits.incrementAndGet(); return true }
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                                      timeout: 0, occlusionGuard: true))
        guard case .failed(let message) = outcome.status else { return XCTFail("実際は \(outcome.status)") }
        XCTAssertTrue(message.contains("FM transcribed nothing"), message)
        XCTAssertTrue(message.contains("; OCR "), message)
        XCTAssertEqual(waits.value, 1, "空の確かめの後に Vision の準備を待っていない")
    }

    /// FM が「見える」と判定したときも、先頭だけ読めた形(partiallyHidden / ellipsized)を注記に残す。
    /// fullyVisible なら何も付けない
    func testFMVisibleVerdictNotesPartialVisibility() async throws {
        for (state, expected) in [("partiallyHidden", StepNote.textPartiallyHidden),
                                  ("ellipsized", StepNote.textEllipsized)] as [(String, StepNote)] {
            let log = CallLog()
            let primary = FakeAppDriver(name: "primary", log: log,
                                        snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                        screenshots: [Self.blankPNG])
            let delegate = FakeVisibilityDelegate(visible: true)
            delegate.visibleState = state
            let executor = StepExecutor(driver: primary, delegate: delegate,
                                        occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
            let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                timeout: 0, occlusionGuard: true)

            let outcome = await executor.execute(step)

            guard case .passed = outcome.status else { XCTFail("\(state): 実際は \(outcome.status)"); continue }
            XCTAssertEqual(delegate.visibleCalls, 1, state)
            XCTAssertTrue(outcome.notes.contains(expected), "\(state): \(outcome.notes)")
        }
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        let executor = StepExecutor(driver: primary, delegate: FakeVisibilityDelegate(visible: true),
                                    occlusionOCRMode: .off, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                                      timeout: 0, occlusionGuard: true))
        XCTAssertFalse(outcome.notes.contains(.textPartiallyHidden), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.textEllipsized), "\(outcome.notes)")
    }

    /// FM の段を切った設定(fmTextVisibilityCheck off = fmVisibilityCheckEnabled: false)では、delegate があっても
    /// FM を呼ばない。OCR も off なら Tier-0 の幾何だけ = 低インクの画面でも緑のまま
    func testFMStageOffNeverCallsFM() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        let delegate = FakeVisibilityDelegate(visible: false)
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, fmVisibilityCheckEnabled: false, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                                      timeout: 0, occlusionGuard: true))

        guard case .passed = outcome.status else { XCTFail("実際は \(outcome.status)"); return }
        XCTAssertEqual(delegate.visibleCalls, 0, "FM の段を切ったのに FM を呼んだ")
        XCTAssertFalse(outcome.notes.contains(.visibilityGuardSkipped), "訊いていないので立たない: \(outcome.notes)")
    }
}
