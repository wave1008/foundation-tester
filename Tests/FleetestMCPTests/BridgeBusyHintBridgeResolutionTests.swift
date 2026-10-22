// 実測 2026-09-07: 固着した in-app ブリッジ(TCP は bound だが HTTP 無応答)への最初の呼び出しは
// bridges[key] を一度も埋めないまま失敗するので、bridgeBusyHint に bridge: nil が渡り、
// 常に XCUITest 向けの「busy・Retry」文言が出ていた(MCP が同じプロセスで直前に "inapp" と
// 列挙していても)。resolvedBridge がディスクの台帳(`.fleetest/bridge-<port>.inapp`)から
// 引き直すフォールバックを固定する。

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class BridgeBusyHintBridgeResolutionTests: XCTestCase {

    func testResolvedBridgeReturnsKnownValueWithoutTouchingDisk() {
        // 台帳が無い/repoRoot が nil でも known が優先される = ディスクを見に行かない
        XCTAssertEqual(
            MCPServer.resolvedBridge(known: "xcuitest", port: 8139, repoRoot: nil), "xcuitest")
    }

    func testResolvedBridgeIsNilWithoutRepoRootWhenUnknown() {
        XCTAssertNil(MCPServer.resolvedBridge(known: nil, port: 8139, repoRoot: nil))
    }

    func testResolvedBridgeIsNilWhenLedgerHasNoInAppRecordForThatPort() throws {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-resolved-bridge-absent-\(UUID().uuidString)")
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        XCTAssertNil(MCPServer.resolvedBridge(known: nil, port: 8139, repoRoot: repoRoot))
    }

    func testResolvedBridgeReadsInAppFromDiskWhenUnknown() throws {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-resolved-bridge-inapp-\(UUID().uuidString)")
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        InAppBridgeState.write(
            stateDir: stateDir, port: 8139, udid: "ABCD-1234", bundleID: "com.example.app")

        XCTAssertEqual(MCPServer.resolvedBridge(known: nil, port: 8139, repoRoot: repoRoot), "inapp")
    }

    /// 実害の固定: 台帳から引き直した bridge が bridgeBusyHint へ渡ると、固着した in-app
    /// ブリッジに対して「Retry the call」を永遠に勧める誤誘導が止む
    func testBridgeBusyHintUsesResolvedBridgeToAvoidRetryAdviceForStuckInAppBridge() throws {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-resolved-bridge-hint-\(UUID().uuidString)")
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        InAppBridgeState.write(
            stateDir: stateDir, port: 8139, udid: "ABCD-1234", bundleID: "com.example.app")

        let resolved = MCPServer.resolvedBridge(known: nil, port: 8139, repoRoot: repoRoot)
        let hint = MCPServer.bridgeBusyHint(connection: "port 8139", bridge: resolved, mayHaveTakenEffect: false)

        XCTAssertTrue(hint.contains("foreground"), hint)
        XCTAssertTrue(hint.contains("ft_launch"), hint)
        XCTAssertFalse(hint.contains("Retry the call"), hint)
    }

    /// 台帳に印が無ければ従来どおり XCUITest 向けの文面のまま(判断材料が無いときに
    /// in-app と決めつけない側の既定)
    func testBridgeBusyHintKeepsXCUITestWordingWhenLedgerHasNoRecord() throws {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-resolved-bridge-nomark-\(UUID().uuidString)")
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let resolved = MCPServer.resolvedBridge(known: nil, port: 8139, repoRoot: repoRoot)
        let hint = MCPServer.bridgeBusyHint(connection: "port 8139", bridge: resolved, mayHaveTakenEffect: false)

        XCTAssertTrue(hint.contains("still bound"), hint)
        XCTAssertTrue(hint.contains("Retry the call"), hint)
    }
}
