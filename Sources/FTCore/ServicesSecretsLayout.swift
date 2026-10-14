// サービス用の秘密の置き場(docs/remote-runner.md §17)。純粋。
// `ScenarioSandbox` が子の読み取りからこの2つを名指しで拒否する(`.config/fleetest` を開け直した後に書く)。
// 置き場を変えたらサンドボックスの拒否も同じ定数から作られるので追随する。

public enum ServicesSecretsLayout {
    /// ホーム基準。マシン側の秘密のファイル(`<project>.env`)を置く。
    public static let secretsSubpath = ".config/fleetest/secrets"
    /// ホーム基準。親が run ごとに作る親専用の env-file 等を置く(`<pid>/`)。
    public static let privateSubpath = ".config/fleetest/private"

    public static func secretsDirectory(home: String) -> String { home + "/" + secretsSubpath }
    public static func privateRoot(home: String) -> String { home + "/" + privateSubpath }

    public static func secretsFile(home: String, project: String) -> String {
        secretsDirectory(home: home) + "/" + project + ".env"
    }

    public static func privateDirectory(home: String, pid: Int32) -> String {
        privateRoot(home: home) + "/" + String(pid)
    }
}
