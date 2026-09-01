// FM(Foundation Models)呼び出しのホスト単位の許可枠(セマフォ)。
//
// 導入時の前提(2026-07-22 実測): スループットは並列度によらず約1回/秒で頭打ち、レイテンシは
// 並列度にほぼ正比例(docs/performance-tuning.md §FM)。14 ワーカーから同時に投げても速くならず、
// modelmanagerd のモデル積み降ろし(unloadIfNeededToMakeRoom)だけが増えるので、呼び出し側で
// 待ち行列を明示してそれを止めるのがこのロックの目的だった。**このとき枠数を 1 にした**。
//
// **この前提は 2026-09-01(macOS 27.0)の実測では再現していない**。`fleetest doctor --fm-load`
// (この門を通さずに直接叩く)で: text = 並列度1 で 2.66 回/秒 → 5 で 7.81 → 10 で 7.58、
// vision = 1.83 → 4.62 → 4.93。**頭打ちの「形」(並列度5で飽和・以降はレイテンシだけ伸びる)は
// あるが、水準が数倍違う**。つまり run 中に見えていた約1回/秒は FM の天井ではなく**枠 1 の
// ロックの上限**だった。E2E(8レーン・occlusion guard 有効)でも実測: FM 実働 113.6 秒に対し
// ゲート待ちの合計 204.8 秒(実働の 180%)・最大待ち 19,285ms(timeout 20 秒まで 0.7 秒)。
// **枠数 5 の根拠**(2026-09-01。3機で並列度 1..8 を掃引 + E2E で実測):
//
//   ① 掃引(`doctor --fm-load`、ピーク比): 並列度3 で local 87% / M1Ultra 93% / M1Max 99%、
//      並列度5 で3機とも 100%、6〜8 は横ばいでレイテンシだけ伸びる。
//      **絶対性能は機械間で 1.9 倍違う**(local 7.62 / M1Ultra 5.50 / M1Max 4.11 回/秒)**のに、
//      飽和する並列度は 3〜5 で一致する** —— 変動するのは天井であって膝ではない。
//      だから**機械ごとに枠数を変える機構(ハードウェアからの導出・校正・実行時適応)は置かない**。
//      新しい世代で膝が動いたらこの掃引をやり直すこと(同じコマンドで再現できる)。
//   ② 実 run(E2E-CMP・8レーン・occlusion guard 有効)で「ゲート待ち + FM 実働」= レーンが FM で
//      止まった総時間: 枠1 318.4s / 枠3 238.3s / **枠5 217.0s**。枠3 は待ちが 56.9 秒残る。
//      **待ちとレイテンシはトレードオフなので、片方だけを見ると必ず誤る**(掃引だけなら
//      「3 で 87〜99% 出るから 3 で十分」と読めるが、実 run では待ちの解消が勝った)。
//
// **外すなら多い側に外す**: 少なすぎると待ちが積み上がり、最悪 timeout で guard が黙って
// 素通りする(枠1 の実測で最大待ち 19,285ms = timeout 20 秒まで 0.7 秒)。多すぎても
// スループットは平らなままレイテンシが伸びるだけ。
//
// ロックは**リポジトリ単位ではなくホスト単位**(FM がホスト単位の資源のため。別リポジトリの
// fleetest プロセスとも枠を共有する必要がある)。ファイルは
// ~/Library/Caches/fleetest/fm.lock.<slot>(slot は 0..<concurrency)。
// **旧版(単数の fm.lock)とは枠を共有しない** —— 版混在(古い fleetest が同時に走っている)では
// 直列化の効果が薄れるが、この混在自体を避けるのが前提(CLAUDE.md の版合わせ)。
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
    /// FM 1 回は実測 1〜4 秒なので、枠5でも通常はこの範囲に収まる
    public static let defaultTimeoutSeconds: TimeInterval = 20

    /// 既定の枠数。根拠はファイル冒頭コメントの 2026-09-01 実測(スループットが飽和する
    /// 最小の並列度)。`FT_FM_CONCURRENCY` で上書きできる(不正値・0 以下は既定へ倒す)
    public static let defaultConcurrency = 5

    /// テストだけが使う差し替え口。**production は常に nil**(`FT_FM_CONCURRENCY` を見る)。
    /// fd を concurrency 本ぶんキャッシュするため、テストがこれを変えたら
    /// `resetForTesting()` も呼んでキャッシュを作り直させること
    static var concurrencyForTesting: Int?

    /// 解決順は **環境変数 → 設定ファイル → 既定**。
    /// 環境変数はリモートのディスパッチが運ぶ値(登録簿 `RemoteHostEntry.fmConcurrency`)で、
    /// 設定ファイルは**この機械**のぶん(`LocalConfig.fmConcurrency`。"local" は登録簿の予約名なので
    /// 手元だけ別の置き場になる)。どちらも無ければ既定
    static var concurrency: Int {
        if let concurrencyForTesting { return concurrencyForTesting }
        return resolveConcurrency(
            environment: ProcessInfo.processInfo.environment,
            configured: LocalConfig.load().fmConcurrency)
    }

    /// 枠数の解決そのもの。**純粋関数にしてあるのはテストのため** —— `concurrency` は
    /// `LocalConfig.load()` で**この機械の実ファイル**を読むので、設定ファイル経路(GUI が書く経路)を
    /// テストから通せない。実際にホストの設定が既定と同じ値だと
    /// `testInvalidConcurrencyEnvFallsBackToDefault` のような検証が**素通り**する。
    /// 不正な環境変数は設定ファイルへ落ちる(既定へ直行しない)。
    static func resolveConcurrency(environment: [String: String], configured: Int?) -> Int {
        if let raw = environment["FT_FM_CONCURRENCY"], let n = Int(raw), n > 0 { return n }
        if let n = configured, n > 0 { return n }
        return defaultConcurrency
    }

    private static let stateLock = NSLock()
    /// プロセス内で現在保持中の枠番号(0..<concurrency)。**枠は交換可能** —— acquire/leave は
    /// 個数さえ対応していればどれを返しても正しいので、release は先着順を問わず popLast() で
    /// 1つ返す(呼び出し元の FMGate は取った枠を覚えず defer { leave() } するだけの契約のため)
    private static var heldSlots: [Int] = []
    private static var cachedFDs: [Int32]?
    private static var cachedConcurrency: Int?

    private static func lockURL(slot: Int) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("fleetest", isDirectory: true)
            .appendingPathComponent("fm.lock.\(slot)")
    }

    /// concurrency 本ぶんの fd(プロセスで 1 回だけ開く)。1本でも開けなければ nil = **fail open**
    /// (ロックファイルの問題で FM 機能そのものを殺さない)
    private static func descriptors() -> [Int32]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let n = concurrency
        if let cachedFDs, cachedConcurrency == n { return cachedFDs }
        cachedFDs?.forEach { close($0) }
        cachedFDs = nil
        heldSlots.removeAll()

        try? FileManager.default.createDirectory(
            at: lockURL(slot: 0).deletingLastPathComponent(), withIntermediateDirectories: true)
        var fds: [Int32] = []
        for slot in 0..<n {
            let fd = open(lockURL(slot: slot).path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else {
                fds.forEach { close($0) }
                return nil
            }
            fds.append(fd)
        }
        cachedFDs = fds
        cachedConcurrency = n
        return fds
    }

    /// 取得できたら true。timeout したら false(呼び出し側は FM をスキップする)。
    /// **無効時・ロックファイルを開けないときは true**(素通り)
    public static func acquire(timeoutSeconds: TimeInterval = defaultTimeoutSeconds) async -> Bool {
        guard isEnabled, let fds = descriptors() else { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if tryAcquire(fds) != nil { return true }
            if Date() >= deadline { return false }
            // ポーリング(flock のブロッキング待ちは協調スレッドを塞ぐので使わない)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// **同一プロセス内の排他も要る**: flock は open file description 単位なので、
    /// 同じ fd を共有する別スレッドからの LOCK_EX は既に保持済みとして即成功してしまう。
    /// 枠ごとに「このプロセスが既に持っているか」を heldSlots で見てから試す
    private static func tryAcquire(_ fds: [Int32]) -> Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        for (slot, fd) in fds.enumerated() where !heldSlots.contains(slot) {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            heldSlots.append(slot)
            return slot
        }
        return nil
    }

    public static func release() {
        guard isEnabled, let fds = descriptors() else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let slot = heldSlots.popLast() else { return }
        _ = flock(fds[slot], LOCK_UN)
    }

    /// テストだけが使う: `concurrencyForTesting` を変えたあと fd キャッシュを畳んで
    /// 作り直させる(同一プロセス内で枠数を差し替えるための口)
    static func resetForTesting() {
        stateLock.lock()
        defer { stateLock.unlock() }
        cachedFDs?.forEach { close($0) }
        cachedFDs = nil
        cachedConcurrency = nil
        heldSlots.removeAll()
    }
}
