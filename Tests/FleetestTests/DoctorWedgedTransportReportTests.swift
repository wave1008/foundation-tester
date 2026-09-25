// doctor の「管理外・古いブリッジ」の走査は `/status` に答えたポートしか見ていなかった。
// **ブリッジが死んで転送役(実機なら iproxy)だけがポートを握っている形**は答えないので
// 走査から丸ごと消え、採番範囲のポートを握ったままでも「✅ No unmanaged or stale bridges」と
// 報告していた(実地 2026-09-23 の負荷テスト: 画面ロックで死んだ実機のトンネル)。
//
// **判定はプロセスの実体で行う**(`PortHolder.isHeldByTunnelOnly`)—— 応答の速さ(`probeStatus`)で
// 決めると、駆動中で /status に答えないだけの in-app ブリッジまで「固まり」として並ぶ
// (実測: run の最中に 8 ポートが誤って報告された)。

import XCTest

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
        let reportBlock = String(code[probeRange.upperBound...].prefix(400))
        XCTAssertTrue(reportBlock.contains("findings.append"),
                      "固まった転送を findings へ載せること(載せないと緑のまま)")
        XCTAssertTrue(reportBlock.contains("fleetest bridge down --port"),
                      "次の一手(止め方)を添えること")
    }
}
