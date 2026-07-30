// doctor の管理外ブリッジの処遇判定(純粋ロジック)。実行系は FTester.swift 側。
// 原則: 自動停止は「証拠が決定的」な2行だけ。別の実在ワークスペースの資産は殺さない。

import Foundation

enum UnmanagedBridgeAction: Equatable {
    /// 自リポジトリ所有だが版が現行 = provision が再利用できる健全なブリッジ。報告しない
    case skipHealthy
    /// 自リポジトリ所有で版が古い → 自分の資産なので自動停止してよい
    case reapOwnStale
    /// 起動元リポジトリが消えている → 確定ゾンビ。自動停止してよい
    case reapOrphan(owner: String)
    /// 別の実在ワークスペースの所有物 → 停止しない。所有者を明示して報告
    case reportForeign(owner: String)
    /// 起動元不明(自己申告の無い旧ブリッジ)→ 報告のみ
    case reportUnknown
}

enum UnmanagedBridgeTriage {
    /// - ownerRepo: /status の自己申告(nil = 申告しない旧ブリッジ)
    /// - ownerExists: 申告パスがディレクトリとして実在するか
    /// - isOwnRepo: 申告パスが自リポジトリのルートか
    /// - hasStateFile: 自リポジトリの状態ファイル(.pid / .inapp)があるか
    /// - stale: protocolVersion が現行と不一致か(自リポジトリ資産の入れ替え判定にのみ使う。
    ///   別ワークスペースは古い版のクローンを正当に使い得るため、処遇には影響させない)
    static func decide(ownerRepo: String?, ownerExists: Bool, isOwnRepo: Bool,
                       hasStateFile: Bool, stale: Bool) -> UnmanagedBridgeAction {
        if isOwnRepo || hasStateFile {
            return stale ? .reapOwnStale : .skipHealthy
        }
        guard let ownerRepo else { return .reportUnknown }
        return ownerExists ? .reportForeign(owner: ownerRepo) : .reapOrphan(owner: ownerRepo)
    }
}
