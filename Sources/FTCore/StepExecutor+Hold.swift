// StepExecutor+Hold.swift
// hold(セレクタ) { } の実体(holdStart/holdEnd の2アクション。DSL は Sources/FTDSL/Commands.swift)。
// holdStart はブリッジの /hold を撃つだけ(離すのはブリッジが自分の時計でやる。BridgeDTO.HoldRequest
// 参照)。holdEnd はその離し時刻まで待って整定を見るだけで、デバイスには何も送らない。
// 中断されたシナリオでも指を下げたままにしないための待ちは FTDriveCore.finishHold が
// waitOutHold() で(holdEnd という「ステップ」を経由せず)直接使う。

import Foundation

extension StepExecutor {

    /// 指が離れたとみなすまでに `duration` へ足す余裕(秒)。ブリッジは自分の時計で離すので、ホストは
    /// 離れたことを観測できない。**根拠**: XCUITest の合成タッチの再生は 3 秒の経路で 0.4〜0.7 秒遅れる
    /// (実測。Runner の CoordinatePinch.minimumSegment の doc)。足りないと、指が下りたまま次の操作を撃つ
    static let holdReleaseMargin: Double = 0.8

    /// holdStart の実体。tap の長押し分岐(StepExecutor+Actions.swift の「長押しは tap の引数」)と
    /// 同じ絵で対象を仕上げてから、座標で /hold を送る。**ref ではなく x/y で送る**のは、in-app が
    /// 501 を返したときに press と同じ座標フォールバック(gestureWithFallback)へそのまま乗せるため
    /// (ref はブリッジごとに別の名前空間で、フォールバック先での取り直しが要る)。
    /// 呼び出し元(StepExecutor+Actions.swift の switch)が保持している element/snapshot を
    /// 更新できるよう、更新後の値と注記を返す
    func executeHoldStart(element initialElement: ElementInfo, snapshot initialSnapshot: SnapshotResponse,
                          step: FlowStep, phase: inout PhaseAccumulator) async throws
        -> (element: ElementInfo, snapshot: SnapshotResponse, driverFallback: String?, refusal: String?) {
        var element = initialElement
        var snapshot = initialSnapshot
        var driverFallback: String?
        var namedTarget = false
        // tap の長押し分岐と同じ規律: 注記を出すときだけ、まず解決先を1回名乗る
        func adviseTarget(_ advisory: String?) {
            guard let advisory else { return }
            if !namedTarget {
                namedTarget = true
                driverFallback = Self.joinNotes(driverFallback,
                    "resolved to \(TapTargetGeometry.describe(element)) (\(element.type))")
            }
            driverFallback = Self.joinNotes(driverFallback, advisory)
        }
        let keyboardOcclusion = KeyboardOcclusion.resolve(
            reported: snapshot.keyboardFrame, in: snapshot.elements)
        adviseTarget(keyboardOcclusion.advisory(for: element))
        adviseTarget(OverlayWindowOcclusion.resolve(
            reported: snapshot.overlayWindowFrames).advisory(for: element))
        adviseTarget(TapTargetGeometry.disabledAdvisory(for: element))
        adviseTarget(duplicateRegionAdvisory(element, in: snapshot))
        // 縁の帯に潜っているだけなら、撃つ前に1回だけ送って外す(tap の長押し分岐と同じ手順)
        // 座標で撃つ(ref を使わない)ので撮り直しは主ドライバでよい。見失ったら撃たない
        if let lifted = try await liftCoveredTarget(element, in: snapshot, step: step,
                                                    verb: "touching", snapshotSource: .primary, phase: &phase) {
            guard let liftedElement = lifted.element else {
                return (element, lifted.snapshot, driverFallback, Self.coverLiftLostMessage(step, verb: "touching"))
            }
            element = liftedElement
            snapshot = lifted.snapshot
            driverFallback = Self.joinNotes(driverFallback, lifted.note)
        }
        adviseTarget(TapTargetGeometry.occlusionAdvisory(
            for: element, in: snapshot.elements, screen: snapshot.screen, isAndroid: isAndroid))
        // 中心が容器の外に落ちる要素だけ、見えている部分の中心を撃つ(tap の座標タップ分岐と同じ規律)
        let rect = Self.visibleTapRect(for: element, in: snapshot.elements,
                                       inferring: step.containerInference ?? true,
                                       scale: driver.pointScale) ?? element.frame
        let duration = step.duration ?? tunables.defaultHoldDuration
        // **指を置く前に OCR のコンパイルを済ませる**: ブロックの最初の視覚検証がコンパイルを待つと(実測 12 秒)、
        // その間に指が離れて押している間だけ出る部品が消える。occlusionFlip と同じ条件で待つ
        // (詰まった読みがある間は待たない)。待った時間は視覚検証の内訳へ入れる
        // 見るのは実行プロファイルの親スイッチ(ステップの既定ガードは off で、各 exist が自分で立てる)
        if occlusionGuardEnabled, occlusionOCRMode != .off,
           RegionText.abandonedInFlight == 0, !RegionText.isModelReady {
            let waitStart = ContinuousClock().now
            let waitOutcome = await RegionText.awaitModelCompile(mode: occlusionOCRMode)
            let waitedMs = Self.ms(ContinuousClock().now - waitStart)
            if waitedMs > 0 {
                phase.guardMs += waitedMs
                phase.ocrMs += waitedMs
                noteCodesThisStep.insert(.ocrCompileWaited)
            }
            if case .capped = waitOutcome { noteCodesThisStep.insert(.ocrCompileCapped) }
        }
        let clock = ContinuousClock()
        // **送る直前**の時刻から離し時刻を数える(送信・応答の往復ぶんずれない)
        let sentAt = clock.now
        let viaXCUITest = try await gestureWithFallback(phase: &phase) {
            try await $0.hold(x: rect.centerX, y: rect.centerY, duration: duration)
        }
        // **送れたときだけ**離し時刻を立てる(送れていなければ指は下がっていない)
        holdLiftsAt = sentAt.advanced(by: .seconds(duration))
        if viaXCUITest { driverFallback = Self.joinNotes(driverFallback, "fell back to XCUITest") }
        return (element, snapshot, driverFallback, nil)
    }

    /// holdEnd の実体。ブリッジが `duration` 秒後に自分で指を離すので、ここでは
    /// **その時刻まで待つだけ**(何も送らない)。待ちの中身は中断中のシナリオが直接呼ぶ
    /// `waitOutHold()` と共有する(`releaseHoldAndWait` の1箇所)
    func executeHoldEnd(phase: inout PhaseAccumulator) async throws -> StepOutcome {
        guard holdLiftsAt != nil else {
            // 一度も hold していない(holdStart が要素未発見等で送らなかった) = 何もしない
            return StepOutcome(status: .passed)
        }
        var notes: [String] = []
        if await releaseHoldAndWait(phase: &phase) {
            note(.holdEndedBeforeBlock, into: &notes)
        }
        let settled = try await settledSignature(phase: &phase).settled
        if !settled { note(.settleCapped, into: &notes) }
        return StepOutcome(status: .passed,
                           driverFallback: notes.isEmpty ? nil : notes.joined(separator: " / "))
    }

    /// `hold { }` のブロックの中で失敗したステップに、**その時点で指が既に上がっていた**事実を残す。
    /// 失敗でシナリオが中断されると `holdEnd` は実行されず、あちらの注記では残せない(押している間だけ出る
    /// 部品を待っているうちに `holdSeconds` が尽きた失敗が、ただの「見つからない」に見える)。
    /// 判定は変えない。holdStart / holdEnd 自身には立てない
    func noteHoldAlreadyReleased(onFailureOf step: FlowStep, status: StepResult.Status) {
        guard case .failed = status, step.action != "holdStart", step.action != "holdEnd",
              let liftsAt = holdLiftsAt, ContinuousClock().now > liftsAt else { return }
        noteCodesThisStep.insert(.holdEndedBeforeBlock)
    }

    /// **中断されたシナリオでも**、ブリッジが指を離す時刻までは待つ(`FTDriveCore.finishHold` からだけ
    /// 呼ぶ)。中断中は `holdEnd` という「ステップ」自体が実行されない(perform() が触らずに
    /// skip を記録して返る)ので、待ちだけをここで直接行う。何も送らない・失敗しない・記録も残さない
    /// (実行ステップとして記録されない経路なので throw できない)
    public func waitOutHold() async {
        var phase = PhaseAccumulator()
        _ = await releaseHoldAndWait(phase: &phase)
    }

    /// `holdLiftsAt` が立っていなければ何もしない。立っていれば `holdReleaseMargin` を足した時刻まで
    /// 待ってクリアする(呼ぶたびに消費するので、`executeHoldEnd` と `waitOutHold` の両方から
    /// 呼ばれても二重に待たない)。
    /// **戻り値**: 呼ばれた時点で既にその時刻を margin 超えて過ぎていたか
    /// (= `hold { }` のブロックが `holdSeconds` より長く掛かった)
    @discardableResult
    private func releaseHoldAndWait(phase: inout PhaseAccumulator) async -> Bool {
        guard let liftsAt = holdLiftsAt else { return false }
        holdLiftsAt = nil
        let clock = ContinuousClock()
        let deadline = liftsAt.advanced(by: .seconds(Self.holdReleaseMargin))
        guard clock.now < deadline else { return true }
        let waitStart = clock.now
        try? await Task.sleep(for: deadline - clock.now)
        phase.waitMs += Self.ms(clock.now - waitStart)
        return false
    }
}
