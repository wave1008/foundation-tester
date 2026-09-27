// api monitor のストレージ計測(monitorDevices[].storage)を配信周期から切り離す。
// 周期は schedule()(更新の要求があれば台を裏のキューへ積むだけ・待たない)と snapshot()(控えを読む)しか呼ばない。
// **測る契機は利用者の更新ボタンだけ**(ユーザー決定。stdin の storageRefresh → requestRefresh)。
// 間隔・台の起動し直し・モニターの起動・run の有無では測らない/止めない。
// **周期の中で計測を await しない**: iOS Simulator の走査は並列でも 1 台数秒(単一スレッドの du は
// 27〜35 秒)かかり、周期内で待つとタイル・凍結判定が止まる。計測は同期呼び出し(Android は Shell.run・
// iOS はスレッドを待つ)なので Swift の協調スレッドにも載せない(専用の DispatchQueue)。
// **測れた値は storeURL(~/.fleetest/device-storage.json)へ残し、起動時に読む**(carriedOver: true =
// 拡張は灰色)。メモリだけだとモニターが起動し直すたびに全台が空に戻る。

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

final class DeviceStorageSampler: @unchecked Sendable {
    typealias Probe = @Sendable (String) -> DeviceStorageInfo?

    private let lock = NSLock()
    private var cache: [String: DeviceStorageInfo] = [:]
    private var inFlight: Set<String> = []
    /// 更新ボタンが押され、次の schedule で積む
    private var refreshRequested = false
    /// iOS は 1 台ずつ(1 台の走査が既にコア数の半分のスレッドを使う。台も並列にすると I/O が重なる)
    private let iosQueue = DispatchQueue(label: "fleetest.monitor.storage.ios", qos: .utility)
    private let androidQueue = DispatchQueue(label: "fleetest.monitor.storage.android", qos: .utility)
    private let probeIOS: Probe
    private let probeAndroid: Probe
    /// 前回値の置き場。nil = 読まない・書かない(テスト)。**既定値を置かない**(production の渡し忘れを
    /// コンパイルで止める)
    private let storeURL: URL?
    /// 書き込みの順序を保つ(iOS と Android のキューが同時に終えると、古い控えを後から書きうる)
    private let storeWriteLock = NSLock()
    /// 1台の計測が終わるたび(測れなかった回も)、測定中から外して値を入れた**後**に計測キューのスレッドで呼ぶ。
    /// モニターはここで monitorStorage を出す(周期を待たずに終わった台から画面を変える)
    private let onMeasured: @Sendable (String) -> Void

    init(probeIOS: @escaping Probe, probeAndroid: @escaping Probe, storeURL: URL?,
         onMeasured: @escaping @Sendable (String) -> Void) {
        self.probeIOS = probeIOS
        self.probeAndroid = probeAndroid
        self.storeURL = storeURL
        self.onMeasured = onMeasured
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode([String: DeviceStorageInfo].self, from: data) {
            cache = stored.mapValues { info in
                var carried = info
                carried.carriedOver = true
                return carried
            }
        }
    }

    /// 利用者の更新ボタン。次の schedule でその時点の候補を全台積む
    func requestRefresh() {
        lock.lock(); refreshRequested = true; lock.unlock()
    }

    /// candidates = 動いている仮想デバイス(key = udid / serial)。更新の要求が無ければ何もしない。
    /// **計測中の台は積まない**(同じ台を二重に歩かない。その台は進行中の計測の値になる)。
    /// 戻り値 = 今回積んだ台(モニターはすぐ「測定中」を知らせる)
    @discardableResult
    func schedule(candidates: [(key: String, platform: String)]) -> [String] {
        var jobs: [(key: String, isIOS: Bool)] = []
        lock.lock()
        if refreshRequested {
            refreshRequested = false
            for candidate in candidates where !inFlight.contains(candidate.key) {
                inFlight.insert(candidate.key)
                jobs.append((candidate.key, candidate.platform == "ios"))
            }
        }
        lock.unlock()
        for job in jobs {
            (job.isIOS ? iosQueue : androidQueue).async { [self] in
                finish(key: job.key, info: job.isIOS ? probeIOS(job.key) : probeAndroid(job.key))
            }
        }
        return jobs.map(\.key)
    }

    /// 測れなかった回は前回値を残す(0 で埋めない)
    private func finish(key: String, info: DeviceStorageInfo?) {
        lock.lock()
        inFlight.remove(key)
        if let info { cache[key] = info }
        lock.unlock()
        if info != nil { persist() }
        onMeasured(key)
    }

    /// 書き込み失敗は握りつぶす(控えのために計測も配信も止めない)。控えは書く直前に取る(順序は storeWriteLock)
    private func persist() {
        guard let storeURL else { return }
        storeWriteLock.lock()
        defer { storeWriteLock.unlock() }
        let current = snapshot()
        guard let data = try? JSONEncoder().encode(current) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    /// 値と計測中の台を同じロックで読む(別々に読むと、間で終わった台が「古い値のまま測定中でない」に見える)
    func progressSnapshot() -> (values: [String: DeviceStorageInfo], measuring: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        return (cache, inFlight)
    }

    func snapshot() -> [String: DeviceStorageInfo] {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    /// 居なくなった台の控えを捨てる(health/renderMode キャッシュと同じ規律)
    func forget(keysNotIn live: Set<String>) {
        lock.lock()
        for key in Set(cache.keys).subtracting(live) {
            cache.removeValue(forKey: key)
        }
        lock.unlock()
    }
}
