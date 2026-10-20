import Foundation

/// run 進捗の記帳(docs/design.md §18。段1・2)。RunLeaseLedger と同じ形 —— 書き手の実体
/// (`RunProgressLedger.write/remove`)は fleetest ターゲットが注入する(FTCore は書き込み先の
/// 生成規約を持つが、pid・プロセス起動の知識は呼び出し側に残す既存の注入規律に揃える)。
/// **書くのは変化した瞬間だけ**(前回の record と比較して同じなら書かない。Equatable)。
/// `total`/`startedAt` 等は不変 —— 変わるのは done/failed/lanes だけなので、それ以外は
/// コンストラクタで固定する
/// **internal**(private ではない)—— RunLeaseLedger と同じく直接単体テストする対象
/// (RunProgressStateTests)。RunOrchestrator 自身は単体で組めないため
actor RunProgressState {
    private let pid: Int32
    private let runID: String?
    private let runGroup: String?
    private let issuer: String?
    private let project: String
    private let profile: String?
    private let startedAt: String
    private let total: Int
    private var done = 0
    private var failed = 0
    /// **詰まりの事実だけ**(docs/design.md §18.1 段6)。判定・閾値は作らない —— laneIdled/laneLeft
    /// が成立した回数をそのまま数えるだけ
    private var requeuedCount = 0
    private var laneDropoutsCount = 0
    private var lanesByKey: [String: RunProgressLane] = [:]
    private var lastWritten: RunProgressRecord?
    private let write: (@Sendable (RunProgressRecord) -> Void)?
    private let remove: (@Sendable () -> Void)?
    /// 供給の段階の箱。変更通知は `supplyChanged()` へ繋ぐ(RunOrchestrator.run)
    private let supply: RunSupplyProgress?
    /// finish() の後に箱の通知で台帳を作り直さない
    private var finished = false
    /// 残り見積もり(docs/design.md §18.4)の実績表(ms)。空 = 実績ゼロ → etaSeconds は常に nil
    private let estimates: [RunProgressEstimate.ScenarioKey: Double]
    /// 未着手ジョブの多重集合(件数)。同じ (scenarioID, platform) が複数残ることがある
    /// (broadcast は同じシナリオが複数レーンぶん残る)。scenarioStarted で1減らし、
    /// 再キュー(laneIdled)でまた1増やす
    private var pendingCounts: [RunProgressEstimate.ScenarioKey: Int]

    init(pid: Int32, runID: String?, runGroup: String?, issuer: String?, project: String,
        profile: String?, startedAt: Date, total: Int,
        estimates: [RunProgressEstimate.ScenarioKey: Double] = [:],
        pendingScenarios: [RunProgressEstimate.ScenarioKey] = [],
        supply: RunSupplyProgress? = nil,
        write: (@Sendable (RunProgressRecord) -> Void)?, remove: (@Sendable () -> Void)?) {
        self.supply = supply
        self.pid = pid
        self.runID = runID
        self.runGroup = runGroup
        self.issuer = issuer
        self.project = project
        self.profile = profile
        self.startedAt = ISO8601DateFormatter().string(from: startedAt)
        self.total = total
        self.estimates = estimates
        self.pendingCounts = Dictionary(grouping: pendingScenarios, by: { $0 }).mapValues(\.count)
        self.write = write
        self.remove = remove
    }

    private func flush() {
        guard !finished else { return }
        let record = RunProgressRecord(
            pid: pid, runID: runID, runGroup: runGroup, issuer: issuer, project: project,
            profile: profile, startedAt: startedAt, total: total, done: done, failed: failed,
            requeued: requeuedCount, laneDropouts: laneDropoutsCount,
            // コンパイル待ちの間は残りを出さない(読み手は受信時点の値から秒読みするので、出すと待ちの間に減っていく)
            etaSeconds: ocrCompileWaiters > 0 ? nil : currentEtaSeconds(),
            lanes: lanesByKey.values.sorted { $0.key < $1.key },
            phase: ocrCompileWaiters > 0 ? "compiling" : "running",
            supply: supply?.snapshot() ?? [])
        guard record != lastWritten else { return }
        let firstWrite = lastWritten == nil
        lastWritten = record
        write?(record)
        // 通知の引き継ぎは**最初の書き込みの後**(それまでは入口/準備中の書き手が段階を台帳へ載せ続ける。
        // 先に奪うと、レーンが1つも合流していない iOS だけの run で供給の進行が止まって見える)
        if firstWrite {
            supply?.setOnChange(owner: ObjectIdentifier(self)) { [self] in Task { await supplyChanged() } }
        }
    }

    /// §18.4 の式そのもの。**未着手はレーンから独立**(pendingCounts)・**実行中はレーンから直接**
    /// (lanesByKey の scenario/scenarioStartedAt)。同じ機械・同じプロセスの時計を使うだけなので
    /// (§18.3 が扱う「向こうの時計とのずれ」はここには無い)、経過は Date() との差でそのまま出す
    private func currentEtaSeconds() -> Int? {
        let pending = pendingCounts.flatMap { key, count in Array(repeating: key, count: count) }
        let running: [(scenario: RunProgressEstimate.ScenarioKey, elapsedSeconds: Double)] =
            lanesByKey.values.compactMap { lane in
                guard let scenario = lane.scenario, let platform = lane.platform,
                      let startedText = lane.scenarioStartedAt,
                      let laneStartedAt = ISO8601DateFormatter().date(from: startedText)
                else { return nil }
                let key = RunProgressEstimate.ScenarioKey(scenarioID: scenario, platform: platform)
                return (key, max(0, Date().timeIntervalSince(laneStartedAt)))
            }
        return RunProgressEstimate.etaSeconds(
            table: estimates, pending: pending, running: running, liveLanes: lanesByKey.count)
    }

    private func decrementPending(_ key: RunProgressEstimate.ScenarioKey) {
        guard let count = pendingCounts[key], count > 0 else { return }
        if count == 1 { pendingCounts.removeValue(forKey: key) } else { pendingCounts[key] = count - 1 }
    }

    /// 記録用(画面には出さない): 実行中シナリオの実績中央値(秒)。実績表に無ければ nil ——
    /// 推測値は書かない。ms→秒は `RunProgressEstimate.etaSeconds` と同じ丸め(切り上げ)
    private func expectedSeconds(scenario: String, platform: String?) -> Int? {
        guard let platform else { return nil }
        guard let ms = estimates[RunProgressEstimate.ScenarioKey(scenarioID: scenario, platform: platform)]
        else { return nil }
        return Int((ms / 1000).rounded(.up))
    }

    /// レーンの新規参加・復帰(revive 後の再参加も同じ経路。key が変われば新規レーン扱い)
    func laneJoined(key: String, name: String, platform: String?) {
        lanesByKey[key] = RunProgressLane(key: key, name: name, platform: platform,
                                          scenario: nil, scenarioStartedAt: nil, expectedSeconds: nil)
        flush()
    }

    /// ワーカー離脱(デバイス使用不能)によるレーンの消滅。復帰できれば laneJoined が改めて足す
    func laneLeft(key: String) {
        guard lanesByKey.removeValue(forKey: key) != nil else { return }
        laneDropoutsCount += 1
        flush()
    }

    /// compile-ocr を待っているレーンの数。1 以上の間は段階を "compiling" にする(全レーンが同じ1本を待つ =
    /// run 全体の段階。待ちの間はシナリオの印を打たないので、経過・残りの秒読みも始まらない)
    private var ocrCompileWaiters = 0

    func ocrCompileWaitBegan() {
        ocrCompileWaiters += 1
        flush()
    }

    func ocrCompileWaitEnded() {
        ocrCompileWaiters = max(0, ocrCompileWaiters - 1)
        flush()
    }

    func scenarioStarted(laneKey: String, scenario: String, at: Date) {
        guard let lane = lanesByKey[laneKey] else { return }
        // 未着手 → 実行中(pendingCounts から1つ引く。lane.platform は laneJoined で
        // worker.platform から常に埋まる —— nil なら鍵が作れないので寄与させない)
        if let platform = lane.platform {
            decrementPending(RunProgressEstimate.ScenarioKey(scenarioID: scenario, platform: platform))
        }
        lanesByKey[laneKey] = RunProgressLane(
            key: lane.key, name: lane.name, platform: lane.platform, scenario: scenario,
            scenarioStartedAt: ISO8601DateFormatter().string(from: at),
            expectedSeconds: expectedSeconds(scenario: scenario, platform: lane.platform))
        flush()
    }

    /// 結果を捨てて再キュー(環境の一過性エラー・不達ブリッジの振り直し等)。
    /// **done/failed は増やさない** —— 同じシナリオを別の機会にもう一度実行するので、
    /// まだ「終わった」ことにはならない(最終的な合否は、次に scenarioFinished が呼ばれたとき)。
    /// **見積もりは「未着手」へ戻す**(実行中 → もう一度 pendingCounts へ)
    func laneIdled(laneKey: String) {
        guard let lane = lanesByKey[laneKey] else { return }
        if let scenario = lane.scenario, let platform = lane.platform {
            let key = RunProgressEstimate.ScenarioKey(scenarioID: scenario, platform: platform)
            pendingCounts[key, default: 0] += 1
        }
        requeuedCount += 1
        lanesByKey[laneKey] = RunProgressLane(
            key: lane.key, name: lane.name, platform: lane.platform, scenario: nil,
            scenarioStartedAt: nil, expectedSeconds: nil)
        flush()
    }

    func scenarioFinished(laneKey: String, passed: Bool) {
        done += 1
        if !passed { failed += 1 }
        if let lane = lanesByKey[laneKey] {
            lanesByKey[laneKey] = RunProgressLane(
                key: lane.key, name: lane.name, platform: lane.platform, scenario: nil,
                scenarioStartedAt: nil, expectedSeconds: nil)
        }
        flush()
    }

    /// run 終了。台帳ファイルを消す(best-effort。呼び手が閉じ忘れても pid 死亡で readAll が無視する)
    func finish() {
        finished = true
        supply?.releaseOnChange(owner: ObjectIdentifier(self))
        remove?()
    }

    /// 供給の箱が変わった(混在 run で iOS が後から合流中の段階など)
    func supplyChanged() {
        flush()
    }
}
