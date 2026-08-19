// シナリオの既定アプリ(bundle ID / パッケージ名)を1箇所で決める。
// 供給元は2つ: ①`@TestClass(app:)` の明示 ②実行プロファイル → アプリプロファイルの
// `<platform>.app`(親が `--app` で子へ渡す)。**優先順を2箇所に手書きしない**ため、
// ランナー(FTScenarioRunner)はここを呼んで結果を転写するだけにする。
//
// 明示が勝つ: 1プロジェクトに複数アプリのシナリオが混在する構成を壊さないため
// (実行プロファイル側にシナリオを絞り込む仕組みが無く、プロファイルを常に勝たせると
// 別アプリのシナリオが**黙って**誤ったアプリを起動する)。食い違いは警告1行だけ出す。

import Foundation

public enum ScenarioAppResolution {
    /// dry-run で解決できなかったときにステップ説明へ出す代替表記。デバイスに触らないので
    /// bundle ID は使われず、ここで落とすと「プロファイル無しでは構文検査もできない」になる
    public static let dryRunPlaceholder = "<app from run profile>"

    public enum Result: Equatable {
        /// warning != nil = 明示とプロファイルが食い違っている(明示を採ったうえで知らせる)
        case resolved(bundleID: String, warning: String?)
        case unresolved(message: String)
    }

    /// declared: `@TestClass(app:)`(nil / 空文字はどちらも「書かれていない」)
    /// fromProfile: 実行プロファイルが解決した bundle ID(`--app`)
    public static func resolve(declared: String?, fromProfile: String?,
                               scenarioID: String, dryRun: Bool = false) -> Result {
        let declared = normalized(declared)
        let fromProfile = normalized(fromProfile)

        if let declared {
            var warning: String?
            if let fromProfile, fromProfile != declared {
                warning = "\(scenarioID) declares @TestClass(app: \"\(declared)\"),"
                    + " which differs from the app the run profile resolves to (\"\(fromProfile)\")."
                    + " The declaration wins. Drop app: from @TestClass to follow the run profile."
            }
            return .resolved(bundleID: declared, warning: warning)
        }
        if let fromProfile {
            return .resolved(bundleID: fromProfile, warning: nil)
        }
        if dryRun {
            return .resolved(bundleID: dryRunPlaceholder, warning: nil)
        }
        return .unresolved(message:
            "\(scenarioID) declares no @TestClass(app:) and no app could be resolved from a run"
            + " profile. Run it with --profile <name> (the profile's app is used), or pass"
            + " --app <bundleID>, or write @TestClass(app: \"<bundleID>\").")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
