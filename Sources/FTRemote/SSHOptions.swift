// ssh/scp/rsync が共有するキープアライブ(定義はここ1箇所。BatchMode/ConnectTimeout は各呼び手の既存値)。
// 無いと回線が黙って死んだとき TCP の既定(macOS で数十分)まで待ち・回収・unlock が止まる。
// 切断は exit 255 = 既存の到達不能の失敗経路へそのまま合流する。
public enum SSHOptions {
    /// 生存確認の送信間隔(秒)。`sshCaptureTimeoutSeconds`(120 秒)より十分短く
    public static let serverAliveIntervalSeconds = 15
    /// 無応答の許容回数。15 秒 × 4 = 60 秒無応答でクライアント側から切る
    public static let serverAliveCountMax = 4

    public static let keepAliveArgs: [String] = [
        "-o", "ServerAliveInterval=\(serverAliveIntervalSeconds)",
        "-o", "ServerAliveCountMax=\(serverAliveCountMax)",
    ]

    /// rsync の `-e`。rsync は値を空白で分割して実行するので1文字列にまとめる(ローカル間転送では使われない)
    public static let rsyncRemoteShellArgs: [String] = ["-e", (["ssh"] + keepAliveArgs).joined(separator: " ")]
}
