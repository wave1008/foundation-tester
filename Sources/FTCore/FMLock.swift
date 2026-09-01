// FM(Foundation Models)呼び出しのホスト単位の直列化。
//
// 導入時の前提(2026-07-22 実測): スループットは並列度によらず約1回/秒で頭打ち、レイテンシは
// 並列度にほぼ正比例(docs/performance-tuning.md §FM)。14 ワーカーから同時に投げても速くならず、
// modelmanagerd のモデル積み降ろし(unloadIfNeededToMakeRoom)だけが増えるので、呼び出し側で
// 待ち行列を明示してそれを止めるのがこのロックの目的だった。
//
// **この前提は 2026-09-01(macOS 27.0)の実測では再現していない**。`fleetest doctor --fm-load`
// (この門を通さずに直接叩く)で: text = 並列度1 で 2.66 回/秒 → 5 で 7.81 → 10 で 7.58、
// vision = 1.83 → 4.62 → 4.93。**頭打ちの「形」(並列度5で飽和・以降はレイテンシだけ伸びる)は
// 同じだが、水準が数倍違う**。つまり run 中に見える約1回/秒は FM の天井ではなく**このロックの
// 上限**で、FM 側にはまだ3倍前後の余地がある。緩める判断はしていない —— 緩めると
// modelmanagerd の積み降ろしと FM の間欠死([[fm-flap-ane-load-failure]])に触れるので、
// **変えるなら FM 重い run の実測(E2E の壁時計)で確かめること**。
//
// ロックは**リポジトリ単位ではなくホスト単位**(FM がホスト単位の資源のため。別リポジトリの
// fleetest プロセスとも直列化する必要がある)。ファイルは ~/Library/Caches/fleetest/fm.lock。
//
// 取得できないまま timeout したら **FM 呼び出しをスキップする**(呼び出し側は nil を返して
// ガードを素通りさせる = 失敗時と同じ振る舞い)。全ワーカーが待ち行列に並ぶと最後尾の待ちが
// 積み上がり、シナリオの壁時計タイムアウトを超えうるため、この安全弁は外せない。
//
// FT_FM_SERIALIZE=0 で無効化できる(A/B 計測用の殺しスイッチ。無効時 acquire は常に true)。

import Foundation

public enum FMLock {
    /// 直列化が有効か。FT_FM_SERIALIZE=0 のときだけ無効
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FT_FM_SERIALIZE"] != "0"
    }

    /// 待ち行列の最後尾が待つ上限。超えたら諦めて FM をスキップする。
    /// FM 1 回は実測 1〜4 秒なので、10 並列でも通常はこの範囲に収まる
    public static let defaultTimeoutSeconds: TimeInterval = 20

    private static let stateLock = NSLock()
    private static var heldInProcess = false
    private static var cachedFD: Int32?

    private static var lockURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("fleetest", isDirectory: true)
            .appendingPathComponent("fm.lock")
    }

    /// ロックファイルの fd(プロセスで 1 本だけ開く)。開けなければ nil = **fail open**
    /// (ロックファイルの問題で FM 機能そのものを殺さない)
    private static func descriptor() -> Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let cachedFD { return cachedFD }
        let url = lockURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        cachedFD = fd
        return fd
    }

    /// 取得できたら true。timeout したら false(呼び出し側は FM をスキップする)。
    /// **無効時・ロックファイルを開けないときは true**(素通り)
    public static func acquire(timeoutSeconds: TimeInterval = defaultTimeoutSeconds) async -> Bool {
        guard isEnabled, let fd = descriptor() else { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if tryAcquire(fd) { return true }
            if Date() >= deadline { return false }
            // ポーリング(flock のブロッキング待ちは協調スレッドを塞ぐので使わない)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// **同一プロセス内の排他も要る**: flock は open file description 単位なので、
    /// 同じ fd を共有する別スレッドからの LOCK_EX は既に保持済みとして即成功してしまう
    private static func tryAcquire(_ fd: Int32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !heldInProcess else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        heldInProcess = true
        return true
    }

    public static func release() {
        guard isEnabled, let fd = descriptor() else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard heldInProcess else { return }
        _ = flock(fd, LOCK_UN)
        heldInProcess = false
    }
}
