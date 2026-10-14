// UDP の経路の確認の純粋な部分(docs/remote-runner.md §17「UDP の経路の確認」)。
// ソケットの送受信・エコーの起動は呼び手(ServicesSession)。ここはファイル・時刻・乱数・ソケットに触れない。

import Foundation

/// 親が毎回変わるトークンをエコーへ送り、同じ値が返るかを見る。
/// 対象は経路(Mac の 127.0.0.1 → ランタイムの公開(+ Docker は中継)→ コンテナ)だけ。利用者のサービスが待ち受けているかは見ない。
public enum UDPReachability {
    /// 1 回の待ち(秒)。根拠: UDP の往復は LAN でも数 ms で、1 秒は VM の起動直後の取りこぼしを跨ぐのに足りる。尽きたとき = 次の試行。
    public static let attemptTimeoutSeconds: Double = 1
    /// 試行回数。根拠: 取りこぼしは連続しない(起動直後の 1 回程度)ので 3 回で十分。尽きたとき = 届かなかったと判定し、
    /// run は始めない(`ServicesError`。アプリの UDP が届かない run はシナリオがアプリの不具合の顔で落ちるだけ)。
    public static let attempts = 3

    public enum Outcome: Sendable, Equatable {
        /// attempt は 1 始まり。
        case reached(attempt: Int)
        case unreached(attempts: Int)
    }

    /// 前後の空白・改行は無視しない(エコーはそのまま返す)。空・別の値・部分一致は false = 無関係な応答を届いたと数えない。
    public static func matches(sent token: String, received: Data) -> Bool {
        guard !token.isEmpty else { return false }
        return received == Data(token.utf8)
    }

    /// 起動の失敗の detail(`ServicesError` が "services: … (phase: …)" で包む)。事実だけを書く。
    /// tcpReached: nil = TCP は確かめていない(句を書かない)。cause: nil = 書かない。
    public static func failureDetail(hostPort: Int, runtime: ServiceRuntime, attempts: Int, timeoutSeconds: Double,
                                     tcpReached: Bool?, cause: String?) -> String {
        var s = "127.0.0.1:\(hostPort)/udp (published by \(runtime.rawValue)) did not answer "
            + "\(attempts) probes of \(durationText(timeoutSeconds)) each"
        if let tcpReached {
            s += tcpReached ? "; TCP on the same path did answer" : "; TCP on the same path did not answer either"
        }
        if let cause { s += " — \(cause)" }
        return s
    }

    public static func reachedLine(hostPort: Int, attempt: Int) -> String {
        "→ services: UDP path 127.0.0.1:\(hostPort)/udp answered on probe \(attempt)"
    }

    /// 整数なら "1s"、小数なら "0.5s"(小数 3 桁で丸め、末尾の 0 を落とす)。
    static func durationText(_ seconds: Double) -> String {
        if seconds == seconds.rounded() { return "\(Int(seconds))s" }
        var t = String(format: "%.3f", seconds)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return "\(t)s"
    }
}

/// Rancher Desktop の転送方式(SSH の方式は UDP を運べない)。設定ファイルを読めたときだけ原因として添える。
public enum RancherPortForwarding {
    /// ホーム基準。
    public static let settingsSubpath = "Library/Preferences/rancher-desktop/settings.json"

    private struct Settings: Decodable {
        struct Experimental: Decodable {
            struct VirtualMachine: Decodable { var sshPortForwarder: Bool? }
            var virtualMachine: VirtualMachine?
        }
        var experimental: Experimental?
    }

    /// 鍵は `experimental.virtualMachine.sshPortForwarder`(Bool)。読めない・欄が無い・Bool でない = nil(原因を書かない側に倒す)。
    public static func usesSSHForwarder(settingsJSON: Data) -> Bool? {
        (try? JSONDecoder().decode(Settings.self, from: settingsJSON))?.experimental?.virtualMachine?.sshPortForwarder
    }

    public static let cause = "Rancher Desktop is using the SSH port forwarder (experimental.virtualMachine.sshPortForwarder = true), which cannot carry UDP; switch with `rdctl set --experimental.virtual-machine.ssh-port-forwarder=false`, then quit Rancher Desktop completely and start it again"
}
