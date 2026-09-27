// api monitor のストレージ計測(monitorDevices[].storage)を配信周期から切り離す。
// 周期は schedule()(期限の来た台を裏のキューへ積むだけ・待たない)と snapshot()(控えを読む)しか呼ばない。
// **周期の中で計測を await しない**: iOS Simulator の走査は並列でも 1 台数秒(単一スレッドの du は
// 27〜35 秒)かかり、周期内で待つとタイル・凍結判定が止まる。計測は同期呼び出し(Android は Shell.run・
// iOS はスレッドを待つ)なので Swift の協調スレッドにも載せない(専用の DispatchQueue)。
// **測れた値は storeURL(~/.fleetest/device-storage.json)へ残し、起動時に読む** —— メモリだけだと
// モニターが起動し直すたびに全台が空に戻り、run 中は iOS を測らないので run が終わるまで空のままになる。

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

final class DeviceStorageSampler: @unchecked Sendable {
    typealias Probe = @Sendable (String) -> DeviceStorageInfo?

    private let lock = NSLock()
    private var cache: [String: DeviceStorageInfo] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    /// 直前の周期で動いていた台。動いていない → 動いている、の遷移を「起動し直した」とみなす
    private var lastConnected: Set<String> = []
    /// 計測中に起動し直した台。その計測(起動前の中身かもしれない)が終わっても期限を進めない
    private var remeasureAfterFlight: Set<String> = []
    /// iOS は 1 台ずつ(1 台の走査が既にコア数の半分のスレッドを使う。台も並列にすると I/O が重なり、同じ Mac の run に響く)
    private let iosQueue = DispatchQueue(label: "fleetest.monitor.storage.ios", qos: .utility)
    private let androidQueue = DispatchQueue(label: "fleetest.monitor.storage.android", qos: .utility)
    private let probeIOS: Probe
    private let probeAndroid: Probe
    /// この Mac で run が動いているか。iOS の計測は**実行の直前にも**確かめる(積んだ後に run が始まりうる)
    private let isRunActive: @Sendable () -> Bool
    /// 前回値の置き場。nil = 読まない・書かない(テスト)。**既定値を置かない**(production の渡し忘れを
    /// コンパイルで止める)
    private let storeURL: URL?
    /// 書き込みの順序を保つ(iOS と Android のキューが同時に終えると、古い控えを後から書きうる)
    private let storeWriteLock = NSLock()

    init(probeIOS: @escaping Probe, probeAndroid: @escaping Probe, isRunActive: @escaping @Sendable () -> Bool,
         storeURL: URL?) {
        self.probeIOS = probeIOS
        self.probeAndroid = probeAndroid
        self.isRunActive = isRunActive
        self.storeURL = storeURL
        // 読んだ値は表示に使うだけで期限(lastAttempt)には入れない —— 最初の周期の noteConnected が
        // 全台を「起動し直した」とみなして測り直すので、どのみち上書きされる
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode([String: DeviceStorageInfo].self, from: data) {
            cache = stored.mapValues { info in
                var carried = info
                carried.carriedOver = true
                return carried
            }
        }
    }

    /// candidates = connected な仮想デバイスのうち inRun でない台(key = udid / serial)。
    /// iOS は run が動いている間は積まない(期限はそのまま残り、run が終われば次の周期で積まれる)
    func schedule(candidates: [(key: String, platform: String)], now: Date) {
        var jobs: [(key: String, isIOS: Bool)] = []
        let runActive = isRunActive()
        lock.lock()
        for candidate in candidates where !inFlight.contains(candidate.key) {
            let isIOS = candidate.platform == "ios"
            if isIOS && runActive { continue }
            let interval = isIOS ? SimulatorStorageProbe.probeIntervalSeconds
                                 : AndroidStorageProbe.probeIntervalSeconds
            if let last = lastAttempt[candidate.key], now.timeIntervalSince(last) < interval { continue }
            inFlight.insert(candidate.key)
            jobs.append((candidate.key, isIOS))
        }
        lock.unlock()
        for job in jobs {
            (job.isIOS ? iosQueue : androidQueue).async { [self] in
                if job.isIOS && isRunActive() {
                    finish(key: job.key, info: nil, attempted: false)
                    return
                }
                let info = job.isIOS ? probeIOS(job.key) : probeAndroid(job.key)
                finish(key: job.key, info: info, attempted: true)
            }
        }
    }

    /// 周期ごとに動いている(connected / booted)台を渡す。**起動し直した台(動いていない → 動いている)は期限を捨てて
    /// 次の schedule で測り直す** —— 間隔(iOS 30 分)を待つと、起動前の掃除で減った量が表示に出るまで
    /// 最長 30 分かかる。ブリッジの再接続だけでも1回余分に測るが、まれなので許容する
    func noteConnected(keys: Set<String>) {
        lock.lock()
        for key in keys.subtracting(lastConnected) {
            lastAttempt.removeValue(forKey: key)
            if inFlight.contains(key) { remeasureAfterFlight.insert(key) }
        }
        lastConnected = keys
        lock.unlock()
    }

    /// 測れなかった回は前回値を残す(0 で埋めない)。撃たなかった回は期限も進めない
    private func finish(key: String, info: DeviceStorageInfo?, attempted: Bool) {
        lock.lock()
        inFlight.remove(key)
        if remeasureAfterFlight.remove(key) != nil {
            lastAttempt.removeValue(forKey: key)
        } else if attempted {
            lastAttempt[key] = Date()
        }
        if let info { cache[key] = info }
        lock.unlock()
        if info != nil { persist() }
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

    func snapshot() -> [String: DeviceStorageInfo] {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    /// 居なくなった台の控えを捨てる(health/renderMode キャッシュと同じ規律)
    func forget(keysNotIn live: Set<String>) {
        lock.lock()
        for key in Set(cache.keys).union(lastAttempt.keys).subtracting(live) {
            cache.removeValue(forKey: key)
            lastAttempt.removeValue(forKey: key)
        }
        lock.unlock()
    }
}
