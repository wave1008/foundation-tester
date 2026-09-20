// 建て直しても直らなかった XCUITest ランナーが run をまたいで放置される問題への対処(2026-09-20)。
//
// リース判定(hasForeignLease の I/O 版)は実ファイルで固める(デバイス不要)。
// 実際に供給の入口(BridgeProvisioner.executeBridge の .reuse 分岐)がこの判定を通ることと、
// 建て直しの結果を RunnerSlownessStore へ持ち越すことは、供給そのものが実デバイスを要求するため
// テストから通せない —— ソース走査で固定する(BridgeProvisionerFailureLogTests と同じ規律)。

import XCTest
@testable import FTBridgeClient

final class RunnerSlownessLeaseIOTests: XCTestCase {
    private var stateDir: URL!
    private var livePID: Int32 { ProcessInfo.processInfo.processIdentifier }

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-runner-slowness-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    func testNoLeaseFilesIsNotForeign() {
        XCTAssertFalse(RunnerAccessibilityHealth.hasForeignLease(udid: "udid-a", stateDir: stateDir))
    }

    /// 自分自身が書いた run-lease は「使用中」に数えない(selfPID を実際の書き手と揃える)
    func testOwnLeaseFileIsNotForeign() {
        RunLease.write(stateDir: stateDir, key: "udid-a", pid: livePID)
        XCTAssertFalse(RunnerAccessibilityHealth.hasForeignLease(
            udid: "udid-a", stateDir: stateDir, selfPID: livePID, parentPID: 1))
    }

    /// **変異②「lease がある台を除外しない」の陽性対照(I/O 版)**: 生きた他プロセスの run-lease は
    /// foreign(selfPID を書き手と別にずらして「他人」を模す)
    func testForeignRunLeaseFileIsForeign() {
        RunLease.write(stateDir: stateDir, key: "udid-a", pid: livePID)
        XCTAssertTrue(RunnerAccessibilityHealth.hasForeignLease(
            udid: "udid-a", stateDir: stateDir, selfPID: livePID + 1, parentPID: 1))
    }

    /// MCP の印も同じく foreign
    func testMCPLeaseFileIsForeign() {
        MCPDeviceLease.write(stateDir: stateDir, key: "udid-a", pid: livePID)
        XCTAssertTrue(RunnerAccessibilityHealth.hasForeignLease(
            udid: "udid-a", stateDir: stateDir, selfPID: livePID + 1, parentPID: 1))
    }

    /// 死んだ(存在しない)pid の lease ファイルは無視する(RunLease/MCPDeviceLease 自体の生存判定に委ねる)
    func testDeadHolderIsNotForeign() {
        RunLease.write(stateDir: stateDir, key: "udid-a", pid: 2_000_000)
        XCTAssertFalse(RunnerAccessibilityHealth.hasForeignLease(
            udid: "udid-a", stateDir: stateDir, selfPID: livePID, parentPID: 1))
    }
}

/// 配線(供給の入口で実際にこの判定を通ること)はソース走査で固定する
/// (`BridgeProvisionerFailureLogTests` と同じ規律。供給そのものは実デバイスを要求するため
/// テストから通せない)。
final class RunnerSlownessProvisioningWiringTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
            .appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// **供給の入口(.reuse の xcuitest 分岐)が、通常のプローブより先に run をまたいだ印を読むこと**。
    /// 印が消えると、毎 run 同じ建て直しの空振りを繰り返す旧挙動に戻る
    func testReuseBranchReadsThePersistedMarkBeforeProbing() throws {
        let text = compact(try source())
        let markReadIndex = try XCTUnwrap(text.range(of: compact(
            "let persisted = RunnerSlownessStore.current(stateDir: fleetestStateDir, key: sim.udid)")))
        // **markReadIndex より後だけを探す**(「let probeSeconds = injected」は recheckRunner にも
        // 同じ文言があり、ファイル中の最初の一致が正しいとは限らないため)。見つからなければ
        // XCTUnwrap が落ちる = 順序が入れ替わった(または消えた)ことを検出する
        let probeIndex = try XCTUnwrap(text.range(
            of: compact("let probeSeconds = injected"), range: markReadIndex.upperBound..<text.endIndex))
        XCTAssertTrue(markReadIndex.upperBound <= probeIndex.lowerBound,
                      "印は通常の 1 問プローブより先に読まれていなければならない")
    }

    /// **変異②「lease がある台を除外しない」の陽性対照(配線側)**: 次に何をするかは
    /// hasForeignLease(実ファイルを読む I/O 版)の結果から決めている(定数へすり替えられていない)
    func testSupplyActionIsBuiltFromTheRealForeignLeaseCheck() throws {
        let text = compact(try source())
        XCTAssertTrue(text.contains(compact(
            "RunnerAccessibilityHealth.supplySlownessAction(persisted: persisted,"
            + " hasForeignLease: RunnerAccessibilityHealth.hasForeignLease("
            + "udid: sim.udid, stateDir: fleetestStateDir))")))
    }

    /// リースのある台には触らない(.restartSimulator のときだけシミュレータを再起動する)。
    /// reuseWithoutRestarting はシミュレータへ何もしない経路であることをケース名で確かめる
    func testOnlyRestartSimulatorCaseTouchesTheSimulator() throws {
        let text = compact(try source())
        XCTAssertTrue(text.contains(compact("case .restartSimulator:")))
        XCTAssertTrue(text.contains(compact(
            "let result = try await restartSimulatorAndRunner(name: name, sim: sim, port: port,")))
        XCTAssertTrue(text.contains(compact("case .reuseWithoutRestarting:")))
    }

    /// **変異①「印が永続しない」の陽性対照(配線側)**: 建て直しても直らなかったという事実は
    /// プロセス内の RunnerRestartFutility だけでなく RunnerSlownessStore へも書かれる
    /// (restartRunner の劣化ブランチに両方の呼び出しが並ぶ)
    func testRestartRunnerPersistsTheFutilityMarkAlongsideTheInProcessOne() throws {
        let text = compact(try source())
        XCTAssertTrue(text.contains(compact(
            "RunnerRestartFutility.shared.mark(udid: sim.udid)"
            + "RunnerSlownessStore.mark(stateDir: fleetestStateDir, key: sim.udid,"
            + " state: .runnerRestartDidNotHelp)")))
    }

    /// **効いたかを直後に測る**(CLAUDE.md の規律): シミュレータ再起動の結果で印を消す/更新する分岐が
    /// どちらも存在する(健全なら clear、まだ遅ければ simulatorRestartDidNotHelp へ更新)
    func testSimulatorRestartOutcomeClearsOrEscalatesTheMark() throws {
        let text = compact(try source())
        XCTAssertTrue(text.contains(compact(
            "RunnerSlownessStore.clear(stateDir: fleetestStateDir, key: sim.udid)")))
        XCTAssertTrue(text.contains(compact(
            "RunnerSlownessStore.mark(stateDir: fleetestStateDir, key: sim.udid,"
            + " state: .simulatorRestartDidNotHelp)")))
    }
}
