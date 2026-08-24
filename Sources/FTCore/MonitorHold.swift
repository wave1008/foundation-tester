// モニターの観測・配信を CLI から止める保持ファイル(.ftester/monitor-hold.json)。
// 書き込み: `ftester monitor pause/resume` / 読み取り: ApiMonitorCommand(各周期の頭)と
// 拡張(monitorHold イベント経由で配信ヘルパーを畳む)。
// **kill ではなくファイルで伝える** —— `api monitor` を kill しても拡張が数秒で再起動する
// (配信ヘルパーも同様)ので、プロセスの生死では計測条件が作れない(受け手報告 2026-08-24)。
// 発行者の pid 生存は見ない: pause コマンドは書いて即終了するのが正常で、生存判定に使えない。
// 解除は「until の期限」か「明示 resume」だけ。

import Foundation

public struct MonitorHold: Codable, Equatable, Sendable {
    /// 期限(epoch 秒)。nil = 明示 resume まで
    public let until: Double?
    public let startedAt: Double

    public init(until: Double?, startedAt: Double) {
        self.until = until
        self.startedAt = startedAt
    }

    public func isActive(now: Date = Date()) -> Bool {
        guard let until else { return true }
        return now.timeIntervalSince1970 < until
    }

    public static func url(stateDir: URL) -> URL {
        stateDir.appendingPathComponent("monitor-hold.json")
    }

    public static func load(stateDir: URL) -> MonitorHold? {
        guard let data = try? Data(contentsOf: url(stateDir: stateDir)) else { return nil }
        return try? JSONDecoder().decode(MonitorHold.self, from: data)
    }

    public static func save(_ hold: MonitorHold, stateDir: URL) throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(hold)
        try data.write(to: url(stateDir: stateDir), options: .atomic)
    }

    /// resume。ファイルが無くても成功(冪等)。戻り値 = 消す前に active だったか(status 表示用)
    @discardableResult
    public static func clear(stateDir: URL, now: Date = Date()) -> Bool {
        let wasActive = load(stateDir: stateDir)?.isActive(now: now) ?? false
        try? FileManager.default.removeItem(at: url(stateDir: stateDir))
        return wasActive
    }

    /// 人向けの1行(status と monitor の stderr が共用)
    public func describe(now: Date = Date()) -> String {
        guard let until else { return "held until `ftester monitor resume`" }
        let remaining = Int(until - now.timeIntervalSince1970)
        return remaining > 0
            ? "held for another \(remaining)s (until \(Date(timeIntervalSince1970: until)))"
            : "expired (a new cycle resumes on its own)"
    }
}
