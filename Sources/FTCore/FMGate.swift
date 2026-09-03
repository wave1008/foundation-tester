// FM 呼び出しの入場ゲート。**全ての FM 呼び出しはここを通す**(監査点を1つに保つ)。
//
// 2つの関門を順に見る:
//  1. サーキットブレーカ(FMBreaker): FM が死んでいるなら呼ばない
//  2. 直列化ロック(FMLock): FM はホスト全体で直列化される資源なので待ち行列を作る
//
// ブレーカの根拠(2026-07-27 実測): FM は**累積 20〜30 回の呼び出しで死に、以後プロセスを
// 変えても再起動まで回復しない**。直列化しても崩壊は防げなかった(docs/verification.md)。
// 死んだ後も呼び続けると、1 回あたり 0.2〜4 秒を捨て続ける(実測: 全滅 run の 1554 シナリオで
// 合計 31 分)。「死んだら止める」が唯一効く対策。
//
// **再起動は cooldown より強い回復の根拠**: マシン再起動を跨いだトリップは無効(状態ファイルは
// .cachesDirectory で再起動を生き延びるため、放っておくと再起動後も cooldown 経過まで死んだまま扱う)。

import Foundation

public enum FMGate {
    /// FM を 1 回呼んでよいか。true を返したら **`defer { leave() }` で必ず返す**(推奨ではなく必須)。
    /// FTSync のコマンド上限(既定120秒)は超過時に op を cancel するので、**この後の任意の await 点で
    /// 巻き戻り得る**。素の `leave()` を末尾に置くと巻き戻りで飛ばされ、**ホスト全体で直列化される
    /// FM ロックを掴んだまま**になる = 他ワーカーの FM が acquire 上限まで待たされる。
    /// false のときは呼び出し側が nil を返してガードを素通りさせる(失敗時と同じ振る舞い)
    public static func enter() async -> Bool {
        if FMBreaker.isOpen {
            FMHealth.recordSkip()
            return false
        }
        // FT_FM_SERIALIZE=0 でも acquire は即 true を返す(FMLock.swift)。特別扱いせずそのまま
        // 測ることで、直列化あり/なしで待ちが出る/0になるという対照そのものが計測器の陽性対照になる
        let waitStartedAt = Date()
        guard await FMLock.acquire() else {
            FMHealth.recordSkip()
            return false
        }
        FMHealth.recordGateWait(ms: Date().timeIntervalSince(waitStartedAt) * 1000)
        return true
    }

    public static func leave() {
        FMLock.release()
    }
}

/// FM が死んだことを検知して以後の呼び出しを止めるサーキットブレーカ。
///
/// **ホスト単位**(ファイル経由)にしてある: FM の全滅はホスト全体の事象で、ワーカーは
/// プロセスが別なので、プロセス内カウンタだけだと 14 ワーカー × threshold 回を無駄打ちする。
/// 落ちた事実を共有すれば無駄打ちは threshold 回で終わる。
public enum FMBreaker {
    /// 連続でこの回数失敗したら落とす。単発の失敗(一過性)では落とさない
    public static let threshold = 3
    /// 落ちてからこの時間が過ぎたら 1 回だけ試させる(half-open)。
    /// FM は実測では再起動まで回復しないが、恒久停止にすると回復を検知できなくなる
    public static let cooldownSeconds: TimeInterval = 600

    /// FT_FM_BREAKER=0 で無効化(切り分け用の殺しスイッチ)
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FT_FM_BREAKER"] != "0"
    }

    private static let lock = NSLock()
    private static var consecutiveFailures = 0

    /// **テストだけが使う差し替え口**(production は nil)。状態はホスト単位の共有ファイルで、
    /// それ自体は意図どおり(ワーカーのプロセスを跨いで落ちた事実を伝える)。ところが
    /// テストを**プロセス並列**で走らせると、無関係なテストの `reset()` が同じファイルを消して
    /// 判定と competing する(実測: `swift test --parallel` で FMBreakerTests が必ず落ちる)。
    /// テスト側はプロセスごとの一時パスをここへ入れて隔離する
    static var stateURLForTesting: URL?

    /// **テストだけが使う差し替え口**(production は nil)。マシン再起動の判定に使う起動時刻を固定する
    static var bootTimeForTesting: Date?

    /// 本番の置き場。**ホスト単位で1つ**(ここが共有であること自体が仕様 —— 14 ワーカーが
    /// 別プロセスでも落ちた事実を共有できる)。パスの形はテストが I/O 抜きで表明する
    static var defaultStateURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("fleetest", isDirectory: true)
            .appendingPathComponent("fm-breaker.state")
    }

    private static var stateURL: URL { stateURLForTesting ?? defaultStateURL }

    /// マシンが最後に起動した時刻。kern.boottime は**スリープでは変わらず、実際の再起動でだけ進む**
    /// (ProcessInfo.systemUptime はスリープ中止まる実装があり、起動時刻の逆算に使うとスリープの
    /// たびに「再起動した」と誤判定する)。取得できなければ nil(呼び出し側は cooldown へフォールバック)
    private static var machineBootTime: Date? {
        if let override = bootTimeForTesting { return override }
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000)
    }

    /// 落ちているか(= FM を呼ばない)。cooldown を過ぎていれば閉じたとみなして 1 回試させる。
    /// トリップがマシン起動より前(= 前回起動セッションの記録)なら、それ自体が無効
    /// (再起動は cooldown より強い回復の根拠。ファイル冒頭)なので状態ファイルごと捨てて閉じたとみなす
    public static var isOpen: Bool {
        guard isEnabled else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
              let trippedAt = attrs[.modificationDate] as? Date else { return false }
        if let bootTime = machineBootTime, trippedAt < bootTime {
            try? FileManager.default.removeItem(at: stateURL)
            return false
        }
        return Date().timeIntervalSince(trippedAt) < cooldownSeconds
    }

    /// FM が答えを返せた。連続失敗カウンタを戻し、落ちていたら復帰させる
    public static func recordSuccess() {
        guard isEnabled else { return }
        lock.lock()
        consecutiveFailures = 0
        lock.unlock()
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// FM が失敗した。threshold に達したら落とす
    public static func recordFailure() {
        guard isEnabled else { return }
        lock.lock()
        consecutiveFailures += 1
        let shouldTrip = consecutiveFailures >= threshold
        lock.unlock()
        guard shouldTrip else { return }
        let url = stateURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 中身は使わない(mtime が落ちた時刻)。既にあれば mtime を更新する
        try? Data().write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// テスト用。ホスト単位の状態を消す
    public static func reset() {
        lock.lock()
        consecutiveFailures = 0
        lock.unlock()
        try? FileManager.default.removeItem(at: stateURL)
    }
}
