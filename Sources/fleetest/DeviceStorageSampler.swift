// api monitor のストレージ計測(monitorDevices[].storage)を配信周期から切り離す。
// 周期は schedule()(期限の来た台を裏のキューへ積むだけ・待たない)と snapshot()(控えを読む)しか呼ばない。
// **周期の中で計測を await しない**: iOS Simulator の du は 1 台 27〜35 秒(実測・データ
// 30〜37GB・ホスト負荷 load avg 14)かかり、周期内で待つとタイル・凍結判定が止まる。計測は Shell.run の
// 同期呼び出しなので Swift の協調スレッドにも載せない(専用の DispatchQueue)。

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
    /// du は 1 台ずつ(並列に歩くと I/O が重なり、同じ Mac の run に響く)
    private let iosQueue = DispatchQueue(label: "fleetest.monitor.storage.ios", qos: .utility)
    private let androidQueue = DispatchQueue(label: "fleetest.monitor.storage.android", qos: .utility)
    private let probeIOS: Probe
    private let probeAndroid: Probe
    /// この Mac で run が動いているか。iOS の du は**実行の直前にも**確かめる(積んだ後に run が始まりうる)
    private let isRunActive: @Sendable () -> Bool

    init(probeIOS: @escaping Probe, probeAndroid: @escaping Probe, isRunActive: @escaping @Sendable () -> Bool) {
        self.probeIOS = probeIOS
        self.probeAndroid = probeAndroid
        self.isRunActive = isRunActive
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

    /// 測れなかった回は前回値を残す(0 で埋めない)。撃たなかった回は期限も進めない
    private func finish(key: String, info: DeviceStorageInfo?, attempted: Bool) {
        lock.lock()
        inFlight.remove(key)
        if attempted { lastAttempt[key] = Date() }
        if let info { cache[key] = info }
        lock.unlock()
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
