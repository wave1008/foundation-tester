// iOS Simulator の「Shutdown → Booted」を機械全体で同時 N 台にする枠。FMCallSlots と同じ方式
// (枠ごとの ~/Library/Caches/fleetest/sim-boot.lock.<slot> へ flock(LOCK_EX|LOCK_NB))で、クローンもプロセスもまたいで共有する。
// プロセスが死ねば flock は外れる。fd はプロセスで1回だけ開く。開けなければ fail open(枠なしで通す)。
// 入口は `SimulatorBoot.ensureBooted(udid:log:)` だけ。

import FTCore
import Foundation
import Synchronization

public enum SimulatorBootSlots {
    /// 同時に起動してよい台数。ユーザー決定(`DeviceBooter.bootAll` の同時2台と同じ値)。
    /// 5台の一斉起動で空きメモリが 59.5GB → 0.7GB に尽き FM が死んだ → maintainer-notes §97。設定・環境変数の口は置かない
    public static let concurrency = 2

    /// 待ちの上限は置かない(`bootstatus -b` 自体に上限が無い。持ち主が死ねば flock が外れる)。
    /// 200ms は枠が空いてから気付くまでの遅れの上限で、起動 1 台(数十秒)に対して無視できる
    static let pollIntervalMicroseconds: UInt32 = 200_000

    private struct State {
        /// このプロセスが持っている枠 → その枠で起動している udid(返すときは自分の udid の枠を返す = 持ち主の表示がずれない)
        var heldSlots: [Int: String] = [:]
        var cachedFDs: [Int32]?
        var lockDirectory: URL?
    }
    private static let state = Mutex(State())

    /// テストだけが使う置き場の差し替え口(本物の枠を奪い/奪われないため)。差し替えたら `resetForTesting()` も呼ぶ
    static var lockDirectoryForTesting: URL? {
        get { state.withLock { $0.lockDirectory } }
        set { state.withLock { $0.lockDirectory = newValue } }
    }

    private static func lockURL(slot: Int, directory: URL?) -> URL {
        if let directory { return directory.appendingPathComponent("sim-boot.lock.\(slot)") }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? TemporaryDirectory.url
        return base.appendingPathComponent("fleetest", isDirectory: true)
            .appendingPathComponent("sim-boot.lock.\(slot)")
    }

    /// state を握ったまま呼ぶ
    private static func descriptors(_ st: inout State) -> [Int32]? {
        if let cached = st.cachedFDs { return cached }
        let first = lockURL(slot: 0, directory: st.lockDirectory)
        try? FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        var fds: [Int32] = []
        for slot in 0..<concurrency {
            let fd = open(lockURL(slot: slot, directory: st.lockDirectory).path,
                          O_CREAT | O_NOFOLLOW | O_RDWR, 0o644)
            guard fd >= 0 else {
                fds.forEach { close($0) }
                return nil
            }
            fds.append(fd)
        }
        st.cachedFDs = fds
        return fds
    }

    /// 待たずに1回だけ試す。取れたら true(呼び手が `release()` で返す)。ロックファイルを開けないときも true(fail open)。
    /// **同一プロセス内の排他も要る**: flock は open file description 単位で、同じ fd への別スレッドの LOCK_EX は即成功する
    /// ので、このプロセスが持っている枠は heldSlots で除く
    public static func acquireWithoutWaiting(udid: String) -> Bool {
        state.withLock { st in
            guard let fds = descriptors(&st) else { return true }
            for (slot, fd) in fds.enumerated() where st.heldSlots[slot] == nil {
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
                st.heldSlots[slot] = udid
                let owner = Array("\(getpid()) \(udid)\n".utf8)
                _ = ftruncate(fd, 0)
                _ = pwrite(fd, owner, owner.count, 0)
                return true
            }
            return false
        }
    }

    /// 取れるまで待つ。待ちに入ったときと取れたときに1行ずつ出す
    public static func acquire(udid: String, log: (String) -> Void) {
        if acquireWithoutWaiting(udid: udid) { return }
        let start = Date()
        let holders = owners()
        log("waiting for a simulator boot slot (\(concurrency) at a time on this machine; held by: "
            + (holders.isEmpty ? "unknown" : holders.joined(separator: ", ")) + ")")
        while !acquireWithoutWaiting(udid: udid) {
            usleep(pollIntervalMicroseconds)
        }
        log("got a simulator boot slot after \(Int(Date().timeIntervalSince(start))) s")
    }

    /// `udid` で取った枠を返す(取っていなければ何もしない = fail open で枠なしに通った回)
    public static func release(udid: String) {
        state.withLock { st in
            guard let fds = descriptors(&st),
                  let slot = st.heldSlots.first(where: { $0.value == udid })?.key else { return }
            st.heldSlots[slot] = nil
            _ = ftruncate(fds[slot], 0)
            _ = flock(fds[slot], LOCK_UN)
        }
    }

    /// 各枠のファイルに書かれた `pid udid`(ログ用。空き・読めない枠は含めない)
    static func owners() -> [String] {
        let directory = state.withLock { $0.lockDirectory }
        return (0..<concurrency).compactMap { slot in
            guard let text = try? String(contentsOf: lockURL(slot: slot, directory: directory), encoding: .utf8)
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// テストだけが使う: fd のキャッシュを畳み、保持中の枠も手放す
    static func resetForTesting() {
        state.withLock {
            $0.cachedFDs?.forEach { close($0) }
            $0.cachedFDs = nil
            $0.heldSlots = [:]
        }
    }
}
