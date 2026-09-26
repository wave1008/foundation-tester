// doctor の「管理外・古いブリッジ」の走査は `/status` に答えたポートしか見ていなかった。
// **ブリッジが死んで転送役(実機なら iproxy)だけがポートを握っている形**は答えないので
// 走査から丸ごと消え、採番範囲のポートを握ったままでも「✅ No unmanaged or stale bridges」と
// 報告していた(実地 2026-09-23 の負荷テスト: 画面ロックで死んだ実機のトンネル)。
//
// **候補はプロセスの実体で絞る**(`PortHolder.isHeldByTunnelOnly`)—— 応答の速さだけで決めると、
// 駆動中で /status に答えないだけの in-app ブリッジまで「固まり」として並ぶ。**トンネルだけ =
// 死んだではない**(USB 実機ブリッジは平常でもトンネルだけが握る)ので、候補は token 付きの
// `BridgeDiscovery.probeStatus` で確かめ、即切断のときだけ止め方を案内する。

import XCTest
@testable import fleetest

final class DoctorWedgedTransportReportTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/DoctorCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") ? "" : $0 }
            .joined(separator: "\n")
    }

    func testSilentPortsAreProbedAndOnlyWedgedOnesAreReported() throws {
        let code = try source()
        guard let scanRange = code.range(of: "BridgeLauncher.probeForeignBridge(") else {
            return XCTFail("管理外ブリッジの走査が見当たらない — テストを見直すこと")
        }
        // 答えなかったポートを捨てずに集めている
        guard let collectRange = code.range(of: "silentPorts.append(port)",
                                            range: scanRange.lowerBound..<code.endIndex) else {
            return XCTFail("応答しなかったポートを集めていない"
                + " —— 「答えない = 何も居ない」に倒すと固まった転送が永久に見えない")
        }
        guard let probeRange = code.range(of: "PortHolder.isHeldByTunnelOnly(port: port)",
                                          range: collectRange.upperBound..<code.endIndex) else {
            return XCTFail("集めたポートをプロセスの実体で判定していない"
                + " —— 応答の速さで決めると駆動中の in-app ブリッジまで並ぶ")
        }
        let reportBlock = String(code[probeRange.upperBound...].prefix(600))
        XCTAssertTrue(reportBlock.contains("BridgeDiscovery.probeStatus(port: port, repoRoot: root)"),
                      "トンネルだけのポートは token 付きの共有 probeStatus で確かめること"
                      + " —— USB 実機ブリッジは平常でもトンネルだけが握り、token 無しの探りには 401 で答える")
        XCTAssertTrue(reportBlock.contains("findings.append"),
                      "固まった転送を findings へ載せること(載せないと緑のまま)")
    }

    // MARK: - tunnelOnlyFinding(純粋関数)

    /// 生きた USB 実機ブリッジ(401 も answered)を「消えた」と言わない
    func testAnsweredTunnelIsHealthy() {
        XCTAssertNil(Doctor.tunnelOnlyFinding(port: 8126, probe: .answered))
        XCTAssertNil(Doctor.tunnelOnlyFinding(port: 8126, probe: .notBound))
    }

    func testDroppedTunnelSuggestsStoppingIt() throws {
        let finding = try XCTUnwrap(Doctor.tunnelOnlyFinding(port: 8126, probe: .transportFailed))
        XCTAssertTrue(finding.contains("fleetest bridge down --port 8126"), finding)
    }

    /// 時間切れは busy と区別できないので止め方を案内しない
    func testTimedOutTunnelDoesNotPrescribeStopping() throws {
        let finding = try XCTUnwrap(Doctor.tunnelOnlyFinding(port: 8126, probe: .timedOut))
        XCTAssertFalse(finding.contains("bridge down"), finding)
    }
}
