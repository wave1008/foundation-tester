// 2026-09-22 の負荷テストで実機 iPhone SE3 が実際に踏んだ欠陥: 画面ロックでブリッジ
// (XCUITest ランナー)が死んだ後も iproxy がポートの LISTEN を握ったままになり、MCP の全ツールが
// 「busy かもしれない・少し待って撃ち直せ」を10分以上返し続けた。
//
// 実測(同じ Mac で `/status` を1回ずつ撃った結果): 健全なブリッジは HTTP 応答が返る(200/401 とも)。
// **固まったブリッジ(iproxy だけ残存)は TCP connect は通るが、HTTP 応答が1バイトも返らないまま
// タイムアウトよりはるかに早く(~2.5ms)転送が切れる**。本当に busy な XCUITest は応答をタイムアウト
// 上限まで保持する。この「所要時間で分かれる」事実を `BridgeDiscovery.probeStatus`(純粋な部分は
// `classifyNoResponse` に切り出す)で拾い、「busy」と「wedged(転送だけ残っている)」を別の文言・
// 別の対処(wedged は `bridge up` を積極的に勧める)に分けた。
//
// ここでは: ①境界を決める純粋関数(実ソケット無し)②2つの文言(busy とは言わない・出口がある)
// ③配線(busy 判定へ probe を経由すること)をソース走査で固定する。

import XCTest
import Foundation
import FTCore
@testable import FTBridgeClient
@testable import fleetest_mcp

final class BridgeWedgedTransportTests: XCTestCase {

    // MARK: - BridgeDiscovery.classifyNoResponse(境界の両側。実ソケットは使わない)

    /// 境界の比率をリテラルで固定する。変異(数字を動かす)で落ちる契約
    func testTransportFailureFractionIsOneHalf() {
        XCTAssertEqual(BridgeDiscovery.transportFailureFraction, 0.5)
    }

    /// 実測(~2.5ms)そのものを与えると transportFailed —— タイムアウト窓(2秒)に対して
    /// 桁違いに早い
    func testClassifyNoResponseTreatsTheMeasuredWedgeLatencyAsTransportFailed() {
        XCTAssertEqual(
            BridgeDiscovery.classifyNoResponse(elapsedMs: 3, timeoutSeconds: 2), .transportFailed)
    }

    /// 上限のすぐ手前まで無応答を保持していれば timedOut(本当に busy)
    func testClassifyNoResponseTreatsNearFullTimeoutAsTimedOut() {
        XCTAssertEqual(
            BridgeDiscovery.classifyNoResponse(elapsedMs: 1_900, timeoutSeconds: 2), .timedOut)
    }

    /// 境界ちょうど(上限の半分)は timedOut 側に倒す(`<` の狭義比較。busy 側を誤って
    /// transportFailed と言わない安全側)
    func testClassifyNoResponseAtExactBoundaryIsTimedOut() {
        XCTAssertEqual(
            BridgeDiscovery.classifyNoResponse(elapsedMs: 1_000, timeoutSeconds: 2), .timedOut)
    }

    /// 境界のすぐ内側は transportFailed(両方向を掛ける。CLAUDE.md「検知の類は両方向に掛ける」)
    func testClassifyNoResponseJustBelowBoundaryIsTransportFailed() {
        XCTAssertEqual(
            BridgeDiscovery.classifyNoResponse(elapsedMs: 999, timeoutSeconds: 2), .transportFailed)
    }

    // MARK: - MCPServer.bridgeWedgedOnUDIDMessage(udid 解決の入口。busy とは言わない)

    /// 文言を等号で固定する(部分一致だけだと「busy と言わない」変異を見逃す)
    func testBridgeWedgedOnUDIDMessageExactWording() {
        let text = MCPServer.bridgeWedgedOnUDIDMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil, lookup: .simulator,
                             wedgedPorts: [8130]))
        XCTAssertEqual(text, "a bridge for udid SIM-1234 is listening on port 8130, but the"
            + " connection to /status fails almost immediately instead of timing out — the bridge"
            + " process is gone; only its transport (on a physical device, iproxy) is still holding"
            + " the port. This will not recover on its own. On a physical device, this typically"
            + " follows the screen locking, or the device leaving USB/network range."
            + " start it with `fleetest bridge up --device \"SIM-1234\"`")
    }

    /// **「busy」とは言わない**(busy 側の bridgeBusyOnUDIDMessage と事実が違うため)
    func testBridgeWedgedOnUDIDMessageNeverSaysBusy() {
        let text = MCPServer.bridgeWedgedOnUDIDMessage(
            udid: "U1",
            diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil, lookup: .notFound,
                             wedgedPorts: [8140]))
        XCTAssertFalse(text.lowercased().contains("busy"), text)
    }

    /// 実機を screen lock で説明する(実測の典型)
    func testBridgeWedgedOnUDIDMessageMentionsScreenLocking() {
        let text = MCPServer.bridgeWedgedOnUDIDMessage(
            udid: "U1",
            diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil, lookup: .notFound,
                             wedgedPorts: [8140]))
        XCTAssertTrue(text.contains("screen locking"), text)
    }

    /// **busy 側と違い `bridge up` を積極的に勧める**(完成コマンド付き。実機は `--physical`)
    func testBridgeWedgedOnUDIDMessageRecommendsBridgeUpWithPhysicalFlag() {
        let text = MCPServer.bridgeWedgedOnUDIDMessage(
            udid: "00008110-000260242EEB801E",
            diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil, lookup: .physical,
                             wedgedPorts: [8152]))
        XCTAssertTrue(
            text.contains("fleetest bridge up --device \"00008110-000260242EEB801E\" --physical"),
            text)
    }

    /// run が使用中と分かっているときはその pid を添える(busy 側と同じ規律)
    func testBridgeWedgedOnUDIDMessageNamesTheHoldingRunWhenKnown() {
        let text = MCPServer.bridgeWedgedOnUDIDMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: 4242, lookup: .simulator,
                             wedgedPorts: [8130]))
        XCTAssertTrue(text.contains("fleetest run (pid 4242)"), text)
        XCTAssertTrue(text.contains("is using this device right now"), text)
    }

    // MARK: - MCPServer.noResponsiveBridgeMessage(wedged を busy より先に見る)

    /// wedgedPorts が非空なら wedged の文面(「no running bridge」でも busy でもない)
    func testNoResponsiveBridgeMessageDispatchesToWedgedWhenWedgedPortsPresent() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil, lookup: .simulator,
                             wedgedPorts: [8130]))
        XCTAssertFalse(text.contains("no running bridge"), text)
        XCTAssertFalse(text.lowercased().contains("busy"), text)
        XCTAssertTrue(text.contains("port 8130"), text)
    }

    /// diagnosis を省略した既存呼び出しは従来どおり「no running bridge」のまま(後方互換)
    func testNoResponsiveBridgeMessageDefaultsToGoneMessageWithoutDiagnosis() {
        let text = MCPServer.noResponsiveBridgeMessage(udid: "U1", diagnosis: .unknown)
        XCTAssertTrue(text.contains("no running bridge is on udid U1"), text)
    }

    // MARK: - MCPServer.bridgeWedgedHint(--port 明示の再接続経路)

    func testBridgeWedgedHintExactWording() {
        let text = MCPServer.bridgeWedgedHint(connection: "port 8152")
        XCTAssertEqual(text, "\nThe bridge behind port 8152 is not answering, and the connection"
            + " failed almost immediately rather than timing out — the bridge process is gone; only"
            + " its transport (on a physical device, iproxy) is still holding the port. This will not"
            + " recover on its own (a physical device typically loses its bridge this way when the"
            + " screen locks, or the device leaves USB/network range). Rebuild it with"
            + " `fleetest bridge up`, then ft_launch your app again.")
    }

    func testBridgeWedgedHintNeverSaysBusy() {
        let text = MCPServer.bridgeWedgedHint(connection: "port 8152")
        XCTAssertFalse(text.lowercased().contains("busy"), text)
        XCTAssertTrue(text.contains("fleetest bridge up"), text)
    }

    /// **bridgeBusyHint とは事実が違う文面**(所要時間で分けた根拠を busy 側と混ぜない)
    func testBridgeWedgedHintDiffersFromBridgeBusyHint() {
        let busy = MCPServer.bridgeBusyHint(connection: "port 8152", engine: "xcuitest")
        let wedged = MCPServer.bridgeWedgedHint(connection: "port 8152")
        XCTAssertNotEqual(busy, wedged)
        XCTAssertTrue(busy.lowercased().contains("busy"), busy)
        XCTAssertFalse(wedged.lowercased().contains("busy"), wedged)
    }

    // MARK: - 配線(ソース走査): busy 判定が probe を経由し、wedged を先に見ること

    /// `iosConnectionLostHint` の `.busy` 分岐が `BridgeDiscovery.probeStatus` で
    /// busy/wedged を分けてから `bridgeWedgedHint`/`bridgeBusyHint` へ回すこと。
    /// 走査を省いて `bound` だけで busy と決め打つ形へ戻ると、生きた xcodebuild の pid が
    /// 残ったまま iproxy だけが残る実機の形(2026-09-22)を再び busy と誤診する
    func testIosConnectionLostHintProbesBeforeChoosingBusyOrWedged() throws {
        let source = try MCPServerSourceText.combined()
        let start = try XCTUnwrap(source.range(of: "func iosConnectionLostHint("),
                                  "iosConnectionLostHint が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    /// iOS の2分岐"),
                                "iosConnectionLostHint の終端(次の関数のコメント)が見つからない")
        let body = String(tail[..<end.lowerBound])

        XCTAssertTrue(body.contains("BridgeDiscovery.probeStatus(port: port, repoRoot: repoRoot)"),
                     "busy 分岐が probe で busy/wedged を分けていない")
        XCTAssertTrue(body.contains("Self.bridgeWedgedHint(connection: connection)"),
                     "wedged のときに bridgeWedgedHint を返していない")
    }

    /// `udidBridgeDiagnosis` の本体が `isBound` だけの絞り込みへ戻っていないこと
    /// (probe(async)へ一本化した経路が消えていないか)
    func testProbedUDIDBridgeDiagnosisUsesProbeStatusForClassification() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Driver.swift"), encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private static func probedUDIDBridgeDiagnosis("),
            "probedUDIDBridgeDiagnosis が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(
            tail.range(of: "\n    /// `probedUDIDBridgeDiagnosis` が専用 Thread"),
            "probedUDIDBridgeDiagnosis の終端(次のコメント)が見つからない")
        let body = String(tail[..<end.lowerBound])

        XCTAssertTrue(body.contains("BridgeDiscovery.probeStatus("),
                     "udid 診断が probeStatus(busy/wedged 判別)を経由していない")
        XCTAssertTrue(body.contains(".transportFailed"),
                     "wedgedPorts の分類が transportFailed を見ていない")
        XCTAssertTrue(body.contains(".timedOut"),
                     "listeningButUnresponsive の分類が timedOut を見ていない")
    }
}
