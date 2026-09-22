// MCP の xcuitest ブリッジ自動復帰(B1)の配線をソース走査で固定する。判定そのものは
// BridgeRecoveryDecisionTests(純粋関数)が固定するので、ここは「呼ばれているか」「二つ目の
// 実装を書いていないか」「成功と失敗で bridgeRecoveryFailed の扱いが割れているか」だけを見る。

import XCTest

final class BridgeRecoveryWiringTests: XCTestCase {

    private func source() throws -> String {
        try MCPServerSourceText.combined()
    }

    /// call() は生の dispatch(tool:args:) ではなく、建て直し込みのラッパーを撃つこと
    /// (直に dispatch を呼ぶと bridgeConnectionRefused から一度も復帰しない)
    func testCallGoesThroughTheRecoveringDispatchWrapper() throws {
        let code = try source()
        XCTAssertTrue(code.contains("try await dispatchRetryingAfterBridgeRecovery(tool: tool, args: resolved)"),
                      "call() は dispatchRetryingAfterBridgeRecovery を撃つこと")
    }

    /// ラッパー自身は dispatch を直接呼ぶ(二つ目の実装を書かない)
    func testWrapperDelegatesToDispatchAndRetriesOnce() throws {
        let code = try source()
        guard let range = code.range(of: "func dispatchRetryingAfterBridgeRecovery(") else {
            return XCTFail("dispatchRetryingAfterBridgeRecovery が見当たらない")
        }
        let body = String(code[range.lowerBound...].prefix(600))
        XCTAssertEqual(body.components(separatedBy: "try await dispatch(tool: tool, args: args)").count - 1, 2,
                       "dispatch を撃つのは最初の1回と、建て直せたときの1回だけであること")
        XCTAssertTrue(body.contains("attemptXCUITestBridgeRecovery("),
                      "リトライの可否は attemptXCUITestBridgeRecovery に判定させること")
    }

    /// 判定(gating)は共有の純粋関数を通すこと——条件を実行関数へ複製しない
    func testExecutionFunctionsDelegateToTheSharedPureGates() throws {
        let code = try source()
        XCTAssertTrue(code.contains("Self.shouldAttemptXCUITestBridgeRecovery("),
                      "attemptXCUITestBridgeRecovery は shouldAttemptXCUITestBridgeRecovery を通すこと")
        XCTAssertTrue(code.contains("Self.shouldAttemptXCUITestRunnerRecheck("),
                      "recheckXCUITestRunnerIfSlow は shouldAttemptXCUITestRunnerRecheck を通すこと")
    }

    /// 建て直しは BridgeProvisioner.provision の1箇所(bridge up / run の供給と同じ経路)。
    /// 測り直しは BridgeProvisioner.recheckRunner(run の RunnerMidRunRecheck と同じ経路)
    func testRebuildAndRecheckDelegateToBridgeProvisioner() throws {
        let code = try source()
        XCTAssertTrue(code.contains(".provision(devices: [(udid, spec)], log: Self.logStderr)"),
                      "建て直しは BridgeProvisioner.provision を呼ぶこと(二つ目の実装を書かない)")
        XCTAssertTrue(code.contains("BridgeProvisioner(repoRoot: repoRoot).recheckRunner("),
                      "測り直しは BridgeProvisioner.recheckRunner を呼ぶこと(run 側と同じ経路)")
    }

    /// 成功時は bridgeRecoveryFailed へ insert しない(次に死んだらまた試してよい)。
    /// 失敗時だけ insert する(このセッションでは再挑戦しない)
    func testOnlyFailureMarksTheEngineKeyAsGivenUp() throws {
        let code = try source()
        guard let range = code.range(of: "func attemptXCUITestBridgeRecovery(") else {
            return XCTFail("attemptXCUITestBridgeRecovery が見当たらない")
        }
        let body = String(code[range.lowerBound...].prefix(1600))
        guard let successRange = body.range(of: "return true"),
              let failureRange = body.range(of: "bridgeRecoveryFailed.insert(key)") else {
            return XCTFail("成功/失敗の分岐が見当たらない — テストを見直すこと")
        }
        XCTAssertTrue(successRange.lowerBound < failureRange.lowerBound,
                      "insert は catch(失敗)側にあり、成功の return より後に書かれていること")
        // 成功の return の直前(catch より手前)に insert が無いこと
        let beforeSuccess = String(body[body.startIndex..<successRange.lowerBound])
        XCTAssertFalse(beforeSuccess.contains("bridgeRecoveryFailed.insert(key)"),
                       "成功時に bridgeRecoveryFailed へ insert しないこと")
    }

    /// 実機は provision() の対象外(SimulatorCatalog.isPhysical で確かめてから撃つ)
    func testRefusesToRebuildPhysicalDevices() throws {
        let code = try source()
        XCTAssertTrue(code.contains("isPhysical: SimulatorCatalog.isPhysical(udid: udid)"),
                      "実機かどうかを確かめてから建て直し/測り直しの可否を判定すること")
    }
    /// **建て直しは結果本文で言う** —— stderr だけだと JSON-RPC しか読まない呼び手に届かない
    /// (2026-09-21 T1 の「唯一の警告が stderr」と同じ型)。ref が消えたことも本文でしか伝わらない
    func testTheRebuildIsAnnouncedInTheResultBody() throws {
        let code = try source()
        XCTAssertTrue(code.contains("[[\"type\": \"text\", \"text\": Self.bridgeRebuiltNote]] + content"),
                      "建て直したあとの結果に注記を前置していない(呼び手には stderr が届かない)")
        XCTAssertTrue(code.contains("take a fresh one"),
                      "ref が無効になったことを言っていない(建て直し = アプリの再起動)")
    }
}
