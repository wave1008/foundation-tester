// 接頭辞(ワークスペース)ごとの短い排他(docs/remote-runner.md §17「調停」)。
// `<stateDir>/services.lock/<prefix>/` を mkdir(原子的)で取り、rmdir で放す。中の `owner` に pid と開始時刻。
// 守るのはサービスの作成・片付けの区間だけ(秒単位)。run 全体の排他は dispatch.lock が持つ。
// **生きている持ち主のロックを外す経路は置かない**(照合と削除が原子的でなく、取り直した別の持ち主のロックを消す)。
// 死んだ持ち主と持ち主の記録が無い古いロックは `acquire` が回収する。

import FTCore
import Foundation

/// pid + 開始時刻の記録と生存判定(控えとロックで共有)。pid の再利用で別のプロセスを「生きている」と見ない。
enum ServicesProcessIdentity {
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    static func text(for date: Date) -> String { formatter().string(from: date) }

    /// そのプロセスの開始時刻(読めなければ今)。
    static func startedAtText(pid: Int32) -> String {
        text(for: ProcessLiveness.startTime(pid) ?? Date())
    }

    /// 開始時刻が読めない・記録が解釈できないときは pid だけで見る(不明を死にしない)。
    static func isAlive(pid: Int32, startedAt: String) -> Bool {
        guard pid > 0 else { return false }
        guard let recorded = formatter().date(from: startedAt) else { return ProcessLiveness.isAlive(pid) }
        return ProcessLiveness.isAliveAndNotStartedAfter(pid, recordedAt: recorded)
    }
}

enum ServicesLock {
    private struct Owner: Codable {
        let pid: Int32
        let pidStartedAt: String
    }

    /// 取れないときの待ちの上限(秒)。根拠: 作成と片付けは数秒で終わる(§17 の実測: 起動 1〜3 秒)ので、
    /// 30 秒を超えて握っているのは死んだ持ち主か刺さった片付け。
    /// 尽きたとき = 持ち主の pid を言って止める。
    static let acquireTimeoutSeconds: Double = 30
    static let pollSeconds: Double = 0.2

    /// 持ち主の記録がまだ無いロック(mkdir と owner の書き込みの間)を「作り途中」とみなす猶予(秒)。
    /// 根拠: 書き込みは mkdir の直後でマイクロ秒。これを超えて無いなら作った側が間で死んでいる。
    static let ownerFileGraceSeconds: Double = 5

    static func lockDirectory(prefix: String, stateDir: URL) -> URL {
        stateDir.appendingPathComponent("services.lock").appendingPathComponent(prefix)
    }

    static func withLock<T>(
        prefix: String, stateDir: URL,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        pidStartedAt: String? = nil,
        timeoutSeconds: Double = ServicesLock.acquireTimeoutSeconds,
        pollSeconds: Double = ServicesLock.pollSeconds,
        isAlive: (Int32, String) -> Bool = ServicesProcessIdentity.isAlive,
        body: () throws -> T
    ) throws -> T {
        let dir = lockDirectory(prefix: prefix, stateDir: stateDir)
        let owner = Owner(pid: pid, pidStartedAt: pidStartedAt ?? ServicesProcessIdentity.startedAtText(pid: pid))
        try acquire(dir: dir, owner: owner, timeoutSeconds: timeoutSeconds, pollSeconds: pollSeconds, isAlive: isAlive)
        defer { release(dir: dir, owner: owner) }
        return try body()
    }

    /// 現在の持ち主(無ければ nil)。`services status` が使う。
    static func currentHolder(prefix: String, stateDir: URL) -> (pid: Int32, startedAt: String)? {
        guard let owner = readOwner(lockDirectory(prefix: prefix, stateDir: stateDir)) else { return nil }
        return (owner.pid, owner.pidStartedAt)
    }

    // MARK: - 内部

    private static func acquire(dir: URL, owner: Owner, timeoutSeconds: Double, pollSeconds: Double,
                                isAlive: (Int32, String) -> Bool) throws {
        let parent = dir.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ServicesError(phase: .lock, detail: "cannot create \(parent.path): \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastHolder = "unknown"
        while true {
            if mkdir(dir.path, 0o755) == 0 {
                if let data = try? JSONEncoder().encode(owner),
                   (try? data.write(to: ownerFile(dir), options: .atomic)) != nil {
                    return
                }
                rmdir(dir.path)  // 持ち主を書けないロックは残さない
                throw ServicesError(phase: .lock, detail: "cannot record the owner in \(dir.path)")
            }
            if errno != EEXIST {
                throw ServicesError(phase: .lock, detail: "cannot create the lock \(dir.path): \(String(cString: strerror(errno)))")
            }
            if let current = readOwner(dir) {
                lastHolder = "pid \(current.pid)"
                if !isAlive(current.pid, current.pidStartedAt) {
                    reclaimIfStillOwnedBy(current, dir: dir)  // 回収したら次の周で mkdir を試す
                    if !FileManager.default.fileExists(atPath: dir.path) { continue }
                }
            } else if lockAge(dir) > ownerFileGraceSeconds {
                try? FileManager.default.removeItem(at: dir)
                if !FileManager.default.fileExists(atPath: dir.path) { continue }
            }
            if Date() >= deadline {
                throw ServicesError(phase: .lock, detail: "timed out after \(Int(timeoutSeconds))s waiting for the services lock held by \(lastHolder) (\(dir.path))")
            }
            Thread.sleep(forTimeInterval: pollSeconds)
        }
    }

    /// 回収の直前にもう一度読み、同じ死んだ持ち主のままのときだけ消す(別の run が回収して取り直した直後のロックを消さない。
    /// 読みと消しの間の窓は残る = 競合は mkdir を取れた側が勝つ)。
    private static func reclaimIfStillOwnedBy(_ stale: Owner, dir: URL) {
        guard let again = readOwner(dir), again.pid == stale.pid, again.pidStartedAt == stale.pidStartedAt else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    private static func release(dir: URL, owner: Owner) {
        // 自分のロックだけを外す(回収されて他人が取り直した後に、他人のロックを消さない)
        guard let current = readOwner(dir), current.pid == owner.pid, current.pidStartedAt == owner.pidStartedAt else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    private static func ownerFile(_ dir: URL) -> URL { dir.appendingPathComponent("owner") }

    private static func readOwner(_ dir: URL) -> Owner? {
        guard let data = FileManager.default.contents(atPath: ownerFile(dir).path) else { return nil }
        return try? JSONDecoder().decode(Owner.self, from: data)
    }

    private static func lockAge(_ dir: URL) -> Double {
        let attributes = try? FileManager.default.attributesOfItem(atPath: dir.path)
        guard let created = attributes?[.creationDate] as? Date else { return 0 }
        return Date().timeIntervalSince(created)
    }
}
