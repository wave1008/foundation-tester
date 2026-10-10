// StepExecutor+WaitForSettle.swift
// DSL の waitForSettle。段1 = ブリッジの画像の静止判定(WaitForSettleRequest・画像はホストへ出ない)、
// 段2 = ホストで木が追いつくまで(範囲内の署名が連続2枚一致)。呼び口は StepExecutor+Actions.swift の executeAction。
// waitSeconds は段1・段2で共有する(段1が使った残りが段2の持ち時間)

import Foundation

extension StepExecutor {

    /// 省略時の既定を畳んだ (quietSeconds, waitSeconds)。quiet = UI フレームワーク別、wait = `tunables.screenWaitTimeout`
    func waitForSettleSeconds(for step: FlowStep) -> (quiet: Double, wait: Double) {
        (step.quietSeconds ?? WaitForSettleDefaults.quietSeconds(framework: uiFramework, isAndroid: isAndroid),
         step.timeout ?? tunables.screenWaitTimeout)
    }

    /// デバイスに触る前の検査。違反なら失敗の文言
    func waitForSettleViolation(for step: FlowStep) -> String? {
        let seconds = waitForSettleSeconds(for: step)
        if case .failure(let violation) = WaitForSettleArguments.plan(quietSeconds: seconds.quiet,
                                                                      waitSeconds: seconds.wait) {
            return violation.message
        }
        return nil
    }

    /// HTTP の待ちの上限 = 要求の timeoutMs + この余裕(秒)。ブリッジは最初の撮影から timeoutMs 経ったあと、最後の1枚の
    /// 撮影と比較を終えてから返すので、timeoutMs ちょうどだと正常な「時間切れ」の応答が通信の失敗になる。
    /// 余裕は撮影の間隔(Simulator 約 0.1 秒。`waitForSettleQuietRangeMs` の doc)を十分に超える値。
    /// 尽きたときは通信のタイムアウトとして DriverError で失敗する(静止の判定ではない)
    static let waitForSettleTransportMarginSeconds: Double = 5

    static let waitForSettleNeedsScreenCapture = "waitForSettle needs a whole-screen capture; the in-app engine only"
        + " sees the app itself (no keyboard or system alerts). Switch the run profile to hybrid or xcuitest"

    /// waitForSettle 本体。`region` = 比べる範囲(nil = 画面全体)。`startedAt` = ステップの開始(範囲の要素の解決も
    /// waitSeconds の中に数える)。戻り値の note は driverFallback に載る(throwsException: false で諦めた事実)
    func executeWaitForSettle(step: FlowStep, region: FTRect?, startedAt: ContinuousClock.Instant,
                              phase: inout PhaseAccumulator) async throws
        -> (status: StepResult.Status, note: String?) {
        let seconds = waitForSettleSeconds(for: step)
        let plan: WaitForSettleArguments.Plan
        switch WaitForSettleArguments.plan(quietSeconds: seconds.quiet, waitSeconds: seconds.wait) {
        case .success(let value): plan = value
        case .failure(let violation): return (.failed(violation.message), nil)
        }
        // 待ち終えた後の次のロケータ操作は、キャッシュを迂回した1枚で解決する(`skippingSettle` と同じ理由:
        // 待った間にも画面は動いており、Android の素取得は古い木を返しうる)
        defer { nextResolveBypassesCache = true }
        let clock = ContinuousClock()
        let deadline = startedAt.advanced(by: .milliseconds(plan.timeoutMs))
        let timeoutMs = min(plan.timeoutMs, max(0, Self.ms(deadline - clock.now)))

        // 段1。iOS は常に XCUITest 側で撮る(in-app はアプリ自身の描画しか撮れず、メインスレッドも塞ぐ)
        let request = WaitForSettleRequest(region: region, quietMs: plan.quietMs, timeoutMs: timeoutMs)
        let stageOneStart = clock.now
        let response: WaitForSettleResponse
        do {
            response = try await (typeDriver ?? driver).waitForSettle(
                request, timeoutSeconds: Double(timeoutMs) / 1000 + Self.waitForSettleTransportMarginSeconds)
        } catch {
            guard DriverError.isEngineIncapable(error), typeDriver == nil, !isAndroid else { throw error }
            return (.failed(Self.waitForSettleNeedsScreenCapture), nil)
        }
        phase.waitMs += Self.ms(clock.now - stageOneStart)
        guard response.settled else {
            // 窓より短い時間しか見られなかった(要素を探すのに上限の大半を使った・waitSeconds < quietSeconds)なら、
            // 「変わり続けた」とは言えない = 見られた時間が窓に足りなかった事実を書く
            if timeoutMs < plan.quietMs {
                let left = Self.settleSecondsText(Double(timeoutMs) / 1000)
                let quiet = Self.settleSecondsText(Double(plan.quietMs) / 1000)
                let message = plan.timeoutMs < plan.quietMs
                    ? "waitSeconds is shorter than quietSeconds (\(quiet)s), so the screen can never count as still"
                    : "only \(left)s of waitSeconds was left after finding the element, shorter than quietSeconds"
                        + " (\(quiet)s), so the screen could not be confirmed still"
                return gaveUpWaitingForSettle(step: step, message: message)
            }
            var message = "the screen kept changing for \(Self.settleSecondsText(Double(response.elapsedMs) / 1000))s"
            if let change = response.lastChangeRegion {
                message += " (last change at x=\(Self.coordinateText(change.x)), y=\(Self.coordinateText(change.y)),"
                    + " \(Self.coordinateText(change.width))×\(Self.coordinateText(change.height)))"
            }
            return gaveUpWaitingForSettle(step: step, message: message)
        }

        // 段2。ここから先は driver(次のステップのロケータを解決するほう)の木
        let stageTwoStart = clock.now
        switch try await syncTree(region: region, deadline: deadline, phase: &phase) {
        case .synced:
            return (.passed, nil)
        case .gaveUp(let changing):
            var message = "the screen was still but the accessibility tree kept changing for"
                + " \(Self.settleSecondsText(Double(Self.ms(clock.now - stageTwoStart)) / 1000))s"
            if !changing.isEmpty {
                let shown = changing.prefix(TreeSyncSignature.namesInMessage).joined(separator: ", ")
                message += " (changing: \(shown)\(changing.count > TreeSyncSignature.namesInMessage ? ", …" : ""))"
            }
            return gaveUpWaitingForSettle(step: step, message: message)
        }
    }

    /// 待ちの上限まで静止しなかったときの結末。throwsException: false は注記(`settle-not-reached`)と事実の文言を
    /// 残して通す。**範囲の要素が解決できない失敗はここを通らない**(引数で空振りを許さない)
    private func gaveUpWaitingForSettle(step: FlowStep, message: String) -> (status: StepResult.Status, note: String?) {
        if step.throwsException == false {
            var parts: [String] = []
            note(.settleNotReached, into: &parts)
            parts.append(message)
            return (.passed, parts.joined(separator: " / "))
        }
        return (failed(.timeout, message), nil)
    }

    private static func settleSecondsText(_ seconds: Double) -> String {
        FTSeconds.format((seconds * 10).rounded() / 10)
    }

    /// 座標(iOS pt / Android px)は小数1桁に丸める(iOS は px÷倍率で 183.666… になる)
    private static func coordinateText(_ value: Double) -> String {
        FTSeconds.format((value * 10).rounded() / 10)
    }

    // MARK: - 段2: 木が追いつくまで

    enum TreeSyncResult: Equatable {
        case synced
        /// 上限まで連続2枚が一致しなかった。changing = 最後の2枚の差に出た要素名(空もありうる)
        case gaveUp(changing: [String])
    }

    /// 範囲内の要素の署名が**連続2枚同じ**になるまで撮り直す。周期は整定ポーリングと同じ規則(`settleSleepMs`)、
    /// キャッシュ迂回も同じ(`.afterOwnMove`)。**上限を過ぎても最低1組は比べる**(木を1枚しか撮らずに
    /// 「追いつかなかった」とは言えない。超過は撮影1枚ぶんまで)
    func syncTree(region: FTRect?, deadline: ContinuousClock.Instant,
                  phase: inout PhaseAccumulator) async throws -> TreeSyncResult {
        let clock = ContinuousClock()
        var previous: [TreeSyncSignature.Entry]?
        while true {
            let start = clock.now
            let snapshot = try await freshSnapshot(.afterOwnMove)
            let snapshotMs = Self.ms(clock.now - start)
            phase.snapshotMs += snapshotMs
            let current = TreeSyncSignature.entries(snapshot, region: region)
            if let previous {
                if previous == current { return .synced }
                if clock.now >= deadline {
                    return .gaveUp(changing: TreeSyncSignature.difference(previous, current))
                }
            }
            previous = current
            let period = Self.settleSleepMs(afterSnapshotMs: snapshotMs, bypassing: bypassesCache(.afterOwnMove),
                                            treeLags: driver.treeLagsBehindMotion)
            let remaining = max(0, Self.ms(deadline - clock.now))
            let waitStart = clock.now
            try await Task.sleep(for: .milliseconds(max(Self.scrollSettleMinSleepMs, min(period, remaining))))
            phase.waitMs += Self.ms(clock.now - waitStart)
        }
    }
}
