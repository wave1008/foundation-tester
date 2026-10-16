// FM の観測の履歴(追記式・機械グローバル)。`FMLiveness` の台帳は経路ごとに**最新の1件だけ**を上書きするので、
// 「死んでいた」は次の生の観測で消える。ここはその消える側 —— **失敗・死に変わった・生に戻った**だけを時刻つきで残す。
//
// 規律:
//  ① **60 秒おきの生は書かない**。書くのは失敗(書き手を問わない)と状態の変わり目だけ
//  ② **同じ失敗の連続は1行に畳む**(経路・書き手・エラーが同じなら `count` と `lastAt` を進める)。
//     死んだまま毎秒失敗しても行が増えない
//  ③ **変わり目は台帳のロックの内側で書く**(`FMLiveness.write` が着地した直後)。外で書くと、台帳の更新順と
//     履歴の順が入れ替わる(died と recovered が逆に並ぶ)。ロックの順序は常に 台帳 → 履歴(履歴から台帳は取らない)
//  ④ **死に変わった回だけ OS 側の証拠を添える**(ANE の `no memory` / `Code=53` の行)。OS のログは後から
//     読めないことがある。`log show` は数秒かかるので別スレッドで撃ち、別の行(`evidence`)として足す。
//     撃ったプロセスが先に終わると欠ける(監視のプローブは長く生きるのでそこで拾える)。子は自分の期限を持つ
//     (`selfBounded`)= 親が先に終わっても残るのは期限まで
//  ⑤ **保持は `maxAgeSeconds` か `maxBytes` の早いほう**。超えたら古い行から捨てる(書き込みのついでに)。
//     捨てるときは一時ファイルに書いて rename(途中で死んでも元の履歴は残る)
//  ⑥ **リンクを辿らない**。`~/.fleetest` はシナリオのプロセス(サンドボックスの中)も書けるので、履歴をリンクに
//     差し替えられると、枠の外の監視プロセスがリンク先を書き換える。`O_NOFOLLOW` で開き通常のファイルだけ扱う
//
// 置き場は台帳と同じ(`FMLiveness.writeURL` の隣)= 本番の実行ファイルだけが書き、テストは
// `FT_FM_LIVENESS_DIR` へ逃げる。再起動では消えない。読み手は `fleetest doctor --fm-only`。

import Foundation
import Synchronization

public enum FMHistory {
    public enum Kind: String, Codable, Sendable {
        /// 失敗の観測(畳んだ回数つき)
        case failure
        /// 生(または未観測)から死に変わった
        case died
        /// 死から生に戻った
        case recovered
        /// 死に変わったときの OS 側のログの抜き出し
        case evidence
    }

    public struct Event: Codable, Sendable, Equatable {
        public var kind: Kind
        public var path: FMLiveness.Path
        public var source: FMLiveness.Source?
        public var error: String?
        public var ms: Int?
        /// 最初に観測した時刻(epoch 秒)
        public var at: Double
        /// 畳んだ失敗の最後の時刻(1回だけなら nil)
        public var lastAt: Double?
        /// 畳んだ失敗の回数(1回だけなら nil)
        public var count: Int?
        public var lines: [String]?

        public init(kind: Kind, path: FMLiveness.Path, source: FMLiveness.Source? = nil, error: String? = nil,
                    ms: Int? = nil, at: Double, lastAt: Double? = nil, count: Int? = nil, lines: [String]? = nil) {
            self.kind = kind
            self.path = path
            self.source = source
            self.error = error
            self.ms = ms
            self.at = at
            self.lastAt = lastAt
            self.count = count
            self.lines = lines
        }

        /// 保持の判定に使う最後の時刻
        var newestAt: Double { lastAt ?? at }
    }

    public static let fileName = "fm-history.ndjson"
    static let lockFileName = "fm-history.lock"

    /// 保持の容量(バイト)。1行は約 300 バイト(エラーを `errorLimit` で切った長さ)なので約 1.7 万件。
    /// ②で失敗の連続は1行に畳むので、変わり目と失敗の塊だけなら数か月ぶんが入る。尽きたら古い行から捨てる
    public static let maxBytes: Int = 5 * 1_048_576
    /// 保持の期間(秒)= 30 日。死の原因を後から突き合わせるのは数日以内(負荷テスト・回帰の振り返り)なので、
    /// その数倍。超えた行は次の書き込みのついでに捨てる
    public static let maxAgeSeconds: TimeInterval = 30 * 86_400
    /// 捨てるときに残す量(容量の割合)。毎回の書き込みで境界を跨いで捨て直さないための余白
    /// (保持の掃除 `RetentionSweep` の「90% まで戻す」と同じ考え)
    static let pruneTargetRatio = 0.9
    /// 1件に残すエラー・証拠の1行の長さ(UTF-8 のバイト数。文字の境界で切る = `truncated`)。`FMHealth.record` の
    /// firstError と同じ 800 では1行が大きすぎるので、入れ子の連鎖の先頭(真因の domain が入る)が収まる長さ
    static let errorLimit = 600
    /// 末尾の1行を探す窓(バイト)。窓が要るのは**畳む対象の failure 行**だけで、その上限はエラー `errorLimit` バイトの
    /// JSON エスケープ(制御文字は `\u0001` の 6 倍)≒ 3.6KB + 欄名なので、その4倍強。窓に改行が無い(証拠の長い行等)
    /// ときは畳まずに足す側へ倒す(evidence 行は畳まない)
    static let tailWindowBytes = 16 * 1024

    /// UTF-8 で `maxBytes` 以下になるよう、Unicode スカラーの境界で切る(`prefix(n)` は文字数なので、結合文字や
    /// 多バイト文字でバイト数の上限にならない)
    static func truncated(_ text: String, maxBytes: Int) -> String {
        var bytes = 0
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            guard bytes + size <= maxBytes else { break }
            bytes += size
            scalars.append(scalar)
        }
        return String(scalars)
    }
    /// 最も古い行の時刻(`newestAt` の最小)の控え。期間を過ぎたかを毎回全体を読まずに決める(行は時刻順とは限らないので、
    /// 先頭の行では決められない)
    static let oldestFileName = "fm-history.oldest"

    static var fileURL: URL? {
        FMLiveness.writeURL?.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    // MARK: - 書く

    /// 失敗1件。直前の行が同じ経路・書き手・エラーの失敗なら畳む(②)
    public static func recordFailure(path: FMLiveness.Path, source: FMLiveness.Source,
                                     error: String?, ms: Int?, now: Date = Date()) {
        guard let url = fileURL else { return }
        let event = Event(kind: .failure, path: path, source: source,
                          error: error.map { truncated($0, maxBytes: errorLimit) }, ms: ms,
                          at: now.timeIntervalSince1970)
        append(event, to: url, now: now, collapsingWith: { last in
            guard last.kind == .failure, last.path == event.path, last.source == event.source,
                  last.error == event.error else { return nil }
            var merged = last
            merged.count = (last.count ?? 1) + 1
            merged.lastAt = event.at
            merged.ms = event.ms
            return merged
        })
    }

    /// 台帳の状態が変わった。**`FMLiveness.write` が台帳のロックを握ったまま呼ぶ**(③)。
    /// 死に変わった回は OS 側の証拠を別スレッドで取りに行く(④)。置き場と取得口は**依頼した時点で固定する**
    /// (後から走る取得が、差し替え後の置き場・取得口を使わない)
    static func recordTransition(path: FMLiveness.Path, from previous: FMLiveness.State?,
                                 to state: FMLiveness.State, source: FMLiveness.Source,
                                 error: String?, now: Date = Date()) {
        guard let url = fileURL else { return }
        let kind: Kind
        switch (previous, state) {
        case (.dead?, .alive): kind = .recovered
        case (.alive?, .dead), (nil, .dead): kind = .died
        default: return
        }
        append(Event(kind: kind, path: path, source: source,
                     error: kind == .died ? error.map { truncated($0, maxBytes: errorLimit) } : nil,
                     at: now.timeIntervalSince1970), to: url, now: now, collapsingWith: nil)
        guard kind == .died else { return }
        let provider = evidenceProvider.withLock { $0 }
        evidenceQueue.async {
            guard let lines = provider(), !lines.isEmpty else { return }
            append(Event(kind: .evidence, path: path, at: Date().timeIntervalSince1970, lines: lines),
                   to: url, now: Date(), collapsingWith: nil)
        }
    }

    /// 書き込みの本体。flock の内側で 半端な末尾を切り戻す → 末尾の1行を読み、畳むか足す → 保持を超えていれば捨てる
    private static func append(_ event: Event, to url: URL, now: Date,
                               collapsingWith collapse: ((Event) -> Event?)?) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let lockFD = openLocked(dir.appendingPathComponent(lockFileName)) else { return }
        defer { close(lockFD) }
        guard let handle = openRegularFile(url) else { return }
        defer { try? handle.close() }
        guard var size = try? handle.seekToEnd() else { return }
        // 半端な末尾(書き込みの途中で死んだ行)は最後の改行まで切り戻す。残すと次の行が連結して一緒に読めなくなる
        if size > 0, let end = completeLength(handle, size: size), end != size {
            guard (try? handle.truncate(atOffset: end)) != nil else { return }
            size = end
        }
        var writeOffset = size
        var toWrite = event
        if let collapse, let (offset, last) = lastEvent(handle, size: size), let merged = collapse(last) {
            writeOffset = offset
            toWrite = merged
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(toWrite) else { return }
        data.append(0x0A)
        // **控えを本体より先に**(小さいほうへ)進める: 本体を書いた後・控えの前に死ぬと、控えが本体の古い行を知らず
        // 期間による掃除を取り逃す。先に書けば、途中で死んでも掃除が早めに走るだけ
        let oldestURL = url.deletingLastPathComponent().appendingPathComponent(oldestFileName)
        guard let stored = readOldest(oldestURL) ?? scanOldest(handle, appendedAt: toWrite.newestAt) else { return }
        let oldest = min(stored, toWrite.newestAt)
        // 控えを書けなければ控えを消す(次は全体を読んで作り直す)。消すこともできなければ本体を書かない
        // (控えが本体の古い行を知らないまま進むと、期間による掃除を取り逃す)
        if !writeOldest(oldest, to: oldestURL) {
            try? FileManager.default.removeItem(at: oldestURL)
            guard !FileManager.default.fileExists(atPath: oldestURL.path) else { return }
        }
        do {
            try handle.truncate(atOffset: writeOffset)
            try handle.seek(toOffset: writeOffset)
            try handle.write(contentsOf: data)
        } catch { return }
        pruneIfNeeded(handle, url: url, now: now, oldest: oldest, oldestURL: oldestURL)
    }

    /// 本体を全部読んで最も古い行の時刻を出す(控えが無い・読めないとき)。読めない行は -inf = 掃除の対象
    private static func scanOldest(_ handle: FileHandle, appendedAt: Double) -> Double? {
        guard (try? handle.seek(toOffset: 0)) != nil else { return nil }
        // 空のファイルは readToEnd が nil を返す(空として扱う)
        let all = (try? handle.readToEnd()) ?? Data()
        return all.split(separator: 0x0A)
            .map { (try? JSONDecoder().decode(Event.self, from: Data($0)))?.newestAt ?? -.infinity }
            .min() ?? appendedAt
    }

    /// `O_NOFOLLOW` で開き、通常のファイルだけを返す(⑥)。リンク・ディレクトリ等は nil(書かない)
    private static func openRegularFile(_ url: URL) -> FileHandle? {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// 最後の改行までの長さ(改行で終わっていればそのまま)。窓の中に改行が無ければ、窓の手前まで遡らずに
    /// 全体を読んで探す(半端な行は1行の上限程度なので、ここに来るのは壊れた回だけ)
    private static func completeLength(_ handle: FileHandle, size: UInt64) -> UInt64? {
        let window = min(size, UInt64(tailWindowBytes))
        guard (try? handle.seek(toOffset: size - window)) != nil,
              let tail = try? handle.read(upToCount: Int(window)) else { return nil }
        if tail.last == 0x0A { return size }
        if let newline = tail.lastIndex(of: 0x0A) {
            return size - window + UInt64(newline - tail.startIndex) + 1
        }
        guard (try? handle.seek(toOffset: 0)) != nil, let all = try? handle.readToEnd() else { return nil }
        return all.lastIndex(of: 0x0A).map { UInt64($0 - all.startIndex) + 1 } ?? 0
    }

    /// 末尾の1行(とその開始位置)。読めない・壊れている行は nil(畳まずに足す側へ倒す)
    private static func lastEvent(_ handle: FileHandle, size: UInt64) -> (UInt64, Event)? {
        guard size > 0 else { return nil }
        let window = min(size, UInt64(tailWindowBytes))
        guard (try? handle.seek(toOffset: size - window)) != nil,
              let tail = try? handle.read(upToCount: Int(window)) else { return nil }
        var body = tail
        guard body.last == 0x0A else { return nil }
        body.removeLast()
        let start = body.lastIndex(of: 0x0A).map { body.index(after: $0) } ?? body.startIndex
        // 窓の先頭から始まる行は途中から切れている可能性がある(窓 = ファイル全体のときだけ信じる)
        if start == body.startIndex, window < size { return nil }
        let line = body[start...]
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(line)) else { return nil }
        return (size - window + UInt64(start - tail.startIndex), event)
    }

    /// 容量を超えたか、最も古い行(控え `oldestFileName`)が期間を過ぎたとき、**行ごとに**期間内か確かめ、新しい側から
    /// `maxBytes * pruneTargetRatio` に収まるぶんだけ残す。行の順は書いた順で、時刻順とは限らない(複数のプロセスが
    /// 時刻を採ってからロックを取る)ので、古い行で打ち切らない。書き直しは一時ファイル → rename(⑤)。
    /// 履歴のロックの内側から呼ぶ
    private static func pruneIfNeeded(_ handle: FileHandle, url: URL, now: Date, oldest: Double, oldestURL: URL) {
        guard let size = try? handle.seekToEnd() else { return }
        let cutoff = now.timeIntervalSince1970 - maxAgeSeconds
        guard size > UInt64(maxBytes) || oldest < cutoff else { return }
        guard (try? handle.seek(toOffset: 0)) != nil, let all = try? handle.readToEnd() else { return }
        let budget = Int(Double(maxBytes) * pruneTargetRatio)
        var kept: [Data] = []
        var keptOldest = Double.infinity
        var total = 0
        for line in all.split(separator: 0x0A).reversed() {
            guard let event = try? JSONDecoder().decode(Event.self, from: Data(line)),
                  event.newestAt >= cutoff else { continue }
            guard total + line.count + 1 <= budget else { break }
            kept.append(Data(line))
            keptOldest = min(keptOldest, event.newestAt)
            total += line.count + 1
        }
        var out = Data()
        for line in kept.reversed() {
            out.append(line)
            out.append(0x0A)
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".fm-history.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp")
        guard (try? out.write(to: tmp)) != nil else { return }
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        if !writeOldest(keptOldest.isFinite ? keptOldest : now.timeIntervalSince1970, to: oldestURL) {
            try? FileManager.default.removeItem(at: oldestURL)
        }
    }

    private static func readOldest(_ url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 一時ファイル → rename(リンクを辿らない = ⑥)。書けたら(または既に同じ値なら)true
    @discardableResult
    private static func writeOldest(_ value: Double, to url: URL) -> Bool {
        if readOldest(url) == value { return true }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".fm-history-oldest.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp")
        guard (try? Data(String(value).utf8).write(to: tmp)) != nil else { return false }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }

    private static func openLocked(_ lockURL: URL) -> Int32? {
        let fd = open(lockURL.path, O_CREAT | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            close(fd)
            return nil
        }
        return fd
    }

    // MARK: - OS 側の証拠(④)

    /// 証拠を取りに行く口。テストは差し替える(`log show` を撃たない)
    public static let evidenceProvider = Mutex<@Sendable () -> [String]?>({ aneLogEvidence() })
    /// 証拠の取得を直列に回す(record の呼び手を数秒待たせない)。テストは `waitForPendingEvidence` で待つ
    static let evidenceQueue = DispatchQueue(label: "fleetest.fm-history.evidence")

    public static func waitForPendingEvidence() {
        evidenceQueue.sync {}
    }

    /// 読むログの窓(分)。死の検出は監視のプローブ間隔(60 秒)か実呼び出しの直後なので、死の実体
    /// (ANE の読み込み失敗)はその数分前までに出ている。広げると `log show` の所要と出力が伸びる
    static let evidenceWindowMinutes = 5
    /// 残す行数。同じ失敗が毎秒並ぶので、真因の行は数行で足りる。1行の上限(`tailWindowBytes`)を抑える値
    static let evidenceMaxLines = 5
    /// `log show` の上限(秒)。実測 5 分ぶんで 2.9〜4.7 秒(M2Ultra)の約 4 倍 = 負荷の高い機械でも収まる余裕。
    /// 尽きたら証拠なしで終える
    static let evidenceTimeoutSeconds: Double = 20

    static func aneLogEvidence() -> [String]? {
        // 台帳の置き場を差し替えている(テスト)間は撃たない。証拠のテストは evidenceProvider を差し替える
        if let override = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"], !override.isEmpty { return nil }
        // **印の行だけを OS 側で絞る**: 絞らないと 5 分ぶんで 16.7MB・8.1 万行を全部メモリに読んでいた(実測。所要は同じ 2.9 秒)
        let predicate = "(process == \"aned\" OR process == \"aneuserd\" OR process == \"TGOnDeviceInferenceProviderService\")"
            + " AND (" + evidenceMarks.map { "eventMessage CONTAINS \"\($0)\"" }.joined(separator: " OR ") + ")"
        let argv = selfBounded(["/usr/bin/log", "show", "--last", "\(evidenceWindowMinutes)m",
                                "--style", "compact", "--predicate", predicate],
                               seconds: Int(evidenceTimeoutSeconds))
        guard let output = try? Shell.run(argv, timeout: evidenceTimeoutSeconds + 5).outputIfSucceeded else { return nil }
        return evidenceLines(from: output)
    }

    /// 子に自分の期限を持たせる包み。`Shell.run` の期限は親が生きている間しか効かない(親が先に終わると
    /// 子は残る)ので、見張りが `seconds` 後に TERM、その 2 秒後に KILL を送る(TERM を無視する子も止める)。
    /// 親の生死に関わらず子が残るのは `seconds` + 2 秒まで
    static func selfBounded(_ argv: [String], seconds: Int) -> [String] {
        let script = """
            s=$1; shift
            "$@" & c=$!
            ( sleep "$s"; kill -TERM $c 2>/dev/null; sleep 2; kill -KILL $c 2>/dev/null ) </dev/null >/dev/null 2>&1 & w=$!
            wait $c; r=$?
            kill $w 2>/dev/null
            exit $r
            """
        return ["/bin/sh", "-c", script, "fleetest-fm-evidence", String(seconds)] + argv
    }

    /// 死の実体(ANE の読み込み失敗)の印。OS 側の絞り込みと、出力の行の選別の両方に使う
    static let evidenceMarks = ["no memory", "Code=53", "Program load failed"]

    static func evidenceLines(from output: String) -> [String]? {
        let hits = output.split(separator: "\n")
            .filter { line in evidenceMarks.contains { line.contains($0) } }
            .suffix(evidenceMaxLines)
            .map { truncated(String($0), maxBytes: errorLimit) }
        return hits.isEmpty ? nil : Array(hits)
    }

    // MARK: - 読む

    /// 書いた順の末尾 `limit` 件。読めない行は飛ばす。
    /// 読むのは書き込みの門に関係なく本番の置き場(`FT_FM_LIVENESS_DIR` があればそちら)
    public static func recent(limit: Int) -> [Event] {
        guard let data = try? Data(contentsOf: FMLiveness.directory.appendingPathComponent(fileName)) else { return [] }
        let events = data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(Event.self, from: Data($0)) }
        return Array(events.suffix(limit))
    }

    /// doctor の1行。時刻は手元の時計のローカル時刻
    public static func describe(_ event: Event) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let at = formatter.string(from: Date(timeIntervalSince1970: event.at))
        let source = event.source.map { " (\($0.rawValue))" } ?? ""
        switch event.kind {
        case .failure:
            let times = event.count.map { " ×\($0) until \(formatter.string(from: Date(timeIntervalSince1970: event.lastAt ?? event.at)))" } ?? ""
            return "\(at) \(event.path.rawValue) failed\(times)\(source): \(event.error ?? "-")"
        case .died:
            return "\(at) \(event.path.rawValue) became dead\(source): \(event.error ?? "-")"
        case .recovered:
            return "\(at) \(event.path.rawValue) recovered\(source)"
        case .evidence:
            return "\(at) \(event.path.rawValue) OS log at death: " + (event.lines ?? []).joined(separator: " | ")
        }
    }
}
