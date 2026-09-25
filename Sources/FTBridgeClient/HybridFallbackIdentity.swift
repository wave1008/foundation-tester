// hybrid(in-app + XCUITest)が握る「主とは別ポート」の本人確認(maintainer-notes §51.2)。
//
// キャッシュ/使い回すドライバが1本の port だけを確かめて安全だと思っていても、hybrid の合成
// (HybridFallbackDriver / HybridDriverComposition)は home/appSwitcher/drag/座標 press/gesture/
// pinch を fallback(XCUITest)側の別ポートへ回す。ブリッジは run のたびに建て直され、
// 同じポート番号が別デバイス(あるいは同じデバイスの別エンジン)に化り得るので、
// 主のポートしか確かめないと黙って別の機へ操作が届く。
//
// 判定そのものは FTCore.BridgeIdentityCheck.hybridFallbackDrift の1箇所(呼び手ごとに
// 文言は持たない)。ここは probe(status 取得)の配線だけを共有する ——
// 呼び手は MCP(fleetest-mcp)とライブ操作(api live serve)の2つ。予備ポートだけでなく
// 主ポート(エンジンが同じ台の別エンジンに化けた形。§51.10)の確認にも使う。
// 実機のランナーは udid を名乗らないので、status は statusForIdentityCheck で台帳から補ってから判定する。

import FTCore
import Foundation

public enum HybridFallbackIdentity {
    /// `port` が今も `expectedUDID` の `expectedEngine` ブリッジを指しているかを確かめる。
    /// **不明(/status を読めない・タイムアウト)は `.none` に倒す**(「変わった」にしない)——
    /// busy な XCUITest は正常に無応答になるので、読めないだけで毎回作り直すと健全な呼び出しが
    /// 遅くなり続ける(`deviceIdentityChanged`/MCP の `hybridFallbackDrifted` と同じ規律)
    public static func drifted(
        port: UInt16, expectedUDID: String, expectedEngine: String = "xcuitest",
        repoRoot: URL?, timeoutSeconds: Double = 3
    ) async -> BridgeIdentityCheck.HybridFallbackDrift {
        let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        guard let reported = try? await BridgeClient(endpoint: endpoint, timeoutSeconds: timeoutSeconds)
            .status(timeout: timeoutSeconds) else { return .none }
        let status = BridgeDiscovery.statusForIdentityCheck(reported, port: port, repoRoot: repoRoot)
        return BridgeIdentityCheck.hybridFallbackDrift(
            port: port, expectedUDID: expectedUDID, expectedEngine: expectedEngine, status: status)
    }
}
