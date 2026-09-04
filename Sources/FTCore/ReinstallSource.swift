// 実機の `clearAppData` を uninstall + install で代替するときの再インストール元。
//
// **iOS の実機には clearAppData の同等手段が無い**(devicectl に口が無く、BridgeClient が 501 を返す)。
// 代わりにアプリを入れ直すとデータも権限の付与も消えるので、意図そのものは再現できる。ただし
// **消したあとに入れ直せなければ、端末からアプリだけ消えて戻せなくなる** —— だから判定は
// uninstall を撃つ**前に**終わらせ、駄目なら何も壊さずに拒否する。
//
// 判定をここに置くのは MCP と DSL で結論を割らないため(CLAUDE.md「判定は1箇所に置く」)。
// 2026-09-04 まで受け皿は MCP 側にしか無く、**同じ端末・同じ意図の操作が経路によって割れていた**。
// **文言は呼び手が持つ** —— MCP は `packagePath:` を、DSL は実行プロファイルの `appPathPhysical`
// を案内する必要があり、同じ1文で両方は言えない。

import Foundation

/// 入れ直しの元をどう決めたか。**理由まで返す**(呼び手が文言を選べるように)
public enum ReinstallSource: Equatable, Sendable {
    /// 入れ直せる。この path を install に渡してよい
    case usable(String)
    /// 元がどこからも渡っていない
    case unknown
    /// 控えはあるが実体が無い(再ビルドや DerivedData の掃除で移動・消滅する)
    case missing(String)

    /// explicit(呼び出しでの明示)> remembered(直近の install の控え / 実行プロファイルの解決結果)。
    /// `exists` を注入するのは、テストが実ファイル無しに3分岐すべてを確かめられるようにするため
    public static func resolve(explicit: String?, remembered: String?,
                               exists: (String) -> Bool) -> ReinstallSource {
        guard let raw = explicit ?? remembered, !raw.isEmpty else { return .unknown }
        let path = (raw as NSString).expandingTildeInPath
        return exists(path) ? .usable(path) : .missing(path)
    }

    /// 「この端末では clearAppData を実行できない」応答か。**この形だけを入れ直しへ回す**
    /// (他の 501 や 5xx を巻き込むと、直すべき失敗を握り潰して黙って再インストールする)。
    /// 判定元は `BridgeClient.clearAppDataTarget` の 501 —— 片方だけ変えない
    public static func isClearAppDataUnsupported(_ error: Error) -> Bool {
        guard let driverError = error as? DriverError,
              case .badResponse(let status, let body) = driverError else { return false }
        return status == 501 && body.contains("simulator-only")
    }
}
