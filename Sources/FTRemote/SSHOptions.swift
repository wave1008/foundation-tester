// ssh/scp/rsync が共有する接続オプション(定義はここ1箇所)。
// 無いと回線が黙って死んだとき TCP の既定(macOS で数十分)まで待ち・回収・unlock が止まる。
// 切断は exit 255 = 既存の到達不能の失敗経路へそのまま合流する。
public enum SSHOptions {
    /// 生存確認の送信間隔(秒)。`sshCaptureTimeoutSeconds`(120 秒)より十分短く
    public static let serverAliveIntervalSeconds = 15
    /// 無応答の許容回数。15 秒 × 4 = 60 秒無応答でクライアント側から切る
    public static let serverAliveCountMax = 4

    /// 接続そのものの上限(秒)。無いと到達不能ホストで TCP 既定(75秒超)固まる
    public static let connectTimeoutSeconds = 10

    /// パスワード入力で止まらないよう非対話にし、接続の上限を付ける(全 ssh/scp 共通の基底オプション)
    public static let batchConnectArgs: [String] = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
    ]

    public static let keepAliveArgs: [String] = [
        "-o", "ServerAliveInterval=\(serverAliveIntervalSeconds)",
        "-o", "ServerAliveCountMax=\(serverAliveCountMax)",
    ]

    /// rsync の `-e`。rsync は値を空白で分割して実行するので1文字列にまとめる(ローカル間転送では使われない)
    public static let rsyncRemoteShellArgs: [String] = ["-e", (["ssh"] + keepAliveArgs).joined(separator: " ")]
}
