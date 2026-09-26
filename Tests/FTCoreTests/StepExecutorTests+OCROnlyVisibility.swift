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
    /// (E2E の暖機前のステップで実際に出た)。FM に訊いた回なので visibilityGuardSkipped は立つ
    func testNoVerdictFromFMWithoutOCRReadingDoesNotJudgeByInkAlone() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[textElement(id: "msg", label: "こんにちは")]],
                                    screenshots: [Self.blankPNG])
        let delegate = NoVerdictVisibilityDelegate()
        let executor = StepExecutor(driver: primary, delegate: delegate,
                                    occlusionOCRMode: .off, isAndroid: false)
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
                                    occlusionInkThreshold: 0, occlusionOCRMode: .off, isAndroid: false)
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
                                    occlusionOCRMode: .off, isAndroid: false)
        let step = FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                            timeout: 0, occlusionGuard: true)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { XCTFail("実際は \(outcome.status)"); return }
        XCTAssertEqual(delegate.visibleCalls, 0, "注入が効いていれば FM を一切呼ばないはず")
        
        XCTAssertFalse(outcome.notes.contains(.visibilityGuardSkipped),
                       "訊いてすらいないので立たないはず: \(outcome.notes)")
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
                                        occlusionOCRMode: .off, isAndroid: false)
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
                                    occlusionOCRMode: .off, isAndroid: false)
        let outcome = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "msg"),
                                                      timeout: 0, occlusionGuard: true))
        XCTAssertFalse(outcome.notes.contains(.textPartiallyHidden), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.textEllipsized), "\(outcome.notes)")
    }
}
