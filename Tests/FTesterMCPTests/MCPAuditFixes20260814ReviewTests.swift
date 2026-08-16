// bc25219 / 6d26a66(2026-08-14 実機監査)のレビューで出た4件。いずれも実機で再現済み。
//
// ① ft_list_apps が udid:/port: 経路の実機で必ず throw する。
//    `bootedSimulatorUDID(named: "iPhone")` が候補 udid の出所を確かめる前に呼ばれており、
//    実機は udid をどこから拾っても(引数の udid: / セッション記憶 / ポート単位の記録)
//    このシミュレータ専用フォールバックへ先に落ちて死ぬ。profile: 経路は provisioned.udid が
//    そのまま `udids[key]` に載るため元から生きていた。
//
// ② profile のキャッシュ命中が rememberResolvedTarget を呼ばず、セッション記憶を更新しない。
//    profile:A → port:B → profile:A の順に触ると、2度目の profile:A がキャッシュ命中で
//    早期 return し、記憶が B のまま止まる。
//
// ③ ft_list_devices が `??` で udid 一致と名前一致のどちらか片方しか見せない。
//    同じ端末に udid を申告するブリッジと申告しない旧ブリッジが同居すると、udid 側で1本でも
//    当たった時点で名前側(旧ブリッジ)がまるごと消える。
//
// ④ deviceIdentityChanged が宛先ホストを 127.0.0.1 に決め打ちする。実機の lan トランスポート
//    (ランナーを 0.0.0.0 に bind してデバイスの LAN IP へ直接叩く)ではデバイスに届かず、
//    同じポート番号で loopback に応答した別の機の udid を読んで正しい呼び出しを拒否しかねない。

import XCTest
import FTBridgeClient
import FTCore
@testable import ftester_mcp

final class MCPAuditFixes20260814ReviewTests: XCTestCase {

    private static func dispatchSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ftester-mcp/MCPServer+Dispatch.swift"), encoding: .utf8)
    }

    private static func driverSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ftester-mcp/MCPServer+Driver.swift"), encoding: .utf8)
    }

    /// 空白と改行を落とした形で照合する(KeyboardOcclusionWiringTests.compact と同じ理由:
    /// 引数の改行位置で普通の折り返しがリテラル照合を落とす実績がある)
    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    // MARK: - 欠陥① ft_list_apps: 実機判定を throw し得るシミュレータ経路より先にする

    /// **ソース走査**: 候補 udid(実機かどうかの判定材料)を組む行が、投げ得る
    /// `SimulatorAppCatalog.bootedSimulatorUDID` の呼び出しより前にあること。
    /// 実機は udid をどこから拾っても deviceName ("iPhone" 相当)がシミュレータ名と一致しないため、
    /// 後ろにあると必ず throw する(実測: `Error: no booted simulator found: iPhone`)
    func testListAppsBuildsCandidateUDIDBeforeTheThrowingSimulatorFallback() throws {
        let source = try Self.dispatchSource()
        let start = try XCTUnwrap(source.range(of: "case \"ft_list_apps\":"),
                                  "ft_list_apps の分岐が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "case \"ft_logs\":"), "次の case が見つからない")
        let body = String(tail[..<end.lowerBound])

        let candidate = try XCTUnwrap(body.range(of: "let candidateUDID ="),
                                      "候補 udid を組む行が見つからない(欠陥①の修正が無い)")
        let throwingFallback = try XCTUnwrap(
            body.range(of: "SimulatorAppCatalog.bootedSimulatorUDID"),
            "シミュレータ専用フォールバックが見つからない")
        XCTAssertTrue(candidate.lowerBound < throwingFallback.lowerBound,
                      "候補 udid の組み立てが bootedSimulatorUDID より後ろにある —— 実機は"
                      + " udid の出所に関わらずここへ先に落ちて必ず throw する(欠陥①の再発)")
    }

    /// **ソース走査**: 候補 udid が呼び出し引数の `udid:` を直接見ること。`udids[key]` だけに
    /// 頼ると、udid: を渡した呼び出しでも(直接ポート経路の driver() は ExploreDriverResolver が
    /// SimulatorCatalog しか見ないため)実機では `udids[key]` が nil のままで拾えない
    func testListAppsCandidateUDIDConsultsTheRawArgumentFirst() throws {
        let source = try Self.dispatchSource()
        let start = try XCTUnwrap(source.range(of: "case \"ft_list_apps\":"),
                                  "ft_list_apps の分岐が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "case \"ft_logs\":"), "次の case が見つからない")
        let body = compact(String(tail[..<end.lowerBound]))

        XCTAssertTrue(body.contains(compact("(args[\"udid\"] as? String)")),
                     "候補 udid が呼び出し引数の udid: を直接見ていない")
    }

    /// **ソース走査**: `port:` だけの呼び出しでも、実機専用のポート記録
    /// (`.ftester/bridge-<port>.device` = `BridgeDeviceRecord`)を候補に含めること。
    /// これが無いと、udid: も渡さず port: だけで実機を指した呼び出しは依然として拾えない
    func testListAppsCandidateUDIDFallsBackToThePortRecordForBareUdidlessPortCalls() throws {
        let source = try Self.dispatchSource()
        let start = try XCTUnwrap(source.range(of: "case \"ft_list_apps\":"),
                                  "ft_list_apps の分岐が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "case \"ft_logs\":"), "次の case が見つからない")
        let body = compact(String(tail[..<end.lowerBound]))

        XCTAssertTrue(body.contains(compact("BridgeDeviceRecord.load(port: port, repoRoot:")),
                     "port: 経路の候補 udid が BridgeDeviceRecord(実機専用のポート記録)を"
                     + "見ていない —— port: だけで実機を指した呼び出しが通らないまま残る")
    }

    // MARK: - 欠陥② profile のキャッシュ命中が記憶を更新すること

    /// **ソース走査**: profile 分岐のキャッシュ命中(`if let cached = drivers[key]` 〜
    /// `return cached`)が rememberResolvedTarget を呼ぶこと。この枝は makeDriver 注入より手前で
    /// 短絡されるため call() 越しには踏めない(MCPAuditFixes20260813PhysicalDeviceTests.
    /// testProfileBranchOfDriverCallsTheRecorder / MCPSessionMemoryCacheHitTests.
    /// testCachedDriverBranchCallsTheRecorder と同じ理由)
    func testProfileCachedBranchCallsTheRecorder() throws {
        let source = try Self.driverSource()
        let marker = "if let profileName = args[\"profile\"] as? String {"
        let start = try XCTUnwrap(source.range(of: marker), "profile 分岐の開始が見つからない")
        let tail = source[start.upperBound...]
        let cachedBranch = try XCTUnwrap(tail.range(of: "if let cached = drivers[key]"),
                                         "profile 分岐のキャッシュ命中枝が見つからない")
        let afterBranch = tail[cachedBranch.upperBound...]
        let returnCached = try XCTUnwrap(afterBranch.range(of: "return cached"))
        let body = afterBranch[..<returnCached.lowerBound]
        XCTAssertTrue(body.contains("rememberResolvedTarget"),
                      "profile のキャッシュ命中が早期 return する前にセッション記憶を更新していない"
                      + "(profile:A → port:B → profile:A の後、記憶が B のまま止まる)")
    }

    /// **配線**: iosPort に生成側(`connectedPorts[key] = probePort ?? provisioned.port`)と
    /// 同じ値を渡すこと。ここが `provisioned.port` 等の別値を直接組み立て直すと、生成時と
    /// キャッシュ命中時で記録される port がずれ得る
    func testProfileCachedBranchReusesConnectedPortsAsTheSourceOfTruth() throws {
        let source = try Self.driverSource()
        let marker = "if let profileName = args[\"profile\"] as? String {"
        let start = try XCTUnwrap(source.range(of: marker), "profile 分岐の開始が見つからない")
        let tail = source[start.upperBound...]
        let cachedBranch = try XCTUnwrap(tail.range(of: "if let cached = drivers[key]"),
                                         "profile 分岐のキャッシュ命中枝が見つからない")
        let afterBranch = tail[cachedBranch.upperBound...]
        let returnCached = try XCTUnwrap(afterBranch.range(of: "return cached"))
        let body = compact(String(afterBranch[..<returnCached.lowerBound]))
        XCTAssertTrue(body.contains(compact("iosPort: connectedPorts[key]")),
                     "profile のキャッシュ命中が iosPort を connectedPorts[key] 以外から"
                     + "組み立てている —— 生成側(probePort ?? provisioned.port)とずれ得る")
    }

    // MARK: - 欠陥③ ft_list_devices: udid 一致と名前一致の和集合

    private func spec(name: String, kind: DeviceKind? = nil, simulator: String? = nil,
                      os: String? = nil, udid: String? = nil) -> DeviceSpec {
        DeviceSpec(name: name, kind: kind, simulator: simulator, os: os, udid: udid)
    }

    /// **実測した実害の再現**: udid を申告する新しいブリッジと、申告しない旧ブリッジが同じ端末に
    /// 同居すると、`??` は udid 側で1本当たった時点で名前側(旧ブリッジ)を丸ごと捨てていた。
    /// `liveIOSBridges()` は申告の有無に関わらず全ブリッジを byName(status.device 名)へ入れ、
    /// 申告するものだけ byUDID にも入れる —— 旧ブリッジは byName にしか居ない。
    /// 修正後は両方が port 昇順で出ること
    func testIOSRowShowsBothAnUDIDDeclaringBridgeAndALegacyNameOnlyBridgeOnTheSameDevice() {
        let device = SimDeviceInfo(udid: "SIM-9", name: "iPhone 17 Pro", os: "iOS 26.0", booted: true)
        let modernBridge = DeviceInventory.Row.Bridge(port: 8144, engine: "inapp")
        let legacyBridge = DeviceInventory.Row.Bridge(port: 8140, engine: "xcuitest")
        let live = DeviceInventory.LiveBridges(
            byName: ["iPhone 17 Pro": [modernBridge, legacyBridge]],
            byUDID: ["SIM-9": [modernBridge]])
        let row = DeviceInventory.iosRow(
            spec: spec(name: "primary", simulator: "iPhone 17 Pro"),
            simDevices: [device], physicalDevices: [], liveBridges: live)

        XCTAssertEqual(row.bridges.map(\.port), [8140, 8144],
                       "udid 一致で1本当たった時点で名前一致(旧ブリッジ)が消えている(欠陥③)")
    }

    /// 同じポートが両方の鍵で当たっても重複させないこと(和集合の実装がそのまま連結しただけなら
    /// ここで2本に見えてしまう)
    func testIOSRowDoesNotDuplicateABridgeThatMatchesBothUDIDAndName() {
        let device = SimDeviceInfo(udid: "SIM-9", name: "iPhone 17 Pro", os: "iOS 26.0", booted: true)
        let bridge = DeviceInventory.Row.Bridge(port: 8144, engine: "xcuitest")
        let live = DeviceInventory.LiveBridges(
            byName: ["iPhone 17 Pro": [bridge]], byUDID: ["SIM-9": [bridge]])
        let row = DeviceInventory.iosRow(
            spec: spec(name: "primary", simulator: "iPhone 17 Pro"),
            simDevices: [device], physicalDevices: [], liveBridges: live)
        XCTAssertEqual(row.bridges, [bridge])
    }

    // MARK: - 欠陥④ deviceIdentityChanged が宛先ホストを BridgeEndpoint.load で解決すること

    /// **ソース走査**: `deviceIdentityChanged` が host を 127.0.0.1 決め打ちにせず、他の3箇所
    /// (BridgeDiscovery.isBound/scan・ExploreDriverResolver)と同じ `BridgeEndpoint.load` を
    /// 通すこと。実機の lan トランスポートは host が loopback ではないため、決め打ちのままだと
    /// デバイスに一度も届かず、同じポート番号で loopback に応答した別の機の udid を読みかねない
    func testDeviceIdentityChangedResolvesHostViaBridgeEndpoint() throws {
        let source = try Self.driverSource()
        let start = try XCTUnwrap(source.range(of: "func deviceIdentityChanged("),
                                  "deviceIdentityChanged が見つからない")
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(
            tail.range(of: "\n    /// ポートが別の機へ移っていたときに呼び出しを断る文"),
            "deviceIdentityChanged の終端(次のコメント)が見つからない")
        let body = compact(String(tail[..<end.lowerBound]))

        XCTAssertTrue(body.contains(compact("BridgeEndpoint.load(port: port, repoRoot:")),
                     "deviceIdentityChanged が宛先ホストを BridgeEndpoint.load で解決していない"
                     + "(127.0.0.1 決め打ちのままでは実機の lan トランスポートに届かない)")
        XCTAssertFalse(body.contains(compact("BridgeClient(port: port, timeoutSeconds: 5).status()")),
                       "127.0.0.1 決め打ちの旧呼び出し(host 引数無し)が残っている")
    }

    /// 純粋な形の同一性判定そのもの(keyChangedDevice)は host 解決と無関係に壊れていないこと
    /// (回帰確認 — ④の修正が判定ロジック自体へ影響していないかの対照)
    func testKeyChangedDeviceStillDetectsAMovedUDID() {
        XCTAssertEqual(MCPServer.keyChangedDevice(previous: "AAA", now: "BBB"), "AAA")
        XCTAssertNil(MCPServer.keyChangedDevice(previous: "AAA", now: "AAA"))
        XCTAssertNil(MCPServer.keyChangedDevice(previous: nil, now: "BBB"),
                     "片方が不明なら『変わった』と読まない")
    }
}
