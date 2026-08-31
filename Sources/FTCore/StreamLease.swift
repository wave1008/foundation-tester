// StreamLease.swift
// **同じ台の画面配信を、複数の利用者が二重に張らないようにするための控え**
// (docs/remote-runner.md §18.2 M2)。共有ランナーでは同じデバイスを2人が同時に眺めうるが、
// 配信は端末側の実コスト(screenrecord / simstream)なので、人数ぶん重ねると
// 「配信を張ったままの run は赤くなる」と同じ経路でランナーを痛める(docs/verification.md)。
//
// **拒否しない・待たせない**。配信を張る側(`api device-stream`)が控えを1つ置き、
// 監視の子(`api monitor`)がそれを読んで **「他の発行者が配信中」だけを事実として配る**。
// 拡張はその台の配信を起こさずポーリングのままにする —— 起こしてから断られる形にすると、
// **失敗するたびに ssh を張り直す**(1台ごとに数十秒周期の再試行)ことになる。
// 相手が配信をやめれば次の監視サイクル(既定2秒)で自然に張られる。
//
// 生存判定は **pid だけ**(mtime を見ない = RunHookLease と同じ規律)。`api device-stream` は
// ヘルパーへ execv で化けるので pid はそのまま生き続け、配信が終われば消える。
// **控えのファイルは消さない**(execv した先には後始末の機会が無い)—— 死んだ pid の控えは
// 読む側が無視する。台数ぶんしか増えない。
//
// **受け入れている穴**: pid が一巡して無関係のプロセスに当たると、その台は「他人が配信中」の
// まま張れなくなる(症状はタイル1枚がポーリングのままになるだけで、run には影響しない)。
// 時間で切る案は「何秒なら古い」の根拠が無い(長い配信は何時間でも続く)ので採らず、
// **`remote clean` の保持ポリシーが `<base>/.fleetest/streams` を掃く**ことで上限を作る。

import Foundation

public struct StreamLeaseInfo: Codable, Equatable, Sendable {
    /// 配信ヘルパーの pid(execv 後もこの値のまま)
    public let pid: Int32
    /// 自己申告の発行者(LocalConfig.resolveIssuerId)。**誰の配信かの唯一の手掛かり**で、
    /// 「他人が配信中か」の判定はこれだけを見る
    public let issuer: String
    public let startedAt: String

    public init(pid: Int32, issuer: String, startedAt: String) {
        self.pid = pid
        self.issuer = issuer
        self.startedAt = startedAt
    }

    public static func now(pid: Int32, issuer: String, date: Date = Date()) -> StreamLeaseInfo {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return StreamLeaseInfo(pid: pid, issuer: issuer, startedAt: formatter.string(from: date))
    }
}

public enum StreamLease {

    /// 控えの置き場は**ホスト共有**(`<base>/.fleetest/streams/`)。発行者ネームスペースの中に
    /// 置くと、他人の配信が見えず二重配信を防げない ―― デバイスはホストの資源(dispatch.lock が
    /// ホストに1本なのと同じ理由)
    public static func directory(base: String) -> String {
        base + "/.fleetest/streams"
    }

    /// デバイス1台の鍵。**`api device-stream` と `api monitor` が同じ綴りを作る契約**
    /// (片方だけ変えると二重配信が黙って復活する)。マシンプロファイル上の名前は空白・
    /// 括弧・"/" を含むので、安全な文字以外を %XX へ畳む(**衝突しない** = 別の台を
    /// 同じ鍵にして互いに配信を止め合うことが無い)
    public static func key(platform: String, name: String) -> String {
        var encoded = ""
        for byte in Array((platform + ":" + name).utf8) {
            let scalar = UnicodeScalar(byte)
            let safe = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || scalar == "." || scalar == "_" || scalar == "-"
            encoded += safe ? String(Character(scalar)) : String(format: "%%%02X", byte)
        }
        return encoded
    }

    public static func fileURL(base: String, platform: String, name: String) -> URL {
        URL(fileURLWithPath: directory(base: base))
            .appendingPathComponent(key(platform: platform, name: name) + ".json")
    }

    /// 控えを置く(配信を始める直前に1回)。失敗は無視してよい ―― 控えが無くても配信は張れる
    /// (二重配信を1回見逃すだけ。配信そのものを控えの都合で止めない)
    public static func write(base: String, platform: String, name: String, info: StreamLeaseInfo) {
        let url = fileURL(base: base, platform: platform, name: name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(info) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// その台を**自分以外の発行者**が配信中か。控えが無い・死んだ pid・自分の控えは false。
    /// **判定は純粋関数**(I/O は読み込み側)—— 変異テストで両方向に掛けられる形にする
    public static func heldByOther(info: StreamLeaseInfo?, myIssuer: String,
                                   pidAlive: (Int32) -> Bool) -> Bool {
        guard let info else { return false }
        guard info.issuer != myIssuer else { return false }
        return pidAlive(info.pid)
    }

    /// ディスクから1台ぶん読む(判定は heldByOther)
    public static func read(base: String, platform: String, name: String) -> StreamLeaseInfo? {
        let url = fileURL(base: base, platform: platform, name: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StreamLeaseInfo.self, from: data)
    }
}
