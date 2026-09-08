import XCTest
@testable import FTCore

/// [SlowSnapshotBudget 配線] StepExecutor+Assert.swift の8ループが、期限切れ後の追加 snapshot を
/// 実際に SlowSnapshotBudget でゲートしていることを、enabled/disabled アサーション1本で固定する
/// (occlusion-guard も firstFrameExtended も絡まない一番単純な経路)。
final class SlowSnapshotRetakeGateTests: XCTestCase {
    /// enabled が期待と逆の要素(見つかりはするが一致しない)を用意し、期限切れ後の
    /// 取り直しが起きるかどうかを primary.bypassedSnapshotCount で観測する
    private func mismatchedEnabledElement() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "target", label: nil, value: nil,
                   placeholder: nil, enabled: false,
                   frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    /// commandTimeoutSeconds を小さく(50ms)固定し、snapshotDelay(200ms)を大きく取ることで、
    /// 「ゲートされる/されない」をタイミング競合なしに大きなマージンで判定する
    func testGateBlocksRetakeWhenBudgetIsExhausted() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[mismatchedEnabledElement()]])
        primary.bypassSupported = true
        primary.snapshotDelay = .milliseconds(200)
        let executor = StepExecutor(driver: primary, isAndroid: false, commandTimeoutSeconds: 0.05)
        let step = FlowStep(assert: "enabled", locator: FlowLocator(id: "target"), timeout: 0)

        let outcome = await executor.execute(step)
        guard case .failed = outcome.status else {
            XCTFail("enabled が一致しないので失敗のはず: \(outcome.status)"); return
        }
        XCTAssertEqual(primary.bypassedSnapshotCount, 0,
                       "外枠(50ms)に対して直前の snapshot(200ms)が大きすぎるので取り直しは撃たれない")
        XCTAssertTrue(outcome.notes.contains(.slowSnapshot),
                      "snapshot 所要(200ms)がこのステップの待ち予算(timeout=0)を超えたら立つ")
    }

    /// 外枠を持たない呼び出し元(commandTimeoutSeconds: nil)は従来どおり1回だけ取り直す
    func testNoCommandTimeoutRetakesOnceAsBefore() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log,
                                    snapshotElements: [[mismatchedEnabledElement()]])
        primary.bypassSupported = true
        primary.snapshotDelay = .milliseconds(200)
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(assert: "enabled", locator: FlowLocator(id: "target"), timeout: 0)

        let outcome = await executor.execute(step)
        guard case .failed = outcome.status else {
            XCTFail("enabled が一致しないので失敗のはず: \(outcome.status)"); return
        }
        XCTAssertEqual(primary.bypassedSnapshotCount, 1,
                       "外枠が無ければ AssertFreshRetry の予算どおり1回だけ取り直す(従来どおり)")
    }
}
