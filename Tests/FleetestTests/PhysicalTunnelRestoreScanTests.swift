import Foundation
import XCTest

/// 実機の USB トンネル(iproxy)だけが消えた生きたランナーを、作り直す前にトンネルの張り直しで戻すことを
/// ソース走査で縛る。作り直しは端末で UI 自動化の承認を求めうる(人が居ないと戻らない)のに、無応答の原因が
/// トンネルだけのときも「起動から N 秒答えない」と読んで作り直していた。経路は供給の引き取り(.adopt)と
/// ライブ操作の自動起動の2つ(どちらも、張り直しを飛ばすと同じポートのランナーを止めて起動し直す)
final class PhysicalTunnelRestoreScanTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// start〜end の間。どちらかが見つからなければ失敗させる(黙って空を返すと走査が素通りする)
    private func body(of text: String, from start: String, to end: String) throws -> Substring {
        guard let s = text.range(of: start),
              let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
            XCTFail("could not find \(start) … \(end) — the scan is broken")
            return ""
        }
        return text[s.upperBound..<e.lowerBound]
    }

    /// .adopt は起動の失敗とみなして作り直す判定(StartingRunnerVerdict)より前に張り直しを試し、
    /// 張り直した回はその判定を通さない
    func testAdoptRestoresTheTunnelBeforeTheRestartVerdict() throws {
        let text = try source("Sources/FTBridgeClient/BridgeProvisioner.swift")
        let adopt = try body(of: text, from: "taking over the starting", to: "case .launch(let port")
        guard let restore = adopt.range(of: "restoreMissingTunnel("),
              let verdict = adopt.range(of: "StartingRunnerVerdict.decide(") else {
            return XCTFail(".adopt no longer calls restoreMissingTunnel( before deciding to restart a physical runner")
        }
        XCTAssertLessThan(restore.lowerBound, verdict.lowerBound,
                          "the restart verdict runs before the tunnel is re-established")
        XCTAssertNotNil(adopt.range(of: "!tunnelRestored,"),
                        "a re-established tunnel still goes through the restart verdict (it reads the old silence)")
    }

    /// ライブ操作の自動起動は、他のセッションの印(作り直しを断る門)と startDetached(同じポートの
    /// ランナーを止める)より前に張り直しを試す。張り直しは相手のブリッジを止めないので印で断らない
    func testLiveAutoStartRestoresTheTunnelFirst() throws {
        let text = try source("Sources/fleetest/LiveBridgeAutoStarter.swift")
        let launch = try body(of: text, from: "private static func launchBridge(", to: "private func logStderr(")
        guard let restore = launch.range(of: "restoreMissingTunnel("),
              let lease = launch.range(of: "hasForeignLease("),
              let start = launch.range(of: "startDetached()") else {
            return XCTFail("launchBridge no longer calls restoreMissingTunnel( / hasForeignLease( / startDetached()")
        }
        XCTAssertLessThan(restore.lowerBound, lease.lowerBound,
                          "the foreign-lease gate refuses before the (non-destructive) tunnel restore is tried")
        XCTAssertLessThan(restore.lowerBound, start.lowerBound,
                          "startDetached (which stops the runner on the same port) runs before the tunnel restore")
        // ランナーの確認は排他を取った後(Codex 再レビュー)
        guard let acquire = launch.range(of: "await tunnelLock.acquire()"),
              let runnerCheck = launch.range(of: "runnersOnDevice(") else { return XCTFail("tunnel lock / runner check not found") }
        XCTAssertLessThan(acquire.lowerBound, runnerCheck.lowerBound)
    }

    /// 張り直しは establish を呼ばない(launcher.bridgeToken で .endpoint を上書きすると、生きたランナーへ
    /// 別の token で繋いで 401 になる)
    func testRestoreDoesNotOverwriteTheEndpointRecord() throws {
        let text = try source("Sources/FTBridgeClient/IOSDeviceTransport.swift")
        let restore = try body(of: text, from: "public static func restoreMissingTunnel(",
                               to: "public static func teardown(")
        XCTAssertNotNil(restore.range(of: "startIproxy("), "restoreMissingTunnel does not start iproxy")
        XCTAssertNil(restore.range(of: "establish("), "restoreMissingTunnel calls establish( — it overwrites the token")
        XCTAssertNil(restore.range(of: "persist("), "restoreMissingTunnel rewrites the endpoint record")
    }

    /// OCR の生死は CLI の doctor と MCP の ft_doctor の両方が実呼び出しで確かめる(片方だけだと、
    /// 同じ機械で一方は「使える」とだけ言う)。判定は RegionText.readerIsAlive の1箇所
    func testBothDoctorsProbeOCR() throws {
        for path in ["Sources/fleetest/DoctorCommand.swift", "Sources/fleetest-mcp/MCPServer+SessionTools.swift"] {
            XCTAssertNotNil(try source(path).range(of: "RegionText.readerIsAlive()"),
                            "\(path) does not probe OCR with RegionText.readerIsAlive()")
        }
    }

    /// MCP の udid の宛先解決も、「居ない」と言う前に張り直しを試す(実機・何も待ち受けていないときだけ)。
    /// 無いと生きたランナーに「no running bridge・bridge up しろ」と言い続ける(2026-10-15 の負荷テスト)
    func testMCPRestoresTheTunnelBeforeSayingNoBridge() throws {
        let text = try source("Sources/fleetest-mcp/MCPServer+Driver.swift")
        let resolve = try body(of: text, from: "static func portForIOS(", to: "static func nothingListensFor(")
        guard let restore = resolve.range(of: "restoreMissingPhysicalTunnel(udid: udid)"),
              let last = resolve.range(of: "udidPorts: udidPorts, diagnosis: diagnosis)", options: .backwards) else {
            return XCTFail("portForIOS no longer tries restoreMissingPhysicalTunnel before the no-bridge message")
        }
        XCTAssertLessThan(restore.lowerBound, last.lowerBound)
        XCTAssertNotNil(resolve.range(of: "diagnosis.lookup == .physical"), "the restore is not limited to physical devices")
        let helper = try body(of: text, from: "static func restoreMissingPhysicalTunnel(",
                              to: "static func classifyAnsweredPorts(")
        XCTAssertNotNil(helper.range(of: "restoreMissingTunnel("))
        XCTAssertNotNil(helper.range(of: "try ProvisionLock("), "the restore runs without the provisioning lock when it cannot be opened")
        // 排他は張り直しが終わるまで握る(予算で先に返すと、張り直しの途中で排他を手放す = Codex レビュー)
        guard let restoreCall = helper.range(of: "restoreMissingTunnel("),
              let release = helper.range(of: "lock.release()") else { return XCTFail("restore or release not found") }
        XCTAssertLessThan(restoreCall.lowerBound, release.lowerBound)
        XCTAssertNotNil(helper.range(of: "runOffCooperativePool("), "the restore must be awaited to completion, not budgeted")
        XCTAssertNil(helper.range(of: "budgeted(Self.udidBridgeDiagnosisBudget, fallback: false)"), "a budget lets the lock go before the restore ends")
        // 接続方式は起動した側の記録から(devicectl の照会の失敗を「USB ではない」に畳まない)
        XCTAssertNotNil(helper.range(of: "BridgeEndpoint.recorded("))
        // 宛先(ランナーのポート・記録)は排他を取った後に確かめる(待つ間に別の実機へ割り当て直される = Codex 再レビュー)
        guard let acquire = helper.range(of: "await lock.acquire()"),
              let runnerCheck = helper.range(of: "runnersOnDevice("),
              let recordCheck = helper.range(of: "BridgeEndpoint.recorded(") else { return XCTFail("lock / checks not found") }
        XCTAssertLessThan(acquire.lowerBound, runnerCheck.lowerBound)
        XCTAssertLessThan(acquire.lowerBound, recordCheck.lowerBound)
    }
}
