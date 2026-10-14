// 接頭辞(ワークスペース)ごとの短い排他(docs/remote-runner.md §17「調停」)。
// `<stateDir>/services.lock/<prefix>.lock` を flock(LOCK_EX)で取る。持ち主が死ねばカーネルが外すので回収の処理が無く、
// **他者の取得を消す操作が存在しない**(mkdir の「死んだ持ち主を照合 → パスで削除」は、照合と削除の間に別の取得が入ると
// 他者のロックを消して 2 者が同時に本体へ入れた)。ファイルの中身(pid と開始時刻)は `services status` の表示用で、排他ではない。
// 守るのはサービスの作成・片付けの区間だけ(秒単位)。run 全体の排他は dispatch.lock が持つ。

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
    /// 30 秒を超えて握っているのは刺さった持ち主(死んだ持ち主の分はカーネルが外している)。尽きたとき = 持ち主の pid を言って止める。
    static let acquireTimeoutSeconds: Double = 30
    static let pollSeconds: Double = 0.2

    static func lockFile(prefix: String, stateDir: URL) -> URL {
        stateDir.appendingPathComponent("services.lock").appendingPathComponent(prefix + ".lock")
    }

    static func withLock<T>(
        prefix: String, stateDir: URL,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        pidStartedAt: String? = nil,
        timeoutSeconds: Double = ServicesLock.acquireTimeoutSeconds,
        pollSeconds: Double = ServicesLock.pollSeconds,
        body: () throws -> T
    ) throws -> T {
        let file = lockFile(prefix: prefix, stateDir: stateDir)
        let owner = Owner(pid: pid, pidStartedAt: pidStartedAt ?? ServicesProcessIdentity.startedAtText(pid: pid))
        let fd = try acquire(file: file, owner: owner, timeoutSeconds: timeoutSeconds, pollSeconds: pollSeconds)
        defer { release(fd: fd) }
        return try body()
    }

    /// 現在の持ち主(握られていなければ nil。握られているが持ち主がまだ書かれていない瞬間は pid 0)。`services status` が使う。
    /// 判定は flock の状態(中身は表示用。持ち主が死んで中身が残っていても、握られていなければ nil)
    static func currentHolder(prefix: String, stateDir: URL) -> (pid: Int32, startedAt: String)? {
        let file = lockFile(prefix: prefix, stateDir: stateDir)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        guard let owner = readOwner(file) else { return (0, "") }
        return (owner.pid, owner.pidStartedAt)
    }

    // MARK: - 内部

    private static func acquire(file: URL, owner: Owner, timeoutSeconds: Double, pollSeconds: Double) throws -> Int32 {
        let parent = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ServicesError(phase: .lock, detail: "cannot create \(parent.path): \(error.localizedDescription)")
        }
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw ServicesError(phase: .lock, detail: "cannot open the lock \(file.path): \(String(cString: strerror(errno)))")
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                writeOwner(owner, to: fd)
                return fd
            }
            if errno != EWOULDBLOCK {
                let reason = String(cString: strerror(errno))
                close(fd)
                throw ServicesError(phase: .lock, detail: "cannot lock \(file.path): \(reason)")
            }
            if Date() >= deadline {
                let holder = readOwner(file).map { "pid \($0.pid)" } ?? "unknown"
                close(fd)
                throw ServicesError(phase: .lock, detail: "timed out after \(Int(timeoutSeconds))s waiting for the services lock held by \(holder) (\(file.path))")
            }
            Thread.sleep(forTimeInterval: pollSeconds)
        }
    }

    private static func release(fd: Int32) {
        ftruncate(fd, 0)  // 持ち主の表示を消す(読み手は flock の状態を先に見るので、空でも判定は変わらない)
        flock(fd, LOCK_UN)
        close(fd)
    }

    private static func writeOwner(_ owner: Owner, to fd: Int32) {
        guard let data = try? JSONEncoder().encode(owner) else { return }
        ftruncate(fd, 0)
        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }

    private static func readOwner(_ file: URL) -> Owner? {
        guard let data = FileManager.default.contents(atPath: file.path), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Owner.self, from: data)
    }
}
