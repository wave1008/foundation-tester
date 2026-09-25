// フリート横断の run 進捗の機械グローバルな控え(docs/design.md §18)。
//
// モニターが run について持っている情報は run-lease の鮮度(inRun の1ビット)と、拡張が起こした
// run にしか届かない runEvent だけだった。「何本中何本終わったか」を CLI 実行・他人の run・
// ランナー機の run でも見せるため、実行中のプロセス自身がここへ書き、`api monitor` が読む
// (FMUsageLedger と同じ役割分担 —— host-metrics が対象を叩いて測ると測定対象を自分で消費する
// のと同じ理由で、進捗を持っている RunOrchestrator 自身が書く)。
//
// 置き場は ~/.fleetest/runs/<pid>.json(機械グローバル。FMUsageLedger の隣・同じ規律)。
// **プロジェクトに依存させない** —— ランナー機では発行者ごとに work が分かれる
// (<base>/users/<issuer>/work/)ので、プロジェクトの .fleetest/ に置くと他人の run が
// 原理的に見えない。共有アカウント前提(remote-runner.md §15.3)なので ~ は全員で1つ。
//
// FMUsageLedger と違い、ここは「呼び出し回数の累積カウンタ」ではなく「run 1つのスナップショット」
// なので UsageLedger(pid ごとの単調増加カウンタの共通実装)には乗せない —— 1 pid = 1 run が
// 全欄を毎回まるごと上書きする。**生存判定は pid だけでなく、記録の startedAt より後に
// 始まっていないかも見る**(mtime は見ない。FMUsageLedger と同じ)—— SIGKILL された run の pid が
// 別プロセスへ再利用されると、pid だけの判定は死んだ run をずっと「生きている」と読み続ける
// (`ProcessLiveness.isAliveAndNotStartedAfter`)。
// SIGKILL で finish() に届かなかった控えは読み手(readAll)が無視し、次の run の開始時に
// sweep() が回収する(掃除は書き手側。理由は sweep の宣言)。

import Foundation

/// 1レーン(= 実行中デバイス)の進捗。key は run-lease と同じ鍵体系
/// (iOS = シミュレータ UDID / Android = adb serial)
public struct RunProgressLane: Codable, Equatable, Sendable {
    public let key: String
    /// 表示名。**モニターのタイルと同じ名前**(実行プロファイルの devices[].name =
    /// `RunWorker.logicalName`。label はポート込みなので使わない)
    public let name: String
    /// "ios" / "android"
    public let platform: String?
    /// 実行中のシナリオ ID。待機中(まだ何も取っていない・直前の1本を終えて次を待つ)は nil
    public let scenario: String?
    /// ISO8601 UTC。`scenario` が nil なら nil
    public let scenarioStartedAt: String?
    // **レーンごとの残り本数は持たない**(docs/design.md §18.1)—— shared dispatch は同一 platform の
    // レーンが1つのキューを共有するので、レーン別の残数は同じ数字が並ぶだけで誤読を招く
    // (3レーンに「残 2」= 6本残っていると読める)。run の残りは total - done で足りる
    /// **記録用**(画面には出さない。ユーザー決定 2026-09-21): 実行中シナリオの実績中央値(秒)。
    /// `scenario` が nil、または実績表に無ければ nil(推測値は書かない)。値は固定 ——
    /// シナリオ開始時に1回引く。**「いつもと比べてどうだったか」を後から分析するために残す**
    public let expectedSeconds: Int?

    public init(key: String, name: String, platform: String?, scenario: String?,
               scenarioStartedAt: String?, expectedSeconds: Int?) {
        self.key = key
        self.name = name
        self.platform = platform
        self.scenario = scenario
        self.scenarioStartedAt = scenarioStartedAt
        self.expectedSeconds = expectedSeconds
    }
}

/// 1 run のスナップショット。`~/.fleetest/runs/<pid>.json` に丸ごと上書きされる
/// (増分ではない。書き手は RunOrchestrator の1箇所 —— docs/design.md §18.1)
public struct RunProgressRecord: Codable, Equatable, Sendable {
    public let pid: Int32
    /// `RunRecorder.runID`。recorder が無い経路(--dry-run/--debug 等)では nil
    public let runID: String?
    /// 機械分担 run を束ねる鍵(`RunRecorder.runGroup`)
    public let runGroup: String?
    /// 自己申告のディスパッチ発行者(`LocalConfig.resolveIssuerId()`)
    public let issuer: String?
    public let project: String
    public let profile: String?
    /// ISO8601 UTC
    public let startedAt: String
    /// **run 開始時に確定した本数**。再キュー・失敗で動かさない
    public let total: Int
    public let done: Int
    public let failed: Int
    /// **詰まりの事実**(段6・docs/design.md §18.5): 結果を捨てて振り直した累計
    /// (`RunProgressState.laneIdled` が成立した回数)。判定・文言は作らない —— 事実の並置だけ
    public let requeued: Int
    /// **詰まりの事実**: レーンが離脱した累計(`RunProgressState.laneLeft` の回数)
    public let laneDropouts: Int
    /// 段5(残り見積もり)。実績が1件も無い run は nil。推測値は出さない
    public let etaSeconds: Int?
    public let lanes: [RunProgressLane]
    /// "building"(シナリオの swift build を**実際に呼んでいる間だけ**。`--skip-build` では
    /// 一度も立たない)/ "preparing"(入口・ビルド後・デバイスの供給中)/ "running"
    public let phase: String

    public init(pid: Int32, runID: String?, runGroup: String?, issuer: String?, project: String,
               profile: String?, startedAt: String, total: Int, done: Int, failed: Int,
               requeued: Int, laneDropouts: Int, etaSeconds: Int?, lanes: [RunProgressLane],
               phase: String) {
        self.pid = pid
        self.runID = runID
        self.runGroup = runGroup
        self.issuer = issuer
        self.project = project
        self.profile = profile
        self.startedAt = startedAt
        self.total = total
        self.done = done
        self.failed = failed
        self.requeued = requeued
        self.laneDropouts = laneDropouts
        self.etaSeconds = etaSeconds
        self.lanes = lanes
        self.phase = phase
    }

}

public enum RunProgressLedger {
    /// `~/.fleetest/runs`。`home` はテスト用の差し替え口(環境変数ではなく引数 —— 書き手
    /// [RunOrchestrator への注入]と読み手[api monitor]の両方が同じ関数を同じ引数の形で呼べる)
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".fleetest", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }

    /// 一時ファイルに書いてから同一ディレクトリ内で rename する(RunLease/UsageLedger と同じ
    /// アトミック書き込み)。**ベストエフォート**(失敗は無視。実行そのものを絶対に止めない)
    public static func write(_ record: RunProgressRecord, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else { return }
        let target = directory.appendingPathComponent("\(record.pid).json")
        let tmp = directory.appendingPathComponent(".\(record.pid).\(UUID().uuidString).tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        guard rename(tmp.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
    }

    public static func remove(pid: Int32, directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(pid).json"))
    }

    /// 死んだ pid の控えを消す。**run の開始時に書き手が1回だけ呼ぶ**(`StaleLedgerSweep` が
    /// provision の入口で台帳を掃除するのと同じ立場)。**読み手(`api monitor`)には置かない** ——
    /// あちらは毎周期読むので、掃除を読み手に持たせると監視の周期がそのまま掃除の回数になる。
    /// `remove` に届かなかった控え(SIGKILL)はここでだけ回収される。
    /// **pid としてパースできない名前は触らない**(この台帳が作った物ではない)。
    /// **中身が読めない(壊れた JSON)ときは pid の生死だけで判定する**(従来どおり。
    /// startedAt が要る比較ができないので、それより弱い判定へ落ちるのは安全側)
    public static func sweep(directory: URL, isAlive: (Int32) -> Bool = ProcessLiveness.isAlive,
                             startTime: (Int32) -> Date? = ProcessLiveness.startTime) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(".json".count)), pid > 0 else { continue }
            let url = directory.appendingPathComponent(name)
            let startedAt = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode(RunProgressRecord.self, from: $0) }?.startedAt
            guard !isStillRunning(pid: pid, startedAt: startedAt, isAlive: isAlive, startTime: startTime)
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 生きている pid の記録だけを返す。**生存判定は pid + startedAt**(pid 再利用を弾く。
    /// ファイルの mtime は見ない)。壊れた JSON は1件だけ飛ばす(全体を失わない)。
    /// `isAlive` / `startTime` はテスト用の差し替え口
    public static func readAll(
        directory: URL, isAlive: (Int32) -> Bool = ProcessLiveness.isAlive,
        startTime: (Int32) -> Date? = ProcessLiveness.startTime
    ) -> [RunProgressRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var records: [RunProgressRecord] = []
        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(".json".count)), pid > 0 else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(RunProgressRecord.self, from: data)
            else { continue }
            guard isStillRunning(pid: pid, startedAt: record.startedAt, isAlive: isAlive,
                                 startTime: startTime) else { continue }
            records.append(record)
        }
        return records
    }

    /// pid の生死 + (読めれば)startedAt 以降に生まれた別プロセスでないかを1つの判定に畳む。
    /// **startedAt が読めない/パースできないときは pid の生死だけで判定する**(sweep が中身を
    /// 読めなかった控えを扱うときの後退経路)
    private static func isStillRunning(pid: Int32, startedAt: String?, isAlive: (Int32) -> Bool,
                                       startTime: (Int32) -> Date?) -> Bool {
        guard let startedAt, let recordedAt = ISO8601DateFormatter().date(from: startedAt) else {
            return isAlive(pid)
        }
        return ProcessLiveness.isAliveAndNotStartedAfter(
            pid, recordedAt: recordedAt, isAliveOverride: isAlive, startTimeOverride: startTime)
    }
}
