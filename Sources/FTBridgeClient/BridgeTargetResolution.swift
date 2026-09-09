// iOS ブリッジの宛先解決とプロトコル版照合を、MCP(ft_*)と CLI の手動駆動サブコマンドが
// 共有するための1箇所。**判定はここ・文言は呼び手ごと**:
// - 宛先探索(1本だけなら自動採用・複数なら拒否・0本ならエラー)の判断と文言はどちらも
//   BridgeDiscovery(このファイルは呼ぶ順序を組むだけ)。ここで文言を新たに作らない。
// - 版ズレは `BridgeVersionSkew` が running/expected の事実だけを返す。「拒否か警告か」
//   「対処の文言(rebuild する実行ファイル名)」は呼び手が変わるので、ここには置かない
//   (MCP は fleetest-mcp を、CLI は fleetest を名指しする)。
//
// Android の宛先解決は `FTAndroid.AndroidTargetResolution` に別に居る —— FTAndroid が
// FTBridgeClient に依存する向きなので、ここから Android 側の型は参照できない。

import FTCore
import Foundation

public enum BridgeTargetResolution {

    /// profile 無しの iOS 宛先。**明示 port は探索しない**(利用者が宛先を決めているため)。
    /// 既定ポートが死んでいるのは珍しくない —— `bridge up` は稼働中ブリッジの再利用や
    /// pid ファイルの残りで別ポートを選ぶ。
    /// `log` は自動採用したときの理由だけを渡す(呼び手が stderr へ出す/出さないを選ぶ)。
    public static func iosPort(explicit: UInt16?, log: (String) -> Void) async throws -> UInt16 {
        if let explicit { return explicit }
        let preferred = BridgeAPI.defaultPort
        let repoRoot = try? RepoRoot.find()
        if await BridgeDiscovery.isAlive(port: preferred, repoRoot: repoRoot) { return preferred }
        // **応答なしを死と読まない**: 待受が続いているなら乗り換え先は別デバイスになる
        let bound = BridgeDiscovery.isBound(port: preferred, repoRoot: repoRoot)
        let found = bound ? [] : await BridgeDiscovery.scan(excluding: preferred, repoRoot: repoRoot)
        switch BridgeDiscovery.decide(preferredAlive: false, preferredBound: bound, found: found) {
        case .usePreferred:
            return preferred
        case .preferredBusy:
            throw BridgeTargetError.busy(preferred: preferred)
        case .adopt(let bridge):
            log(BridgeDiscovery.adoptedNote(preferred: preferred, found: bridge))
            return bridge.port
        case .none:
            throw BridgeTargetError.noBridge(preferred: preferred)
        case .ambiguous(let bridges):
            throw BridgeTargetError.ambiguous(preferred: preferred, found: bridges)
        }
    }

    /// ドライバが繋いでいるブリッジの版と、この実行ファイルが期待する版のズレ。
    /// 一致・判定不能(旧ブリッジは版を返さない)なら nil。
    public static func versionSkew(driver: AppDriver) async -> BridgeVersionSkew? {
        guard let running = try? await driver.status().protocolVersion,
              running != BridgeAPI.bridgeProtocolVersion else { return nil }
        return BridgeVersionSkew(running: running, expected: BridgeAPI.bridgeProtocolVersion)
    }
}

/// iOS ブリッジ探索の失敗。**文言は持たない** —— `errorDescription` は BridgeDiscovery の
/// 対応する関数(busyMessage 等)をそのまま返す。呼び手はこれを包むだけにすること
/// (MCPError / ValidationError へ `errorDescription` を渡す。ここで新しい文言を作らない)
public enum BridgeTargetError: Error, LocalizedError, Equatable {
    case busy(preferred: UInt16)
    case noBridge(preferred: UInt16)
    case ambiguous(preferred: UInt16, found: [BridgeDiscovery.Found])

    public var errorDescription: String? {
        switch self {
        case .busy(let preferred):
            return BridgeDiscovery.busyMessage(preferred: preferred)
        case .noBridge(let preferred):
            return BridgeDiscovery.noBridgeMessage(preferred: preferred)
        case .ambiguous(let preferred, let found):
            return BridgeDiscovery.ambiguousMessage(preferred: preferred, found: found)
        }
    }
}

/// 繋いだブリッジの版と、この実行ファイルが期待する版の食い違い。**事実だけ**(文言は呼び手)。
public struct BridgeVersionSkew: Equatable {
    public let running: Int
    public let expected: Int

    public init(running: Int, expected: Int) {
        self.running = running
        self.expected = expected
    }

    /// true = ブリッジ側が新しい(このビルドが古い) / false = ブリッジ側が古い
    public var bridgeIsNewer: Bool { running > expected }
}
