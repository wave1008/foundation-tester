// **アラート自身を対象にした検証を、門(executeAssert の SystemUIGate)が奪わない**ことを固定する。
//
// exists は fallback(SpringBoard)で解決したときに `resolvedViaSystemUIThisStep` を立てていたが、
// 値比較(textEquals 等)と notExists は立てていなかった。門は「覆われている」と読んで、
// いま検証したアラートを閉じてから判定し直し(`element not found`)、緑を赤にすり替えていた。
// 判定材料は **fallback.tap の有無**(閉じたかどうか)—— 合否だけだと閉じた末に別の理由で
// 落ちる形と区別できない

import XCTest
@testable import FTCore

final class SystemUIGateAssertOnAlertTests: XCTestCase {

    /// SpringBoard の木に載るアラート本体(題名を持つ)
    private func alertTitled(_ title: String) -> ElementInfo {
        ElementInfo(ref: 100, type: "alert", identifier: nil, label: title, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 300, height: 200), depth: 0)
    }

    private func labeled(ref: Int, label: String) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: nil, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    /// 登録がある(= 門が動く)状態で、アラートのボタンだけを持つ fallback を組む
    private func makeExecutor(log: CallLog) -> StepExecutor {
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let fallback = FakeAppDriver(name: "fallback", log: log,
                                     snapshotElements: [[alertTitled("権限"),
                                                         labeled(ref: 9, label: "許可")]])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: true, title: "権限",
                                                               buttons: ["許可"])]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false)
        // 登録のボタンはアラートのボタンと一致させる = 門が閉じられる形にしておく
        // (閉じられない登録だと「閉じなかった」のが規律のおかげか登録のおかげか分からない)
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*権限*", button: "許可"))
        return executor
    }

    /// `textIs("許可", "許可")` が fallback で解決したら**そのまま通し、閉じない**
    /// (testAssertOnTheAlertItselfStaysGreen の値比較版)
    func testTextComparisonOnTheAlertItselfPassesWithoutDismissing() async throws {
        let log = CallLog()
        let executor = makeExecutor(log: log)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(label: "許可"),
                            expected: "許可", timeout: 2)

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            return XCTFail("アラート自身の値比較は通すこと: \(outcome.status)")
        }
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("fallback.tap") },
                       "検証したアラートを閉じてはいけない: \(log.entries)")
        XCTAssertFalse(outcome.notes.contains(.waitedForSystemUI), "\(outcome.notes)")
    }

    /// 不一致で落ちる回も同じ —— 閉じてしまうと理由が「不一致」から「不在」に化ける
    func testMismatchOnTheAlertItselfStaysAMismatchWithoutDismissing() async throws {
        let log = CallLog()
        let executor = makeExecutor(log: log)
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(label: "許可"),
                            expected: "Allow", timeout: 1)

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else {
            return XCTFail("不一致は失敗のまま: \(outcome.status)")
        }
        XCTAssertTrue(reason.contains("text does not equal"),
                      "不一致の理由文であること(不在にすり替えない): \(reason)")
        XCTAssertFalse(reason.contains("element not found"), reason)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("fallback.tap") },
                       "検証したアラートを閉じてはいけない: \(log.entries)")
    }

    /// `notExist("許可")` がアラートの上で赤になった回も閉じない
    /// (閉じてから判定し直すと、正しい赤を緑にすり替える)
    func testNotExistsOnTheAlertItselfFailsWithoutDismissing() async throws {
        let log = CallLog()
        let executor = makeExecutor(log: log)
        let step = FlowStep(assert: "notExists", locator: FlowLocator(label: "許可"), timeout: 0)

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else {
            return XCTFail("アラートが出ている間の notExist は失敗のまま: \(outcome.status)")
        }
        XCTAssertTrue(reason.contains("still exists"), reason)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("fallback.tap") },
                       "検証したアラートを閉じてはいけない: \(log.entries)")
    }
}
