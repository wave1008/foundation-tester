import Foundation
import FTCore

// 折りたたみ機の開閉(iOS = iPhone Duo の Simulator / Android = 折りたたみの Emulator)。
// 判定・手順は FTCore.FoldControl(MCP の ft_fold と共有)。ここは DSL の口と文言だけ。
// 開閉はシナリオの終わりに元へ戻る(FTDriveCore.restoreFoldIfNeeded。rotateTo の向きと同じ)。

/// 折りたたみ機でないデバイスで fold / unfold / hinge をスキップとして記録するときの理由(docs/commands.md と同文)
let foldNotFoldableSkipReason = "fold / unfold / hinge need a foldable device"
    + " (the iPhone Duo simulator or a foldable Android Emulator)"

/// iOS の実機で fold / unfold / hinge をスキップとして記録するときの理由(docs/commands.md と同文)。
/// 実機は開閉の状態を読む手段も送る手段も無い(Android の実機は device_state で折りたためるかを読める)
let foldPhysicalIOSSkipReason = "fold / unfold / hinge cannot drive a physical iPhone"
    + " (fold it by hand); they run on the iPhone Duo simulator"

/// 閉じる(外側の画面へ)。閉じたことを `waitSeconds`(既定 = `tunables.defaultTimeout`)まで待って確かめ、
/// 閉じなければ失敗。**折りたたみ機でなければシナリオを「対象外(skipped)」で記録する**(失敗ではない)
public func fold(waitSeconds: Double? = nil, file: StaticString = #filePath, line: UInt = #line) {
    foldCommand(.fold, command: "fold", description: "fold", waitSeconds: waitSeconds, file: file, line: line)
}

/// 開く(内側の大きい画面へ)。確かめ方・対象外の扱いは `fold()` と同じ
public func unfold(waitSeconds: Double? = nil, file: StaticString = #filePath, line: UInt = #line) {
    foldCommand(.unfold, command: "unfold", description: "unfold", waitSeconds: waitSeconds, file: file, line: line)
}

/// ヒンジを指定の角度にする(0 = 閉 / 180 = 開。半開きの本の形は 130 前後)。
/// **どちらの画面になるかは確かめない** —— 途中の角度は直前の状態で変わる(iPhone Duo の実測で、開く向きは
/// 120°〜150° の間、閉じる向きは 20°〜10° の間で画面が切り替わる)。画面は次の検証で確かめる
public func hinge(_ degrees: Double, file: StaticString = #filePath, line: UInt = #line) {
    foldCommand(.angle(degrees), command: "hinge", description: "hinge \(formatDegrees(degrees))°",
                waitSeconds: nil, file: file, line: line)
}

private func formatDegrees(_ degrees: Double) -> String {
    degrees == degrees.rounded() ? String(Int(degrees)) : String(degrees)
}

private struct FoldCommandFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// FoldControl の失敗 → DSL の文言(MCP は自前の文言を持つ)
private func foldFailureMessage(_ failure: FoldControl.Failure) -> String {
    switch failure {
    case .outOfRange(let degrees):
        return "hinge degrees must be between 0 (folded) and 180 (unfolded), got \(formatDegrees(degrees))"
    case .notFoldable:
        return foldNotFoldableSkipReason
    case .unreadable(let detail):
        return "could not read whether the device is folded (\(detail)), so nothing was sent"
    case .didNotSwitch(let expected, let observed, let waited):
        let last: String
        switch observed {
        case .state(let state): last = "it stayed \(state.rawValue)"
        case .notFoldable: last = "it no longer reports two built-in displays"
        case .unknown(let detail): last = "the fold state could not be read: \(detail)"
        }
        return "the device did not become \(expected.rawValue) within \(formatDegrees(waited))s after the hinge"
            + " event (\(last)). The hinge event is an undocumented simulator interface, so this Xcode may"
            + " not accept it"
    }
}

private func foldCommand(_ target: FoldTarget, command: String, description: String, waitSeconds: Double?,
                         file: StaticString, line: UInt) {
    let core = FTRuntime.requireCore(command: command)
    if !core.isDryRun, !core.scenarioAborted {
        if core.platform == "ios", core.physical {
            core.skipScenarioNotApplicable(description: description, command: command,
                                           reason: foldPhysicalIOSSkipReason, file: file, line: line)
            return
        }
        if case .notFoldable = FTSync.run({ await core.observeFold() }) {
            core.skipScenarioNotApplicable(description: description, command: command,
                                           reason: foldNotFoldableSkipReason, file: file, line: line)
            return
        }
    }
    let wait = waitSeconds ?? core.tunables.defaultTimeout
    let driver = core.systemDriver
    core.performCustom(description: description, command: command, file: file, line: line) {
        // FoldControl.apply は期限を Int のミリ秒へ畳む(非有限で trap)。MCP・ライブ操作は ArgumentBounds が先に断る
        if let violation = FlowStep.secondsViolation("waitSeconds", wait) { throw FoldCommandFailure(violation) }
        do {
            _ = try await FoldControl.apply(target, waitSeconds: wait,
                                            send: { try await driver.setHingeAngle(degrees: $0) },
                                            observe: { await core.observeFold() },
                                            sent: { core.rememberFoldOriginal($0) })
        } catch let failure as FoldControl.Failure {
            throw FoldCommandFailure(foldFailureMessage(failure))
        }
        await driver.continueAfterFold()
        await core.executor.settleAfterDeviceChange()
    }
}
