// StepExecutor+AssertState.swift
// checkIsON/OFF の状態読み・画像分類・assertCount・screenLooksLike。呼び口は +Assert の dispatchAssert
// (loadedVisionClassifier は +FindImage、checkState は StepExecutor.swift からも)

import Foundation

extension StepExecutor {
    /// オンしか報告しない実装(Compose iOS の Checkbox/Radio・Flutter iOS の Radio)は、オフと
    /// 「状態を持たない要素」が同じ見え方になる。**このシナリオで一度オンを報告した要素**なら、
    /// 状態を持つと分かっているので、報告が無いことをオフと読む
    func checkState(of element: ElementInfo, step: FlowStep) -> CheckState {
        let key = "\(step.locatorSummary)|\(element.type)|\(element.identifier ?? element.label ?? "")"
        let state = CheckStateReading.state(of: element, isAndroid: isAndroid)
        if state == .on { checkStateReporters.insert(key) }
        if state == .unknown, checkStateReporters.contains(key) { return .off }
        return state
    }

    /// 画像分類器を読み込む(分類器ごとにプロセスで1回。見本画像が無ければ nil)。学習・読み込みの失敗は
    /// 理由を `visionClassifierErrors` に残して nil(checkIsON/OFF は a11y だけで判定を続ける =
    /// 注記 check-state-classifier-failed / imageIs は理由を添えて失敗する)
    func loadedVisionClassifier(_ name: String) async -> VisionClassifier.Model? {
        if let loaded = visionClassifiersLoaded[name] { return loaded }
        do {
            guard let root = visionClassifierProjectRoot,
                  let set = try VisionClassifier.trainingSet(
                      at: VisionClassifier.directory(projectRoot: root, name: name)) else {
                visionClassifiersLoaded[name] = .some(nil)
                return nil
            }
            let model = try await VisionClassifier.load(
                set, cacheDirectory: VisionClassifier.cacheDirectory(projectRoot: root, name: name))
            visionClassifiersLoaded[name] = .some(model)
            if !model.mismatches.isEmpty { visionClassifierMismatches[name] = model.mismatches }
            return model
        } catch {
            visionClassifierErrors[name] = ErrorText.user(error)
            noteCodesThisStep.insert(.visionClassifierUnavailable)
            if name == CheckStateClassifier.name { noteCodesThisStep.insert(.checkStateClassifierFailed) }
            visionClassifiersLoaded[name] = .some(nil)
            return nil
        }
    }

    /// 要素の枠でスクリーンショットを切り、分類器の1位を返す(撮れない・切れないときは nil)
    func classifyElementImage(_ element: ElementInfo, screen: FTRect, keyboardShown: Bool,
                              with classifier: VisionClassifier.Model,
                              phase: inout PhaseAccumulator) async -> VisionClassifier.Classification? {
        guard let png = try? await judgmentScreenshot(keyboardShown: keyboardShown, phase: &phase),
              let image = VisionClassifier.crop(png: png, frame: element.frame, screen: screen) else { return nil }
        classifierScreenshotThisStep = png
        // アプリの領域が一色の絵(撮れていない・何も描かれていない)は分類しない。一色の切り出しは [OFF] に似ていて、ON の要素を
        // 確信度 1.00 で [OFF] と答えた実測がある(Android Emulator・配信 24fps + 8 並列)。checkIsON/OFF は
        // a11y の読みで判定し、待ちの次の周回が撮り直す
        if BlankFrameDetector.isUnjudgeable(pngData: png) {
            classifierFailureThisStep = "the app area of the screenshot is a single colour (nothing is drawn there,"
                + " or the capture failed), so the element image was not classified"
            return nil
        }
        do {
            return try classifier.classify(image)
        } catch {
            classifierFailureThisStep = ErrorText.user(error)
            return nil
        }
    }

    /// 要素の枠でスクリーンショットを切り、分類器の1位のラベルを状態へ写す。ラベルが [ON]/[OFF] を
    /// 含まない・撮れない・切れないときは nil(a11y の判定のまま)
    func classifyCheckState(_ element: ElementInfo, screen: FTRect, keyboardShown: Bool,
                            with classifier: VisionClassifier.Model, phase: inout PhaseAccumulator)
        async -> (state: CheckState, classification: VisionClassifier.Classification)? {
        guard let classification = await classifyElementImage(element, screen: screen, keyboardShown: keyboardShown,
                                                               with: classifier, phase: &phase),
              let state = CheckStateClassifier.state(forLabel: classification.label) else { return nil }
        return (state, classification)
    }

    static func checkStateSourceHint(_ classification: VisionClassifier.Classification?,
                                     classifierError: String?) -> String {
        if let classification {
            return " (judged by CheckStateClassifier from the element image: label \"\(classification.label)\","
                + " confidence \(String(format: "%.2f", classification.confidence));"
                + " the screenshot it judged is attached to the report)"
        }
        if let classifierError { return " (CheckStateClassifier was not used: \(classifierError))" }
        return ""
    }

    /// checkIsON/OFF の失敗文。**状態が読めず、分類器に使えなかった理由があるときは「見本を置け」と言わない** ——
    /// 見本は置いてあり、学習・読み込み・推論の対照のどれかで使えなかった(枠の中で Create ML が見本を見つけられず
    /// 学習できなかったとき、案内が見本を置けと勧め、本当の理由は文の末尾に回っていた)
    static func checkStateFailure(_ state: CheckState, locator: String,
                                  classification: VisionClassifier.Classification?,
                                  classifierError: String?) -> String {
        if state == .unknown, let classifierError {
            return "the element reports no check state and CheckStateClassifier could not judge it from its image:"
                + " \(locator) (accessibility has no selected trait and no on/off value; CheckStateClassifier:"
                + " \(classifierError))"
        }
        return checkStateMismatch(state, locator: locator)
            + checkStateSourceHint(classification, classifierError: classifierError)
    }

    static func checkStateMismatch(_ state: CheckState, locator: String) -> String {
        switch state {
        case .on: return "the element is on: \(locator)"
        case .off: return "the element is off: \(locator)"
        case .indeterminate: return "the element is in an indeterminate (partially checked) state: \(locator)"
        case .unknown:
            return "the element reports no check state: \(locator) (no selected trait and no on/off value; "
                + "it is either off or an implementation that does not expose its check state to accessibility, "
                + "such as a custom-drawn button. Verify a text that reflects the state with textIs, have the app "
                + "expose it (e.g. SwiftUI .accessibilityRepresentation { Toggle(...) }), or put sample images of the "
                + "element in vision/classifiers/CheckStateClassifier/[ON] and [OFF] to judge it from its image)"
        }
    }

    func executeAssertCount(step: FlowStep,
                                    phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        guard let expectedCount = step.expectedCount else {
            return .skipped("expectedCount was not specified")
        }
        guard let locator = step.locator else {
            return .skipped("no locator specified")
        }
        // `||` は**候補集合の和**(Shirates 準拠)。全節の候補を合わせ、同じ要素は1度だけ数える。
        // 節の優先順位が効くのは要素を1つ選ぶときだけで、数えるときは節を跨いで合計する
        let chain = [locator] + (step.fallbacks ?? [])
        let deadline = Date().addingTimeInterval(step.timeout ?? tunables.defaultTimeout)
        let stepStart = clock.now
        var freshRetry = AssertFreshRetry(bypassOnRepoll: repollBypassesCache)
        var lastSnapshotMs = 0
        var backoff = PollBackoff()
        var actual = 0
        var breakdown: [(clause: FlowLocator, elements: [ElementInfo])] = []
        var nestingHint = ""
        /// 失敗文言に切り詰めを添えるための直近の観測
        var lastSnapshot: SnapshotResponse?
        // 一度でも上限に当たったら以後は天井で撮る(notExists と同じ latch)
        var needsCeiling = false
        while true {
            let start = clock.now
            if needsCeiling { driver.raiseElementLimitOnNextSnapshot(BridgeAPI.maxSnapshotElementsCeiling) }
            var snapshot = try await assertionSnapshot(&freshRetry)
            if let injectedDelay = SlowSnapshotInjection.delay() { try await Task.sleep(for: injectedDelay) }
            let snapshotMs = Self.ms(clock.now - start)
            phase.snapshotMs += snapshotMs
            lastSnapshotMs = snapshotMs
            if Double(snapshotMs) / 1000 > (step.timeout ?? tunables.defaultTimeout) {
                noteCodesThisStep.insert(.slowSnapshot)
            }
            try await dismissInterruption(in: &snapshot, phase: &phase)
            noteEmptyWebView(snapshot)
            // **件数は木の完全性がそのまま結果になる**(間引かれた分は「無い」と区別が付かない)。
            // 不在と違い一致・不一致のどちらにも効くので、数える前に撮り直す
            if snapshot.truncatedCount > 0, !needsCeiling {
                needsCeiling = true
                snapshot = try await retakenAtElementLimitCeiling(snapshot, phase: &phase)
            }
            lastSnapshot = snapshot
            breakdown = LocatorResolver.unionByClause(chain, elements: snapshot.elements)
            actual = breakdown.reduce(0) { $0 + $1.elements.count }
            nestingHint = LocatorResolver.nestingHint(breakdown.flatMap(\.elements),
                                           in: snapshot.elements)
            if actual == expectedCount {
                // **一致した周でだけ評価する**(notExists と同じ理由。不一致はそのまま赤くなるので
                // 「不在の証拠にならない」と言う相手が居ない)
                noteUnderreportedTree(snapshot)
                // 天井でも足りない木で数えた一致は根拠にならない(notExists と同じ誤った成功)
                if snapshot.truncatedCount > 0 {
                    return failedWithoutKind(Self.undecidableTruncationMessage(
                        "the count", step: step,
                        evidence: Self.ceilingTruncationEvidence(snapshot)))
                }
                return .passed
            }
            if Date() >= deadline {
                // 失敗と決める前に、キャッシュを捨てた1周だけ確かめる(AssertFreshRetry)
                if SlowSnapshotBudget.mayRetake(stepElapsedMs: Self.ms(clock.now - stepStart),
                                                lastSnapshotMs: lastSnapshotMs,
                                                commandTimeoutMs: commandTimeoutMs),
                   freshRetry.arm(ifSupported: driver.supportsCacheBypass) {
                    continue
                }
                break
            }
            let waitStart = clock.now
            try await Task.sleep(for: backoff.nextDelay())
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
        // 節が複数あるときは**どの節が何件拾ったか**まで出す。和集合の総数だけだと
        // 「どれが想定より多く拾ったのか」が分からず、セレクタを直すのに snapshot を
        // 取り直す往復が要る(実例: ラベルで数えてボタンの内側の Text も拾っていた)
        let detail = breakdown.count > 1
            ? "breakdown: " + breakdown.map { "\($0.clause.summary) \($0.elements.count)" }
                .joined(separator: " / ")
            : step.locatorSummary
        // **切り詰めは不一致の側にも効く**(間引かれた分だけ actual が少ない)。天井まで上げても
        // 残っているときは判定不能だが、既に不一致なので誤った成功にはならない = 注記で足りる
        return .failed("count mismatch: expected \(expectedCount), actual \(actual) (\(detail))"
                       + nestingHint + Self.truncationHint(lastSnapshot))
    }

    func executeAssertScreenMatches(
        step: FlowStep, phase: inout PhaseAccumulator) async throws -> StepResult.Status {
        let clock = ContinuousClock()
        guard screenLooksLikeEnabled else {
            return .skipped("screenLooksLike is disabled (run profile setting)")
        }
        guard let expected = step.expected, !expected.isEmpty else {
            return .skipped("expected was not specified")
        }
        guard let delegate else {
            return .skipped("FM verification is disabled (Foundation Models unavailable)")
        }
        // スクショを撮る前に落とす(画像を渡せない環境では検証自体が成立しない)
        guard FMVisionSupport.isSupported else {
            return .skipped("screen verification is disabled (\(FMVisionSupport.requirement))")
        }
        let frozen = StepResult.Status
            .skipped("aborted due to a frozen display (blank frame) — requeued onto another device")
        guard let screenshot = try await unfrozenScreenshot(phase: &phase) else {
            onDeviceFrozen?()
            return frozen
        }
        // ステータスバーだけが残った黒(撮れていない・表示の凍結)を FM に渡すと必ず「一致しない」になる。
        // 可視性検証と同じく判定の根拠にしない(凍結の根拠にもしない = 回復は撃たない)
        if BlankFrameDetector.isBlackApartFromSystemBars(pngData: screenshot) {
            noteCodesThisStep.insert(.blankScreenshot)
            return .skipped("the screenshot is black apart from the system bars (the capture failed or the"
                + " display is frozen), so the screen was not verified")
        }
        guard let verdict = await delegate.verifyScreen(expected: expected, screenshotPNG: screenshot) else {
            return .skipped("could not run screen verification")
        }
        if verdict.pass { return .passed }
        // **不一致なら1回だけ撮り直して判定し直す**。他の検証は timeout までポーリングして遷移の
        // 整定を吸収するが、screenLooksLike にそれを許すと FM 照合(ホスト全体で直列・約1回/秒)を
        // 何度も焼くので、**回数を1回に固定**する(正常系のコストは増えない・失敗系で +1 回)。
        // 狙いは「遷移直後のまだ描き終わっていない画面」の1件だけを救うこと
        let start = clock.now
        try await Task.sleep(nanoseconds: UInt64(Self.screenMatchRetryDelayMs) * 1_000_000)
        phase.waitMs += Self.ms(clock.now - start)
        // **撮り直しも白フレーム検査を通す**。素の screenshot() を呼ぶと、凍結した画面を FM に渡して
        // 「画面が一致しない」で落ち、requeue すべき凍結を検証失敗に見せかける
        guard let retryShot = try await unfrozenScreenshot(phase: &phase) else {
            onDeviceFrozen?()
            return frozen
        }
        // 撮り直しだけが黒なら、1 枚目の不一致をそのまま返す(見送ると本物の不一致を黒い絵で消す)
        if BlankFrameDetector.isBlackApartFromSystemBars(pngData: retryShot) {
            return .failed("the screen does not match the expectation: \(verdict.reason)")
        }
        guard let retryVerdict = await delegate.verifyScreen(expected: expected,
                                                             screenshotPNG: retryShot) else {
            return .failed("the screen does not match the expectation: \(verdict.reason)")
        }
        if retryVerdict.pass { return .passed }
        return .failed("the screen does not match the expectation: \(retryVerdict.reason)")
    }

    /// スクショを撮り、白フレーム(画面凍結)なら回復を待って最大2回まで撮り直す。
    /// **白のままなら nil**(呼び手が onDeviceFrozen + requeue する)。
    /// 白フレームを FM 検証に渡すと必ず不一致になり、凍結が「検証失敗」に化けるための防波堤
    private func unfrozenScreenshot(phase: inout PhaseAccumulator) async throws -> Data? {
        let clock = ContinuousClock()
        var start = clock.now
        // 画面全体の FM 判定は1回で数秒かかるので、inapp モードでは常に画面全体の絵(JudgmentCapture)
        var screenshot = try await judgmentScreenshot(keyboardShown: false, alwaysWholeScreen: true, phase: &phase)
        phase.actionMs += Self.ms(clock.now - start)
        guard BlankFrameDetector.isUniformBlank(pngData: screenshot) else { return screenshot }
        for _ in 0..<2 {
            start = clock.now
            try await Task.sleep(nanoseconds: 2_000_000_000)
            phase.waitMs += Self.ms(clock.now - start)
            start = clock.now
            screenshot = try await judgmentScreenshot(keyboardShown: false, alwaysWholeScreen: true, phase: &phase)
            phase.actionMs += Self.ms(clock.now - start)
            if !BlankFrameDetector.isUniformBlank(pngData: screenshot) { return screenshot }
        }
        return nil
    }
}
