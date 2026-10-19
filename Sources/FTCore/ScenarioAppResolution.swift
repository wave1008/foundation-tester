// シナリオの既定アプリ(bundle ID / パッケージ名)を1箇所で決める。
// 供給元は実行プロファイル → アプリプロファイルの `<platform>.app`(親が `--app` で子へ渡す)だけ。
// プロファイル無しの実行は `--app-id` が同じ経路で値を渡す。
// ランナー(FTScenarioRunner)はここを呼んで結果を転写するだけにする。

import Foundation

public enum ScenarioAppResolution {
    /// dry-run で解決できなかったときにステップ説明へ出す代替表記。デバイスに触らないので
    /// bundle ID は使われず、ここで落とすと「プロファイル無しでは構文検査もできない」になる
    public static let dryRunPlaceholder = "<app from run profile>"

    public enum Result: Equatable {
        case resolved(bundleID: String)
        case unresolved(message: String)
    }

    /// fromProfile: 実行プロファイルが解決した bundle ID(`--app`。nil / 空白のみは「無い」)
    public static func resolve(fromProfile: String?,
                               scenarioID: String, dryRun: Bool = false) -> Result {
        if let trimmed = fromProfile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return .resolved(bundleID: trimmed)
        }
        if dryRun {
            return .resolved(bundleID: dryRunPlaceholder)
        }
        return .unresolved(message:
            "No app could be resolved for \(scenarioID). Run it with --profile <name> (the app profile's"
            + " app for the platform is used), or pass --app-id <bundleID> when running without a profile.")
    }
}
