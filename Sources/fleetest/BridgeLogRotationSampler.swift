// BridgeLogRotationSampler.swift
// api monitor の周期から、xcresult 保持容量が guarded だけで超過したときの「起動し直す価値のある」
// ブリッジの候補を切り離す(モニターの周期に計測を足すときの規律: 周期の中で待たない・裏で回して
// 控えを読むだけ。前例: DeviceStorageSampler)。
//
// 判定そのものは FTCore.BridgeLogRotation.candidate(純粋関数)。ここは I/O 側の3つだけ:
//   ①xcresult のセッションを採る(RetentionSweeper.xcresultSessions。guarded 判定込み)
//   ②実効容量ポリシー(~/.config/fleetest/config.json)を読む。sweepAfterRun が false なら測らない
//     (利用者の止めるスイッチ)
//   ③一定間隔で背景のキューへ積む(周期は控えを読むだけ)
//
// ポート→デバイスの対応は呼び手(ApiMonitorCommand)が毎周期の観測状態(iosPort)から引く
// (BridgeLogRotationCandidateMapping.candidate)——このプロセスが観測しているデバイスだけに絞るため。

import FTBridgeClient
import FTCore
import Foundation

final class BridgeLogRotationSampler: @unchecked Sendable {
    /// 増え方の実測最大が約6GB/日(docs/results-json.md 保持容量節)≒ 42MB/10分。
    /// 既定上限5GiBに対し10分遅れても無視できる差なので、この間隔で足りる
    static let measurementIntervalSeconds: TimeInterval = 600

    struct RawCandidate: Equatable {
        let port: UInt16
        /// 起動し直せば孤児になり消える束そのもののバイト数
        let bundleBytes: Int64
        /// xcresult 系統の使用量合計(guarded 込み)
        let usageBytes: Int64
        let limitBytes: Int64
        /// 候補の束。**控えを返すたびに実在を確かめる**(`snapshot`)—— 計測は間隔を空けるので、
        /// 起動し直し後に古いポートを別のデバイスのブリッジが使い始めると、古い控えがそのデバイスを
        /// 指してしまう。起動し直せば古い束は消える(同じポートなら起動時の掃除・別ポートなら孤児の掃除)
        let bundlePath: URL
    }

    typealias Measure = @Sendable () -> RawCandidate?

    private let lock = NSLock()
    private var lastMeasuredAt: Date?
    private var cached: RawCandidate?
    private let queue = DispatchQueue(label: "fleetest.monitor.bridgeLogRotation", qos: .utility)
    private let measure: Measure
    private let now: @Sendable () -> Date
    private let bundleExists: @Sendable (URL) -> Bool

    /// テストの差し替え口。本番は `toolRoot:` の convenience init を使う
    init(measure: @escaping Measure, now: @escaping @Sendable () -> Date = { Date() },
         bundleExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.measure = measure
        self.now = now
        self.bundleExists = bundleExists
    }

    convenience init(toolRoot: URL?) {
        self.init(measure: {
            guard let toolRoot else { return nil }
            let policy = LocalConfig.load().retention ?? RetentionPolicy()
            guard policy.effectiveSweepAfterRun else { return nil }
            let sessions = RetentionSweeper.xcresultSessions(toolRoot: toolRoot)
            let maxBytes = policy.effectiveXcresultMaxBytes
            guard let chosen = BridgeLogRotation.candidate(sessions: sessions, maxBytes: maxBytes),
                  let port = BridgeLauncher.resultBundlePort(chosen.id),
                  let bundlePath = chosen.paths.first else { return nil }
            let usage = sessions.reduce(Int64(0)) { $0 + $1.bytes }
            return RawCandidate(port: port, bundleBytes: chosen.bytes, usageBytes: usage, limitBytes: maxBytes,
                                bundlePath: bundlePath)
        })
    }

    /// 呼び手は毎周期これを呼ぶ(待たない)。間隔が経っていれば背景で1回測る。
    /// **due の判定と `lastMeasuredAt` の更新は同じロックの中**(2つのスレッドが同時に呼んでも
    /// 二重に積まない)
    func scheduleIfDue() {
        lock.lock()
        let due = lastMeasuredAt == nil
            || now().timeIntervalSince(lastMeasuredAt!) >= Self.measurementIntervalSeconds
        if due { lastMeasuredAt = now() }
        lock.unlock()
        guard due else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.measure()
            self.lock.lock()
            self.cached = result
            self.lock.unlock()
        }
    }

    /// 控えを読むだけ(周期は待たない。束の実在の確認は stat 1回)
    func snapshot() -> RawCandidate? {
        lock.lock()
        defer { lock.unlock() }
        if let current = cached, !bundleExists(current.bundlePath) { cached = nil }
        return cached
    }
}

/// ポート → デバイスの対応(I/O を持たない純粋関数)。対応が引けない候補(このプロセスが
/// 観測していないポート)は nil 扱い——束はあってもタイルを特定できず、拡張は何を起動し直すか言えない
enum BridgeLogRotationCandidateMapping {
    static func candidate(
        raw: BridgeLogRotationSampler.RawCandidate?, states: [DeviceRuntimeState]
    ) -> ApiMonitorBridgeLogRotationEvent.Candidate? {
        guard let raw else { return nil }
        guard let state = states.first(where: { $0.target.platform == "ios" && $0.iosPort == raw.port })
        else { return nil }
        return ApiMonitorBridgeLogRotationEvent.Candidate(
            deviceId: state.target.id, name: state.target.name, port: raw.port,
            bundleBytes: raw.bundleBytes, usageBytes: raw.usageBytes, limitBytes: raw.limitBytes)
    }
}
