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
//     `.available` のまま全呼び出しが失敗する実測があり、根拠にすると嘘を配る。
//     `unavailable` は逆方向に嘘をつかないので、そちらだけはプローブが根拠に使う
//  ④ **新しい観測が勝つ**。書き手は複数プロセス(ワーカー・監視・CLI)なので、書く前に
//     ディスクの `checkedAt` と比べ、古い観測で新しい観測を上書きしない。**片方の経路を
//     書くときにもう片方を消さない**(読んでから畳んで書く。読み→畳み→rename は
//     `fm-liveness.lock` の flock の内側 —— 書き手同士が同じ古い記録を読んで畳むと、
//     後に rename した側がもう片方の経路を古い値へ戻す)
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
import Synchronization

public enum FMLiveness {
    /// 観測できた生死。**不明はここに無い**(不明は Verdict そのものが nil)
    public enum State: String, Codable, Sendable {
        case alive
        case dead
    }

    /// FM の経路。**独立に死ぬ**ので独立に持つ(ファイル冒頭 ②)
    public enum Path: String, Codable, Sendable {
        /// テキストのみの呼び出し。シナリオの下書き・命名(run の中では使わない)
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
        /// 公表した判定の元になった観測の刻印(表示・診断用。順序は根拠 `Basis` の観測で決める)
        public var stamp: Stamp?

        public init(state: State, checkedAt: Double, source: Source,
                    error: String? = nil, ms: Int? = nil, stamp: Stamp? = nil) {
            self.state = state
            self.checkedAt = checkedAt
            self.source = source
            self.error = error
            self.ms = ms
            self.stamp = stamp
        }

        /// `self` が `other` を上書きしてよいか。同じ起動の刻印どうしなら単調時刻で比べる(壁時計は補正で戻る)。
        /// 起動が違えば上書きしてよい(書き手は今の起動のプロセス = 前の起動の記録より新しい)。
        /// どちらかに刻印が無い・起動が識別できないときだけ壁時計で比べる
        /// **未来の記録は新しいとみなさない**(壁時計が戻った後の記録は、鮮度の窓ぶんを超えて未来にあれば不明に倒す)
        public func isFresh(now: Date = Date(), maxAge: TimeInterval = FMLiveness.freshSeconds) -> Bool {
            let age = now.timeIntervalSince1970 - checkedAt
            return age < maxAge && age > -maxAge
        }
    }

    /// ディスク上の形。経路ごとに独立(②)。`text` / `vision` は**公表する判定**(読み手はこれだけを見る)、
    /// `basis` はそれを導く根拠(書き手だけが使う = `derive`)
    public struct Record: Codable, Sendable, Equatable {
        public var text: Verdict?
        public var vision: Verdict?
        var basis: [String: Basis]?

        public init(text: Verdict? = nil, vision: Verdict? = nil) {
            self.text = text
            self.vision = vision
            self.basis = nil
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

        /// deadSummary() が末尾に必ず足す事実の1文。実測: text/vision とも
        /// ModelManagerError で数時間死に続け、その間 ANE が異常な状態のままカーネルパニック
        /// → 再起動直後は両経路とも生き返った。**直るとは断定しない**(この Mac の1回の観測)。
        /// テストの期待値組み立てにも使う(この文言はここ1箇所だけが正)
        public static let deadSummaryNote =
            " (if this persists across runs, rebooting this Mac has cleared this state before)"

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
            let joined = parts.joined(separator: " / ") + Self.deadSummaryNote
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
    /// この間隔を無視して即書く**(死んだ瞬間を遅らせない)。**畳むのは公表する判定(表示)だけ**で、根拠は毎回更新する
    /// (根拠まで畳むと、新しい刻印を捨てて古い観測に上書きを許す)
    static let writeCoalesceSeconds: TimeInterval = 5

    /// 書けない(テスト・opt-in していない)ときの、プロセス内の根拠
    private struct Memo {
        var localBasis: [Path: Basis] = [:]
    }
    private static let memo = Mutex(Memo())

    // MARK: - 置き場

    /// 置き場の差し替え(テストの隔離。FMHistory・FMHostMemory も同じ鍵で既定の置き場をやめる)
    static let directoryOverrideKey = "FT_FM_LIVENESS_DIR"

    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetest", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("fm-liveness.json") }
    /// 読み→畳み→書きを跨ぐ排他(flock)。書き手は複数プロセス(ワーカーの text と
    /// host-metrics プローブの vision)なので、rename の原子性だけでは足りない ——
    /// 両方が同じ古い記録を読んで畳むと、後に rename した側がもう片方の経路を古い値へ戻す(④の違反)
    static let lockFileName = "fm-liveness.lock"

    /// 書き込み先。nil = 書かない。**`LedgerWriteRole` が opt-in した production の実行ファイル
    /// だけへ書く**(fail-closed。LedgerWriteRole.swift 冒頭)。`XCTestConfigurationFilePath` の
    /// 判定は二重の備えとして残す —— `swift test --parallel` のワーカーでは立たないことがあるので
    /// これ単独では守れない。台帳自体を検証するテストは FT_FM_LIVENESS_DIR を明示するので影響を受けない。
    /// **`private` を外してあるのはテストのため**(@testable でこの門自体を直接検証する)
    static var writeURL: URL? {
        if let override = ProcessInfo.processInfo.environment[directoryOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("fm-liveness.json")
        }
        guard LedgerWriteRole.permitsProductionWrite else { return nil }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        return fileURL
    }

    // MARK: - 書く

    /// 観測1件を記録する(プローブ・availability・ブレーカ・実呼び出しの成功)。実呼び出しの失敗は `recordCallFailure`。
    /// 根拠(`Basis`)に足し、公表する判定を根拠から導き直す(`derive`)。**1つの臨界区間・1つのファイルで行う**
    /// (根拠と判定を別々に持つと、遅れて着いた観測で両者が食い違う)。書き込み失敗は握りつぶす(台帳のために FM の実行も
    /// 監視も止めない)。ファイル I/O をするので、呼び出し側のロックの内側から呼ばないこと
    public static func record(path: Path, state: State, source: Source,
                              error: String? = nil, ms: Int? = nil,
                              now: Date = Date(), observed: Stamp) {
        // 実呼び出し(FMHealth)とプローブ(FMLivenessProbe.settle)の失敗は、それぞれが1回ずつ履歴へ書く
        // (ここで書くと閾値の回が二重になる)。呼ばずに決めた死(availability・ブレーカ)はここで書く
        if state == .dead, source == .availability || source == .breaker {
            FMHistory.recordFailure(path: path, source: source, error: error, ms: ms, now: now)
        }
        let observation = Observation(stamp: observed, checkedAt: now.timeIntervalSince1970, source: source,
                                      error: state == .dead ? error : nil, ms: ms)
        let kind: ObservationKind = state == .alive ? .alive : (source == .call ? .callFailure : .deadDirect)
        _ = update(path: path, observed: observed, now: now) { insert(observation, kind: kind, into: &$0) }
    }

    /// 実呼び出しの失敗1件(FMHealth)。根拠の失敗に足し、閾値に達していれば導き直した判定が死になる
    public static func recordCallFailure(path: Path, error: String?, ms: Int?, now: Date = Date(), observed: Stamp) {
        let observation = Observation(stamp: observed, checkedAt: now.timeIntervalSince1970, source: .call,
                                      error: error, ms: ms)
        _ = update(path: path, observed: observed, now: now) { insert(observation, kind: .callFailure, into: &$0) }
    }

    /// 1つの臨界区間(`lockFileName` の flock)で 台帳を読み → 根拠を変え → 判定を導き直し → 1回の rename で書き、
    /// 変わり目を履歴へ書く(台帳 → 履歴のロック順。履歴は台帳のロックを取らない)。**台帳を書けなかった回は変わり目を
    /// 書かない**。返すのは変えた後の根拠。書けない(テスト・opt-in していない)ときはプロセスの中の根拠だけを変える
    /// **起動が識別できない刻印の観測は共有しない**(順序を確定できない = 共有の根拠に混ぜると比較が循環し、前回の起動の失敗を
    /// 今回へ引き継ぐ)。そのプロセスの中だけで持ち、台帳は書かない(台帳は他の書き手と監視のプローブが養う)。
    /// `observed` が nil(無条件の消去)は共有とプロセス内の両方を変える
    private static func update(path: Path, observed: Stamp?, now: Date, _ change: (inout Basis) -> Void) -> Basis {
        func local() -> Basis {
            memo.withLock { memo in
                var basis = memo.localBasis[path] ?? Basis()
                if let boot = observed?.boot { dropOtherBoots(&basis, boot: boot) }
                change(&basis)
                memo.localBasis[path] = basis
                return basis
            }
        }
        if observed == nil { _ = local() }
        guard let url = writeURL, observed?.boot != Stamp.unknownBoot else { return observed == nil ? Basis() : local() }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // ロックを取れないときは書かない —— 書き込み失敗と同じ扱い(握りつぶす)で、片方の経路を消す危険を冒さない
        guard let lockFD = openLocked(dir.appendingPathComponent(lockFileName)) else { return Basis() }
        defer { close(lockFD) }  // close が flock も解放する
        // ④ もう片方の経路を消さない(読んでから変えて書く)
        var record = read(at: url) ?? Record()
        var basis = record.basis?[path.rawValue] ?? Basis()
        if let boot = observed?.boot { dropOtherBoots(&basis, boot: boot) }
        change(&basis)
        var bases = record.basis ?? [:]
        bases[path.rawValue] = basis
        record.basis = bases
        let previous = record[path]
        if let derived = derive(basis) {
            // 表示の畳み: 同じ状態・同じ書き手で間隔の内なら前の公表を残す(根拠は上で更新済み)
            let keep = previous.map { $0.state == derived.state && $0.source == derived.source
                && abs(derived.checkedAt - $0.checkedAt) < writeCoalesceSeconds } ?? false
            if !keep { record[path] = derived }
        }
        guard writeAtomically(record, to: url) else { return basis }
        if let published = record[path], previous?.state != published.state {
            FMHistory.recordTransition(path: path, from: previous?.state, to: published.state,
                                       source: published.source, error: published.error, now: now)
        }
        return basis
    }

    /// 一時ファイル → 同一ディレクトリ内 rename(2)。読み手に途中まで書かれた JSON を見せない・リンクを辿らない
    private static func writeAtomically<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp")
        guard (try? data.write(to: tmp)) != nil else { return false }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }

    /// ロックファイルを開いて LOCK_EX を取る(ブロッキング。臨界区間は 1 回の read/encode/rename
    /// なので待ちは短い)。開けない・取れないときは nil。同一プロセスの別スレッドも open ごとに
    /// 別の open file description になるので互いに排他される
    private static func openLocked(_ lockURL: URL) -> Int32? {
        let fd = open(lockURL.path, O_CREAT | O_NOFOLLOW | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            close(fd)
            return nil
        }
        return fd
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

    /// **FM を呼ぶ前の門が読む判定**(`FMCallAdmission.enter(path:)`)。その経路が**新しい死**と記録されていれば
    /// true = 呼ばない。古い・不明・生は false(呼んで確かめる)。**書き込み先を開けない(テスト・
    /// opt-in していない)プロセスは本番の台帳を読まない** —— 読むと、機械の FM が死んでいる間だけ
    /// 無関係なテストの門が閉じる
    public static func isKnownDead(_ path: Path, now: Date = Date()) -> Bool {
        guard let url = writeURL else { return false }
        guard let verdict = read(at: url)?[path], verdict.isFresh(now: now) else { return false }
        return verdict.state == .dead
    }

    // MARK: - 観測の刻印

    // 連続失敗は**機械全体で数える**(台帳の根拠 `Basis.callFailures`): シナリオは1本ごとに別プロセスで走り、1本が FM を
    // 撃つのは数回なので、プロセス内で数えると閾値(FMBreaker.threshold)に届かず、死を1度も記録しないまま全シナリオが
    // 失敗の所要(実測 16 秒)を払っていた

    /// 観測の刻印。**順序の判定にだけ使う**(表示・鮮度は壁時計の `checkedAt`)。`boot` は起動ごとの識別子
    /// (`kern.bootsessionuuid`)、`mono` は起動からの単調な時刻(ns。`CLOCK_MONOTONIC` = 機械全体で共通・スリープも進む)。
    /// 壁時計は補正で戻るので、順序に使うと新しい成功を古いと誤る
    public struct Stamp: Codable, Sendable, Equatable {
        public var boot: String
        public var mono: UInt64

        public init(boot: String, mono: UInt64) {
            self.boot = boot
            self.mono = mono
        }

        public static func now() -> Stamp { Stamp(boot: bootID, mono: clock_gettime_nsec_np(CLOCK_MONOTONIC)) }

        /// 起動が識別できない印。**同じ起動の証拠として扱わない**(再起動をまたいで同じ値になる)=
        /// 連続失敗はプロセスの中だけで数え、台帳の順序は壁時計で比べる
        public static let unknownBoot = "unknown"

        /// 起動の識別子を親から子へ渡す環境変数(`ScenarioHost.childEnvironment`)。子のサンドボックスが sysctl の読みを
        /// 許さない形に変わっても、親(枠の外)が読んだ値で同じ起動を名乗れる
        public static let bootEnvironmentKey = "FT_BOOT_SESSION_ID"

        /// `kern.bootsessionuuid`(**全プロセスで同じ方式**。代替の方式と混ざると同じ起動を別と取り違え、互いの記録を捨て合う)。
        /// 取れなければ親が渡した `bootEnvironmentKey`、それも無ければ `unknownBoot`。**取れたときだけ覚える**
        /// (一過性の失敗を覚えると、そのプロセスは以後ずっと台帳を養わない)
        public static var bootID: String {
            if let cached = cachedBootID.withLock({ $0 }) { return cached }
            guard let id = resolveBootID(sysctl: readBootSessionID(), environment: ProcessInfo.processInfo.environment)
            else { return unknownBoot }
            cachedBootID.withLock { $0 = id }
            return id
        }

        /// sysctl の値を先に採る(親が渡した値はその代わり)。どちらも無ければ nil
        static func resolveBootID(sysctl: String?, environment: [String: String]) -> String? {
            if let sysctl, !sysctl.isEmpty { return sysctl }
            guard let inherited = environment[bootEnvironmentKey], !inherited.isEmpty else { return nil }
            return inherited
        }

        private static let cachedBootID = Mutex<String?>(nil)

        static func readBootSessionID() -> String? {
            var size = 0
            guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
            let id = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return id.isEmpty ? nil : id
        }
    }

    // MARK: - 根拠(観測の集合)と、そこから導く判定

    /// 1件の観測。順序は `isAfter`。**共有の根拠に入るのは識別できる起動の刻印の観測だけ**(`update`)
    struct Observation: Codable, Sendable, Equatable {
        var stamp: Stamp
        var checkedAt: Double
        var source: Source
        var error: String?
        var ms: Int?
    }

    /// 経路ごとの根拠。**公表する判定はこれから毎回同じ規則で導く**(`derive`)= 観測の着く順に依らない
    /// (どの順で足しても同じ集合になる: 最新の生・最新の自分で決めた死・新しい側の失敗)
    struct Basis: Codable, Sendable, Equatable {
        /// 最新の生の観測(書き手を問わない)
        var lastAlive: Observation?
        /// 最新の「自分で死と決めた」観測(プローブ = プロセス内の閾値の後・availability・ブレーカ)
        var lastDeadDirect: Observation?
        /// 実呼び出しの失敗の新しい側 `maxKeptFailures` 件(古い順)
        var callFailures: [Observation] = []
    }

    enum ObservationKind {
        case alive, deadDirect, callFailure
    }

    /// 持っておく失敗の上限。判定は「最新の生より後の失敗が FMBreaker.threshold 件以上か」だけなので、新しい側をそれだけ
    /// 持てば足りる(閾値以上あれば新しい側の閾値件は全部その後ろにあり、無ければ後ろの件数は新しい側の中に全部ある)
    static var maxKeptFailures: Int { FMBreaker.threshold }

    /// `a` が `b` より新しいか = **単調時刻だけで比べる**(全順序)。根拠には同じ起動の識別できる刻印の観測しか入らない
    /// (`dropOtherBoots` と unknown の隔離)ので比べられる。壁時計を混ぜると比較が循環し(単調時刻では a<b<c なのに
    /// 壁時計では c<a)、着く順で判定が変わる
    static func isAfter(_ a: Observation, _ b: Observation) -> Bool {
        a.stamp.mono > b.stamp.mono
    }

    static func insert(_ observation: Observation, kind: ObservationKind, into basis: inout Basis) {
        func newer(_ current: Observation?) -> Observation {
            guard let current, !isAfter(observation, current) else { return observation }
            return current
        }
        switch kind {
        case .alive: basis.lastAlive = newer(basis.lastAlive)
        case .deadDirect: basis.lastDeadDirect = newer(basis.lastDeadDirect)
        case .callFailure:
            basis.callFailures = Array((basis.callFailures + [observation]).sorted { isAfter($1, $0) }
                .suffix(maxKeptFailures))
        }
    }

    /// 別の起動の根拠を捨てる(前回の起動の失敗を引き継がない・単調時刻は起動ごとに 0 から始まる)
    static func dropOtherBoots(_ basis: inout Basis, boot: String) {
        if let alive = basis.lastAlive, alive.stamp.boot != boot { basis.lastAlive = nil }
        if let dead = basis.lastDeadDirect, dead.stamp.boot != boot { basis.lastDeadDirect = nil }
        basis.callFailures = basis.callFailures.filter { $0.stamp.boot == boot }
    }

    /// 公表する判定。候補 = 最新の生 / 最新の自分で決めた死 / 最新の生より後に閾値以上ある実呼び出しの失敗の最新。
    /// **最も新しい候補を採る**(同じ新しさなら死 = 安全側)。候補が無ければ nil(公表を変えない)
    static func derive(_ basis: Basis, threshold: Int = FMBreaker.threshold) -> Verdict? {
        var candidates: [(observation: Observation, state: State)] = []
        if let alive = basis.lastAlive { candidates.append((alive, .alive)) }
        if let dead = basis.lastDeadDirect { candidates.append((dead, .dead)) }
        let afterAlive = basis.callFailures.filter { failure in basis.lastAlive.map { isAfter(failure, $0) } ?? true }
        if afterAlive.count >= threshold, let newest = afterAlive.max(by: { isAfter($1, $0) }) {
            candidates.append((newest, .dead))
        }
        guard var best = candidates.first else { return nil }
        for candidate in candidates.dropFirst()
        where isAfter(candidate.observation, best.observation)
            || (!isAfter(best.observation, candidate.observation) && candidate.state == .dead) {
            best = candidate
        }
        return Verdict(state: best.state, checkedAt: best.observation.checkedAt, source: best.observation.source,
                       error: best.state == .dead ? best.observation.error : nil, ms: best.observation.ms,
                       stamp: best.observation.stamp)
    }

    /// 実呼び出しの失敗を1件足し(台帳の判定も導き直す)、最新の生より後の失敗の数を返す
    public static func bumpFailureStreak(_ path: Path, at stamp: Stamp, now: Date = Date()) -> Int {
        let observation = Observation(stamp: stamp, checkedAt: now.timeIntervalSince1970, source: .call)
        let basis = update(path: path, observed: stamp, now: now) { insert(observation, kind: .callFailure, into: &$0) }
        return basis.callFailures.filter { failure in basis.lastAlive.map { isAfter(failure, $0) } ?? true }.count
    }

    /// 生の観測(実呼び出し)を1件足す = その刻印より前の失敗を数えなくする。nil は**実呼び出しの失敗を無条件に消す**
    /// (`FMHealth.reset` = テストと計測の区切り)
    public static func resetFailureStreak(_ path: Path, observedAt stamp: Stamp? = nil, now: Date = Date()) {
        guard let stamp else {
            _ = update(path: path, observed: nil, now: now) { $0.callFailures = [] }
            return
        }
        let observation = Observation(stamp: stamp, checkedAt: now.timeIntervalSince1970, source: .call)
        _ = update(path: path, observed: stamp, now: now) { insert(observation, kind: .alive, into: &$0) }
    }

    /// テスト用。プロセス内の根拠を捨てる(ディスクは触らない)
    public static func resetWriteMemo() {
        memo.withLock { $0 = Memo() }
    }
}
