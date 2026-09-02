// FM(Foundation Models)がこの機械で今**呼べる状態か**の、機械グローバルな台帳。
//
// FMHealth が数えるのは「この run の中で何回呼んで何回落ちたか」で、**呼んでいない間は何も
// 言えない**。モニターの FM 行が呼び出し0件のときに無印なのはそのため —— 「誰も使っていない」と
// 「死んでいる」が同じ絵になる。ここはその1点だけを持つ:
// **最後に観測した生死・いつ・何を根拠に・(死なら)エラー**。
//
// 規律5つ:
//  ① **生 / 死 / 不明の3値**。記録が無い・古いは nil(不明)で、死と混ぜない
//     (「一度も聞いていない」を「空き」と同じ形にしない —— 占有の控えと同じ規律)。
//     鮮度は `freshSeconds`
//  ② **経路は text と vision で別に持つ**。**text と vision は独立に死ぬ・戻る**(実測。
//     [[fm-flap-ane-load-failure]])。ひとつに畳むと、text だけ生きている機械で
//     occlusion-guard(視覚系)が全滅したまま「FM は生きている」と配ることになる ——
//     この台帳が消したい誤った緑そのもの
//  ③ **書き手は根拠を名乗る**(`Source`)。**availability は書き手にしない** ——
//     `.available` のまま全呼び出しが失敗する実測(2026-07-22)があり、根拠にすると嘘を配る。
//     `unavailable` は逆方向に嘘をつかないので、そちらだけはプローブが根拠に使う
//  ④ **新しい観測が勝つ**。書き手は複数プロセス(ワーカー・監視・CLI)なので、書く前に
//     ディスクの `checkedAt` と比べ、古い観測で新しい観測を上書きしない。**片方の経路を
//     書くときにもう片方を消さない**(読んでから畳んで書く)
//  ⑤ **FM の実測(FMUsageLedger)には書かない**。死活プローブは「仕事」ではないので、
//     ここへ書いてもモニターの FM レートは動かない(**測る対象を自分で消費して見せない**)
//
// 置き場は ~/.fleetest/fm-liveness.json(`FT_FM_LIVENESS_DIR` で差し替え。テスト用)。
// FMUsageLedger と同じ機械グローバルな場所 —— FM はホストの資源なので、プロジェクトにも
// リポジトリにも依存させない。
//
// 読み手: `api host-metrics`(NDJSON の fmState/fmError/… → モニターの FM 行)・
// run 開始前の警告(ProfileRunner.warnIfFMDegraded)・`ft_status` / `ft_doctor`。
// 書き手: FMHealth.record(実仕事の成否)と FTFoundationModels の FMLivenessProbe。

import Foundation

public enum FMLiveness {
    /// 観測できた生死。**不明はここに無い**(不明は Verdict そのものが nil)
    public enum State: String, Codable, Sendable {
        case alive
        case dead
    }

    /// FM の経路。**独立に死ぬ**ので独立に持つ(ファイル冒頭 ②)
    public enum Path: String, Codable, Sendable {
        /// テキストのみの呼び出し。heal / triage / シナリオ命名
        case text
        /// 画像入力(Attachment)を伴う呼び出し。occlusion-guard / screenLooksLike
        case vision
    }

    /// 何を根拠にそう判定したか。強い順に .call > .probe > .breaker
    public enum Source: String, Codable, Sendable {
        /// シナリオ実行等の**実仕事**の FM 呼び出しの成否(FMHealth.record 経由)
        case call
        /// 死活確認だけのための実呼び出し(FMLivenessProbe)
        case probe
        /// サーキットブレーカが落ちている = 直前に連続失敗した、という既知の事実。
        /// **呼ばずに死と言える唯一の根拠**(FMBreaker の doc 参照)
        case breaker
        /// availability が `unavailable` を返した(Apple Intelligence が off・非対応機・
        /// モデル未取得)。**この向きだけは availability を信じてよい**(③)
        case availability
    }

    public struct Verdict: Codable, Sendable, Equatable {
        public var state: State
        /// 観測した時刻(epoch 秒)。鮮度の判定はこれだけで行う
        public var checkedAt: Double
        public var source: Source
        /// 死のときの理由(入れ子を畳んだ連鎖。FMHealth.describe を通した形)。
        /// 生のときは nil —— **「直っても前のエラーが残る」を作らない**
        public var error: String?
        /// 実際に呼んだ回(.call / .probe)の所要 ms。生きているのに遅い(= 実質使えない)を
        /// 後から見るため。呼ばずに判定した回(.breaker / .availability)は nil
        public var ms: Int?

        public init(state: State, checkedAt: Double, source: Source,
                    error: String? = nil, ms: Int? = nil) {
            self.state = state
            self.checkedAt = checkedAt
            self.source = source
            self.error = error
            self.ms = ms
        }

        public func isFresh(now: Date = Date(), maxAge: TimeInterval = FMLiveness.freshSeconds) -> Bool {
            now.timeIntervalSince1970 - checkedAt < maxAge
        }
    }

    /// ディスク上の形。経路ごとに独立(②)
    public struct Record: Codable, Sendable, Equatable {
        public var text: Verdict?
        public var vision: Verdict?

        public init(text: Verdict? = nil, vision: Verdict? = nil) {
            self.text = text
            self.vision = vision
        }

        public subscript(path: Path) -> Verdict? {
            get { path == .text ? text : vision }
            set { if path == .text { text = newValue } else { vision = newValue } }
        }
    }

    /// 鮮度を当てた読み。**nil の枝は「不明」**(記録が無い / 古い)。死と混ぜないこと
    public struct Reading: Sendable, Equatable {
        public let text: Verdict?
        public let vision: Verdict?

        public init(text: Verdict?, vision: Verdict?) {
            self.text = text
            self.vision = vision
        }

        /// **どこか1経路でも死んでいる**か。FM 依存機能のどれかが黙って無効になっている合図
        public var hasDead: Bool { !deadPaths.isEmpty }
        /// 観測が1件も無い(= 何も言えない)
        public var isUnknown: Bool { text == nil && vision == nil }

        /// 死んでいる経路の名前("text" / "vision")。**順序は固定**(text→vision)——
        /// 出力を突き合わせるテストと、行の見た目が観測順で入れ替わらないようにするため
        public var deadPaths: [String] {
            [("text", text), ("vision", vision)]
                .compactMap { name, verdict in verdict?.state == .dead ? name : nil }
        }

        /// 死んでいる経路と理由を1つの文字列に畳む。生/不明だけなら nil。
        /// **両方死んでいるときは両方出す** —— 「片方だけ死んでいる」と「全滅」は次の一手が違う
        /// (前者はシナリオの書き方で回避できる)。`limit` は載せ先ごとの上限
        /// (1Hz の NDJSON と run.json では許せる長さが違う)
        public func deadSummary(limit: Int? = nil) -> String? {
            let parts = [("text", text), ("vision", vision)]
                .compactMap { name, verdict -> String? in
                    guard let verdict, verdict.state == .dead else { return nil }
                    return "\(name): \(verdict.error ?? verdict.source.rawValue)"
                }
            guard !parts.isEmpty else { return nil }
            let joined = parts.joined(separator: " / ")
            return limit.map { String(joined.prefix($0)) } ?? joined
        }
    }

    /// これより古い観測は「不明」に倒す。既定のプローブ間隔
    /// (FMLivenessProbe.probeIntervalSeconds = 60 秒)の2倍 —— **1回取りこぼしただけで
    /// 不明にしない**ための2倍で、それ以上は FM の間欠死の時間尺度(数分〜数時間。
    /// [[fm-flap-ane-load-failure]])に対して古すぎる
    public static let freshSeconds: TimeInterval = 120

    /// 状態が変わらない間、ディスクへ書き直す最短間隔。実呼び出しは1秒に数回あるので、
    /// 毎回書くと台帳が「現在の状態」ではなく書き込み負荷になる。**状態が変わった回は
    /// この間隔を無視して即書く**(死んだ瞬間を遅らせない)
    static let writeCoalesceSeconds: TimeInterval = 5

    private static let lock = NSLock()
    /// このプロセスが最後にディスクへ書いた内容(経路ごと)。coalesce の判定にだけ使う
    private static var lastWritten: [Path: Verdict] = [:]

    // MARK: - 置き場

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("fm-liveness.json") }

    /// 書き込み先。nil = 書かない。**XCTest のプロセスからは書かない** ——
    /// FMHealth.record は単体テストが合成値で直接叩くので、FM を1回も呼んでいないのに
    /// 「FM は死んでいる」が機械全体に配られる(FMUsageLedger.writeDirectory と同じ理由)。
    /// 台帳自体を検証するテストは FT_FM_LIVENESS_DIR を明示するので影響を受けない
    private static var writeURL: URL? {
        if let override = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("fm-liveness.json")
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        return fileURL
    }

    // MARK: - 書く

    /// 観測1件を記録する。**書き込み失敗は握りつぶす** —— 台帳のために FM の実行も監視も
    /// 止めない。ファイル I/O をするので、呼び出し側のロックの内側から呼ばないこと
    public static func record(path: Path, state: State, source: Source,
                              error: String? = nil, ms: Int? = nil,
                              now: Date = Date()) {
        let verdict = Verdict(state: state, checkedAt: now.timeIntervalSince1970,
                              source: source,
                              // 生になったらエラーは捨てる(Verdict.error の doc)
                              error: state == .dead ? error : nil,
                              ms: ms)
        lock.lock()
        let previous = lastWritten[path]
        // 状態が同じで、書いたばかりなら書かない(writeCoalesceSeconds の doc)
        if let previous, previous.state == verdict.state,
           verdict.checkedAt - previous.checkedAt < writeCoalesceSeconds {
            lock.unlock()
            return
        }
        lock.unlock()
        // **控えを進めるのは実際に着地した回だけ**。書けなかった判定(自分より新しい観測が
        // 既に居た等)で控えを進めると、以後の同じ状態の書き込みが「書いたばかり」として
        // 畳まれ、ディスクに1度も着地しない状態が続く
        guard write(path: path, verdict: verdict) else { return }
        lock.lock()
        lastWritten[path] = verdict
        lock.unlock()
    }

    @discardableResult
    private static func write(path: Path, verdict: Verdict) -> Bool {
        guard let url = writeURL else { return false }
        // ④ もう片方の経路を消さない・自分より新しい観測は上書きしない
        var record = read(at: url) ?? Record()
        if let existing = record[path], existing.checkedAt > verdict.checkedAt { return false }
        record[path] = verdict
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else { return false }
        // 一時ファイル → 同一ディレクトリ内 rename(2)。読み手に途中まで書かれた JSON を見せない
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".fm-liveness.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp")
        guard (try? data.write(to: tmp)) != nil else { return false }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }

    // MARK: - 読む

    /// 台帳をそのまま読む(**古くても返す**)。鮮度を当てたいときは `current` を使う
    public static func read() -> Record? { read(at: fileURL) }

    private static func read(at url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// 鮮度を当てた読み。古い枝は nil(= 不明)に倒す
    public static func current(now: Date = Date(), maxAge: TimeInterval = freshSeconds) -> Reading {
        let record = read()
        func fresh(_ verdict: Verdict?) -> Verdict? {
            guard let verdict, verdict.isFresh(now: now, maxAge: maxAge) else { return nil }
            return verdict
        }
        return Reading(text: fresh(record?.text), vision: fresh(record?.vision))
    }

    /// テスト用。プロセス内の coalesce の記憶を捨てる(ディスクは触らない)
    public static func resetWriteMemo() {
        lock.lock()
        lastWritten.removeAll()
        lock.unlock()
    }
}
