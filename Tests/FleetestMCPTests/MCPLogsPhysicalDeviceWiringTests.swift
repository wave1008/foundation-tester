// ft_logs が実機宛てのときに CrashLogs.text の待ちを飛ばすための配線(件3)。
//
// CrashLogsTests は CrashLogs.text(physicalUDID:) 自体の分岐を直接検証するが、
// MCPServer+Dispatch の ft_logs ケースが実際に physicalUDID を解決して渡しているかは
// ソース走査でしか固定できない —— ft_logs はホストのファイル走査(DiagnosticReports)/
// adb を伴うため、server.call を通した統合テストの対象から意図的に外れている
// (MCPToolCallTests.hostBackedTools 参照)。

import XCTest
@testable import fleetest_mcp

final class MCPLogsPhysicalDeviceWiringTests: XCTestCase {

    private static func logsCaseBody() throws -> String {
        let source = try MCPServerSourceText.combined()
        let start = try XCTUnwrap(source.range(of: "case \"ft_logs\":"),
                                  "ft_logs の分岐が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "case \"ft_install\":"), "次の case が見つからない")
        return String(tail[..<end.lowerBound])
    }

    /// 空白と改行を落とした形で照合する(KeyboardOcclusionWiringTests.compact と同じ理由:
    /// 引数の改行位置で普通の折り返しがリテラル照合を落とす実績がある)
    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// **唯一のブリッジ非依存な実機の手掛かり**は BridgeDeviceRecord(実機のときだけ書かれる
    /// `.fleetest/bridge-<port>.device`)。これを引かずに CrashLogs.text へ渡すと、
    /// 実機宛てでも常にシミュレータの待ち(≒4.2秒)を払ってから「実機は読めない」と答える
    func testFtLogsResolvesPhysicalUDIDFromTheBridgeDeviceRecord() throws {
        let body = try Self.logsCaseBody()
        XCTAssertTrue(compact(body).contains(compact("BridgeDeviceRecord.load(port: port, repoRoot:")),
                     "ft_logs が BridgeDeviceRecord を引いていない —— 実機宛てでも常に待つ")
        XCTAssertTrue(compact(body).contains(compact("physicalUDID: logsPhysicalUDID")),
                     "解決した physicalUDID が CrashLogs.text へ渡っていない")
    }

    /// **ft_logs はブリッジに問い合わせない**(CrashLogs.swift の doc: ブリッジごと落ちた直後に
    /// 使う道具)。`driver(args)` を撃つと、まさにその落ちた直後のセッションで先に失敗し、
    /// クラッシュの手掛かりを読む前に道具自体が使えなくなる
    func testFtLogsNeverCallsTheBridgeDriver() throws {
        let body = try Self.logsCaseBody()
        XCTAssertFalse(body.contains("driver(args)"),
                       "ft_logs がブリッジ(driver())へ問い合わせている —— 落ちた直後に使えなくなる")
    }

    /// 実機判定は iOS 限定(Android は実機/仮想の区別が要らない)。手掛かりが無ければ nil を渡し、
    /// 「実機でない証拠にはならない」ので従来どおり待つ側へ倒す(best-effort)
    func testFtLogsGatesThePhysicalLookupToIOS() throws {
        let body = try Self.logsCaseBody()
        XCTAssertTrue(compact(body).contains(compact("Self.platformName(args) == \"ios\"")),
                     "実機判定が iOS 限定になっていない")
    }
}
