// ft_logs が実機宛てのときに CrashLogs.text の待ちを飛ばすための配線(件3)。
//
// CrashLogsTests は CrashLogs.text(physicalUDID:) 自体の分岐を直接検証するが、
// MCPServer+SessionTools の ftLogs が実際に physicalUDID を解決して渡しているかは
// ソース走査でしか固定できない —— ft_logs はホストのファイル走査(DiagnosticReports)/
// adb を伴うため、server.call を通した統合テストの対象から意図的に外れている
// (MCPToolCallTests.hostBackedTools 参照)。

import XCTest
@testable import fleetest_mcp

final class MCPLogsPhysicalDeviceWiringTests: XCTestCase {

    private static func logsCaseBody() throws -> String {
        let source = try MCPServerSourceText.combined()
        let start = try XCTUnwrap(source.range(of: "func ftLogs("),
                                  "ft_logs の実装が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "func ftInstall("), "次の関数が見つからない")
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

    /// **udid を毎回添える呼び手**(複数台を駆動する標準の呼び方)でも実機と分かること。
    /// 入口は ft_logs の udid を畳まないので、ここで記憶のポートへ揃えないと鍵が `direct:ios:0:` になり、
    /// 駆動中の実機でもシミュレータの待ち(≒4.2秒)+「クラッシュ無し」に落ちる(2026-09-30 実機で実測)
    func testFtLogsResolvesANamedUDIDFromSessionMemory() throws {
        let body = try Self.logsCaseBody()
        XCTAssertTrue(compact(body).contains(compact("rememberedPort(forUDID: logsUDID)")),
                     "udid 指定の ft_logs がセッションの記憶を引いていない")
        XCTAssertTrue(compact(body).contains(compact("Self.logsPhysicalUDID(udid: logsUDID,")),
                     "udid 指定が実機判定へ渡っていない")
        XCTAssertFalse(MCPServer.toolFoldsUDID("ft_logs"), "ft_logs の udid を入口で畳むと、死んだブリッジの後に読めない")
    }

    /// 実機判定の4形。**ポートの記録が別の実機のものなら採らない**(ポートは使い回される)
    func testLogsPhysicalUDIDDecision() {
        let se3 = "00008110-000260242EEB801E"
        let other = "00008110-001460910E0A201E"
        // udid なし: ポートの記録がそのまま答え
        XCTAssertEqual(MCPServer.logsPhysicalUDID(udid: nil, recordAtPort: se3) { _ in false }, se3)
        XCTAssertNil(MCPServer.logsPhysicalUDID(udid: nil, recordAtPort: nil) { _ in true })
        // udid あり: ポートの記録が一致
        XCTAssertEqual(MCPServer.logsPhysicalUDID(udid: se3, recordAtPort: se3) { _ in false }, se3)
        // udid あり: ポートは分からないが、どこかのポートに実機として記録がある
        XCTAssertEqual(MCPServer.logsPhysicalUDID(udid: se3, recordAtPort: nil) { $0 == se3 }, se3)
        // udid あり: ポートの記録は別の実機・その udid の記録はどこにも無い = 実機とは言えない
        XCTAssertNil(MCPServer.logsPhysicalUDID(udid: se3, recordAtPort: other) { _ in false })
        XCTAssertNil(MCPServer.logsPhysicalUDID(udid: se3, recordAtPort: nil) { _ in false })
    }

    /// 実機判定は iOS 限定(Android は実機/仮想の区別が要らない)。手掛かりが無ければ nil を渡し、
    /// 「実機でない証拠にはならない」ので従来どおり待つ側へ倒す(best-effort)
    func testFtLogsGatesThePhysicalLookupToIOS() throws {
        let body = try Self.logsCaseBody()
        XCTAssertTrue(compact(body).contains(compact("Self.platformName(args) == \"ios\"")),
                     "実機判定が iOS 限定になっていない")
    }
}
