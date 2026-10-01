// ブリッジの持ち主の仕分け(純粋関数)。doctor の処遇(UnmanagedBridgeTriage)と供給の計画段
// (BridgeProvisioner.planBridge)が共有する —— 片方だけ変えると、doctor は「他人の資産」と言うのに
// 供給がそれを止める、のように食い違う(実害: 別クローンの供給が本線の XCUITest ランナーを
// 「ツールチェーンの記録が無い」で起動し直して止めた)。

import Foundation

public enum BridgeOwnership: Equatable, Sendable {
    /// 自分のクローンが起こした(申告が自分。申告が無ければ自分の台帳がある)
    case own
    /// 別の実在するワークスペースが起こした。**止めない・起動し直さない**
    case foreign(owner: String)
    /// 申告先のディレクトリが消えている = 確定した孤児。自分のものと同じく止めてよい
    case orphan(owner: String)
    /// 申告の無い旧ブリッジで、自分の台帳も無い
    case unknown

    /// - ownerRepo: /status の自己申告(`FT_OWNER_REPO`。nil = 申告しない旧ブリッジ)
    /// - isOwnRepo: 申告パスが自分のクローンか(`isSameRepo`)
    /// - ownerExists: 申告パスがディレクトリとして実在するか
    /// - hasStateFile: 自分の台帳(`.pid` / `.inapp`)がそのポートにあるか
    ///
    /// **申告を台帳より先に見る** —— 台帳はポートしか持たないので、自分の古い台帳が残るポートに
    /// 別のクローンのブリッジが居ると、台帳を先に見た時点で自分のものと誤る
    /// (rules/bridge-provision.md「ポートだけで自分の残骸と決めない」)
    public static func classify(ownerRepo: String?, isOwnRepo: Bool, ownerExists: Bool,
                                hasStateFile: Bool) -> BridgeOwnership {
        if let ownerRepo {
            if isOwnRepo { return .own }
            return ownerExists ? .foreign(owner: ownerRepo) : .orphan(owner: ownerRepo)
        }
        return hasStateFile ? .own : .unknown
    }

    /// 申告パスが自分のクローンか。`/private` の有無・末尾の `/`・シンボリックリンクの表記揺れを畳む
    public static func isSameRepo(_ reported: String, _ repoRoot: URL) -> Bool {
        canonical(reported) == canonical(repoRoot.path)
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
