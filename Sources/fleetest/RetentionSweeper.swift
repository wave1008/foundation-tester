// RetentionSweeper.swift
// 保持容量の掃除の I/O 側。**判定は持たない** —— 新しい順に積んで上限を超えた分を落とす規則は
// `FTCore.RetentionSweep.plan`(純粋関数)が唯一の定義元で、ここは
// ①4系統の「セッション」を採ってくる ②plan の結果のパスを消す、の2つだけを行う。
//
// 消してよい/いけないの境界(guarded)は系統ごとに違うが、**採取したセッションを消すのは
// `apply` 1箇所**に閉じる —— 系統ごとに削除を書くと、どれかが「結果 JSON も消す」ような
// 取り返しのつかない差分を静かに持つ。

import FTBridgeClient
import FTCore
import Foundation

enum RetentionSweeper {

    enum Category: String, CaseIterable, Sendable {
        case deviceCaptures, recordings, reports, logs

        func maxBytes(_ policy: RetentionPolicy) -> Int64 {
            switch self {
            case .deviceCaptures: return policy.effectiveDeviceCapturesMaxBytes
            case .recordings: return policy.effectiveRecordingsMaxBytes
            case .reports: return policy.effectiveReportsMaxBytes
            case .logs: return policy.effectiveLogsMaxBytes
            }
        }
    }

    /// **時間で打ち切らない**。自動の掃除は run の完了後に**別プロセスの背景**で走る
    /// (`RunCompletionSweep`)のでテストの実行時間に乗らず、手動は頼まれた分を最後まで消す。
    /// 同時に2本は走らない(`FTCore.RetentionSweepLock`)

    // MARK: - セッションの採取

    static func sessions(for category: Category, repoRoot: URL,
                         activeRunID: String?) -> [RetentionSweep.Session] {
        switch category {
        case .deviceCaptures: return deviceCaptureSessions(repoRoot: repoRoot)
        case .recordings: return recordingSessions(repoRoot: repoRoot, activeRunID: activeRunID)
        case .reports: return reportSessions(repoRoot: repoRoot, activeRunID: activeRunID)
        case .logs: return logSessions(repoRoot: repoRoot)
        }
    }

    // MARK: - (a) 録画

    /// 単位は run 1件。**消すのは `recordings/` だけ** —— runDir 自体・run.json・scenarios/ は
    /// 残す(結果 JSON を消すと run の履歴・LPT の実績が失われる)
    static func recordingSessions(repoRoot: URL, activeRunID: String?) -> [RetentionSweep.Session] {
        var sessions: [RetentionSweep.Session] = []
        for project in ProjectStore.all(repoRoot: repoRoot) {
            for runDir in runDirectories(project: project) {
                let dir = runDir.appendingPathComponent(RecordingIndexIO.directoryName)
                guard let measured = measure(directory: dir) else { continue }
                sessions.append(RetentionSweep.Session(
                    id: runDir.lastPathComponent, bytes: measured.bytes,
                    newestModified: measured.newest, paths: [dir],
                    guarded: runIsGuarded(runDir: runDir, activeRunID: activeRunID)))
            }
        }
        return sessions
    }

    // MARK: - (b) レポート

    /// **セッション内のパスを並べ替えない** —— 削除の順序に意味は無く、`URL.path` での比較は
    /// 日本語のファイル名を毎回 Unicode 正規化するので 15 万件で採取時間の大半を食った
    /// (実測: 採取 20 秒のうち並べ替えが 98%)。決定性は plan の (mtime, id) 順が持つ。
    /// **単位は run ではなく日**。**日付が読めないファイルには触らない**
    /// (利用者が置いた別のファイルかもしれない)。run 単位(結果 JSON の `reportPath` で引く)は実測で
    /// 360 秒かかった —— 結果 JSON 155,785 件の復号と、PNG を stem で親へ結び直す総当たり
    /// (5,444 × 147,375 回の接頭辞照合)が乗る。日単位ならファイル名だけで決まり 1 秒未満で、
    /// **1 run のレポートは同じ日に落ちる**(日を跨ぐ run だけが2つに割れるが、
    /// どちらも同じ側から消えるので中途半端には残らない)。
    /// 読み手は結果 JSON の `reportPath` が指す先の消失に耐える(拡張の両経路が存在を確かめる)。
    ///
    /// 日は**ファイル名のローカル時刻**から取る(runID の UTC とは別系統。混ぜない)。
    /// `.md` と `.png` はどちらも `scenario-<yyyyMMdd>-<HHmmss>-<SSS>-` で始まる
    /// (`ScenarioReportWriter` の命名)ので、同じ規則で1つの日へ入る。
    static func reportSessions(repoRoot: URL, activeRunID: String?) -> [RetentionSweep.Session] {
        // 今日のぶんは触らない(たった今終わった run のレポートを守る唯一の砦。
        // activeRunID は UTC の runID なので日の判定には使えない)
        let today = localDayStamp(Date())
        var sessions: [RetentionSweep.Session] = []
        for project in ProjectStore.all(repoRoot: repoRoot) {
            var byDay: [String: [URL]] = [:]
            for url in regularFiles(in: project.reportsDir) {
                guard let day = reportDay(of: url.lastPathComponent) else { continue }
                byDay[day, default: []].append(url)
            }
            for (day, files) in byDay {
                guard let measured = measure(files: files) else { continue }
                sessions.append(RetentionSweep.Session(
                    id: "\(project.name) \(day)", bytes: measured.bytes,
                    newestModified: measured.newest, paths: files,
                    guarded: day >= today))
            }
        }
        return sessions
    }

    /// レポートのファイル名と同じ `yyyyMMdd`(ローカル時刻)
    static func localDayStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `scenario-<yyyyMMdd>-<HHmmss>-<SSS>-…`(ScenarioReportWriter の baseName)の日付部。
    /// この形でなければ nil = 対象外
    static func reportDay(of fileName: String) -> String? {
        guard fileName.range(of: "^scenario-[0-9]{8}-[0-9]{6}-[0-9]{3}-",
                             options: .regularExpression) != nil else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: "scenario-".count)
        return String(fileName[start..<fileName.index(start, offsetBy: 8)])
    }

    // MARK: - (c) ログ

    /// 単位はファイル1本。`bridge-<port>.log` は1ブリッジセッション、`pre-push-*` / `install-*` は
    /// 1回の実行のログなので、まとめずに1本=1セッションでよい。
    /// **生死は `FTCore.ProcessLiveness.isAlive` だけで見る**(`kill(pid, 0)` はゾンビにも成功する)
    static func logSessions(repoRoot: URL) -> [RetentionSweep.Session] {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        var sessions: [RetentionSweep.Session] = []
        for url in regularFiles(in: stateDir) where url.pathExtension == "log" {
            guard let measured = measure(files: [url]) else { continue }
            sessions.append(RetentionSweep.Session(
                id: url.lastPathComponent, bytes: measured.bytes, newestModified: measured.newest,
                paths: [url], guarded: bridgeLogIsLive(url: url, stateDir: stateDir)))
        }
        return sessions
    }

    private static func bridgeLogIsLive(url: URL, stateDir: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("bridge-"),
              let port = UInt16(name.dropFirst("bridge-".count)) else { return false }
        return pid(ofBridgePort: port, stateDir: stateDir).map(ProcessLiveness.isAlive) ?? false
    }

    // MARK: - (d) デバイス由来の添付

    /// `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Data/InternalDaemon/
    /// <container>/tmp/Attachments/` 直下の通常ファイル。**ディレクトリは消さない**
    /// (testmanagerd が置き場として掴んでいる)。
    ///
    /// セッション境界は「そのデバイスで今稼働しているブリッジのプロセス開始時刻」:
    ///   - 生きているブリッジがある → 開始時刻より前 = 消してよい / 以降 = guarded
    ///   - ブリッジが無く Shutdown → 全部が1つの消してよいセッション
    ///   - ブリッジが無いが Booted → **丸ごと guarded**(このリポジトリ以外の誰かが使っている
    ///     可能性がある)。起動状態が読めないときも同じ扱い
    static func deviceCaptureSessions(repoRoot: URL) -> [RetentionSweep.Session] {
        let devicesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let bridges = liveBridgeStarts(repoRoot: repoRoot)
        // simctl は**1回だけ**(デバイスごとに呼ぶと台数ぶんの秒を払う)。読めなければ
        // 起動状態は不明 = 全台 guarded へ倒す
        let booted: Set<String>? = (try? SimulatorCatalog.devices())
            .map { Set($0.filter(\.booted).map(\.udid)) }

        var sessions: [RetentionSweep.Session] = []
        for deviceDir in subdirectories(of: devicesDir) {
            let udid = deviceDir.lastPathComponent
            guard let attachments = testManagerAttachments(deviceDir: deviceDir) else { continue }
            let files = regularFiles(in: attachments)
            guard !files.isEmpty else { continue }

            if let bridge = bridges[udid] {
                guard let started = bridge.earliest else {
                    // ブリッジは生きているが開始時刻が読めない → 境界を引けないので触らない
                    appendSession(&sessions, id: "\(udid) (bridge, start time unknown)",
                                  files: files, guarded: true)
                    continue
                }
                // mtime が読めないファイルは「以降」側 = guarded へ入れる(安全側)
                let older = files.filter { modified($0).map { $0 < started } ?? false }
                let olderPaths = Set(older.map(\.path))
                appendSession(&sessions, id: "\(udid) before the bridge started",
                              files: older, guarded: false)
                appendSession(&sessions, id: "\(udid) since the bridge started",
                              files: files.filter { !olderPaths.contains($0.path) }, guarded: true)
                continue
            }
            guard let booted else {
                appendSession(&sessions, id: "\(udid) (device state unknown)",
                              files: files, guarded: true)
                continue
            }
            appendSession(&sessions, id: booted.contains(udid) ? "\(udid) (booted, no bridge)" : udid,
                          files: files, guarded: booted.contains(udid))
        }
        return sessions
    }

    private static func appendSession(_ sessions: inout [RetentionSweep.Session], id: String,
                                      files: [URL], guarded: Bool) {
        guard let measured = measure(files: files) else { return }
        sessions.append(RetentionSweep.Session(
            id: id, bytes: measured.bytes, newestModified: measured.newest,
            paths: files, guarded: guarded))
    }

    /// MCMMetadataIdentifier が `com.apple.testmanagerd` のコンテナだけを見る。
    /// **他のコンテナには触らない**(同じ InternalDaemon の下に kvs / sbd 等が並ぶ)
    private static func testManagerAttachments(deviceDir: URL) -> URL? {
        let daemons = deviceDir.appendingPathComponent("data/Containers/Data/InternalDaemon")
        for container in subdirectories(of: daemons) {
            let plist = container
                .appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: plist),
                  let raw = try? PropertyListSerialization.propertyList(
                    from: data, format: nil) as? [String: Any],
                  raw["MCMMetadataIdentifier"] as? String == "com.apple.testmanagerd" else { continue }
            let attachments = container.appendingPathComponent("tmp/Attachments")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: attachments.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return attachments
        }
        return nil
    }

    /// そのデバイスで生きているブリッジの開始時刻。**`earliest == nil` は「時刻が読めない」**で、
    /// 呼び手はそのとき境界を引かずに丸ごと guarded へ倒す
    private struct BridgeStart {
        /// 複数本が同じデバイスに居るときは最も早い開始時刻(それより前だけが確実に無関係)。
        /// 1本でも時刻が読めなければ nil
        var earliest: Date?
        var unknown: Bool
    }

    /// UDID → 生きているブリッジの開始時刻。
    ///
    /// **帰属は `bridge-<port>.device` では引けない** —— あの台帳は実機のブリッジしか書かない
    /// (`BridgeDeviceRecord`)ので、仮想デバイスでは1件も当たらず境界を引けなくなる。
    /// 添付を積むのは XCUITest ランナーで、その宛先はプロセスの起動引数
    /// (`-destination ... id=<UDID>`)にしか無い —— `BridgeLauncher.portsMatching(udid:)` と
    /// 同じ照合を、こちらは pid ごと1回の走査で行う(ps は**1回だけ**。`ps -p <pid列>` は
    /// 壊れた pid が1つ混じると出力ごと空になるので使わない)
    private static func liveBridgeStarts(repoRoot: URL) -> [String: BridgeStart] {
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        var pids: [pid_t] = []
        for url in regularFiles(in: stateDir) where url.pathExtension == "pid" {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("bridge-"), UInt16(name.dropFirst("bridge-".count)) != nil,
                  let pid = pid(ofBridgePort:
                                    UInt16(name.dropFirst("bridge-".count)) ?? 0, stateDir: stateDir),
                  ProcessLiveness.isAlive(pid) else { continue }
            pids.append(pid)
        }
        guard !pids.isEmpty,
              let ps = try? Shell.run(["ps", "-ax", "-o", "pid=,command="]) else { return [:] }
        var udidByPID: [pid_t: String] = [:]
        for line in ps.output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]),
                  pids.contains(pid), let udid = destinationUDID(inCommand: trimmed) else { continue }
            udidByPID[pid] = udid
        }

        var starts: [String: BridgeStart] = [:]
        for (pid, udid) in udidByPID {
            var entry = starts[udid] ?? BridgeStart(earliest: nil, unknown: false)
            guard let start = ProcessLiveness.startTime(pid) else {
                entry.unknown = true
                entry.earliest = nil
                starts[udid] = entry
                continue
            }
            if !entry.unknown {
                entry.earliest = min(entry.earliest ?? start, start)
                starts[udid] = entry
            }
        }
        return starts
    }

    /// `-destination` の `id=<UDID>` を取り出す。**照合するのはブリッジの pid だけ**なので、
    /// 同じ形の引数を持つ無関係なコマンドを拾うことはない
    static func destinationUDID(inCommand command: String) -> String? {
        guard let range = command.range(of: "id=") else { return nil }
        let rest = command[range.upperBound...]
        let udid = rest.prefix { $0.isHexDigit || $0 == "-" }
        // シミュレータは 36 文字のダッシュ 5 分割、実機は 25 文字型や旧 40 桁 hex 型がある
        return udid.count >= 25 ? String(udid) : nil
    }

    private static func pid(ofBridgePort port: UInt16, stateDir: URL) -> pid_t? {
        let url = stateDir.appendingPathComponent("bridge-\(port).pid")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - 削除

    struct ApplyResult: Sendable {
        var deletedSessions = 0
        var freedBytes: Int64 = 0
        /// 消せなかったパスの数(失敗しても続ける。run の成否は変えない)
        var failures = 0
    }

    /// plan の `delete` を消す。**例外を投げない**(呼び出し側の run の成否を変えない。
    /// `RunHookRunner.end` と同じ規律)。`dryRun` では**1バイトも消さず**に一覧だけ返す
    static func apply(_ plan: RetentionSweep.Plan, dryRun: Bool,
                      log: (String) -> Void) -> ApplyResult {
        var result = ApplyResult()
        for session in plan.delete {
            if dryRun {
                log("· would delete \(session.id) (\(bytesText(session.bytes)))")
            } else {
                var failed = false
                for path in session.paths {
                    // 誰かが先に消していたら目的は達成されている(失敗に数えない)
                    guard FileManager.default.fileExists(atPath: path.path) else { continue }
                    do {
                        try FileManager.default.removeItem(at: path)
                    } catch {
                        failed = true
                        result.failures += 1
                        log("⚠️ could not delete \(path.path): \(error.localizedDescription)")
                    }
                }
                guard !failed else { continue }
                log("· deleted \(session.id) (\(bytesText(session.bytes)))")
            }
            result.deletedSessions += 1
            result.freedBytes += session.bytes
        }
        return result
    }

    // MARK: - 中核(`fleetest clean` と `fleetest api clean` はどちらもここだけを呼ぶ)

    struct CategoryReport: Encodable, Sendable {
        let category: String
        let maxBytes: Int64
        /// 発動の線 = 削除後の目標(`RetentionPolicy.sweepLine`)
        let sweepLineBytes: Int64
        /// 掃除前の合計(guarded を含む)
        let usageBytes: Int64
        let plannedSessions: Int
        let deletedSessions: Int
        let freedBytes: Int64
        let keptBytes: Int64
        /// true なら掃除しても上限に収まらない(生きているものが占めている)
        let overCapAfterGuards: Bool
        let failures: Int
    }

    struct CleanReport: Encodable, Sendable {
        let dryRun: Bool
        let freedBytes: Int64
        let categories: [CategoryReport]
    }

    /// - `log`: 削除の一覧(1セッション1行)
    /// - `notice`: 利用者が知るべき事実だけ(guarded だけで線を超えている)。
    ///   **一覧と口を分けてある** —— 同じ口に流して文字列で選り分けると、文言を変えた瞬間に
    ///   通知が黙って消える(一度そうなって、打ち切られたことが画面に出なかった)
    ///
    /// **錠は呼び手が取る**(`RetentionSweepLock`)。ここは消すだけ
    @discardableResult
    static func clean(repoRoot: URL, categories: [Category], policy: RetentionPolicy,
                      dryRun: Bool, activeRunID: String? = nil,
                      log: (String) -> Void, notice: (String) -> Void) -> CleanReport {
        var reports: [CategoryReport] = []
        var freed: Int64 = 0
        for category in Category.allCases where categories.contains(category) {
            let maxBytes = category.maxBytes(policy)
            let line = RetentionPolicy.sweepLine(forCap: maxBytes)
            let collected = sessions(for: category, repoRoot: repoRoot, activeRunID: activeRunID)
            let plan = RetentionSweep.plan(sessions: collected, maxBytes: line)
            let usage = collected.reduce(Int64(0)) { $0 + $1.bytes }
            if plan.overCapAfterGuards {
                notice("⚠️ \(category.rawValue): live sessions alone exceed the sweep line"
                    + " (\(bytesText(usage)) / \(bytesText(line)) = \(RetentionPolicy.sweepTriggerPercent)%"
                    + " of the \(bytesText(maxBytes)) limit) — stop the bridges or the runs that hold"
                    + " them, or raise the limit")
            }
            let applied = apply(plan, dryRun: dryRun, log: log)
            freed += applied.freedBytes
            reports.append(CategoryReport(
                category: category.rawValue, maxBytes: maxBytes, sweepLineBytes: line,
                usageBytes: usage,
                plannedSessions: plan.delete.count, deletedSessions: applied.deletedSessions,
                freedBytes: applied.freedBytes, keptBytes: usage - applied.freedBytes,
                overCapAfterGuards: plan.overCapAfterGuards, failures: applied.failures))
        }
        return CleanReport(dryRun: dryRun, freedBytes: freed, categories: reports)
    }

    /// 系統ごとの現在の使用量(guarded を含む合計)。`api retention` の `usage` 欄
    static func usage(repoRoot: URL) -> [Category: Int64] {
        var result: [Category: Int64] = [:]
        for category in Category.allCases {
            result[category] = sessions(for: category, repoRoot: repoRoot, activeRunID: nil)
                .reduce(Int64(0)) { $0 + $1.bytes }
        }
        return result
    }

    static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    // MARK: - FS ヘルパ

    private static let fileKeys: Set<URLResourceKey> =
        [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]

    /// run.json に完了時刻が無い(= 進行中)か、今終わった run か。
    /// **読めない run.json も guarded** —— 進行中と壊れた記録を区別できないので安全側へ倒す
    private static func runIsGuarded(runDir: URL, activeRunID: String?) -> Bool {
        if let activeRunID, runDir.lastPathComponent == activeRunID { return true }
        guard let meta = RunResultsStore.meta(runDir: runDir) else { return true }
        return meta.finishedAt == nil
    }

    private static func runDirectories(project: TestProject) -> [URL] {
        let runs = RunResultsStore.resultsDir(projectRoot: project.rootURL)
            .appendingPathComponent("runs")
        return subdirectories(of: runs).flatMap { subdirectories(of: $0) }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func subdirectories(of dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
    }

    /// `dir` 直下の通常ファイル(**辿らない・シンボリックリンクの先を見ない**)
    private static func regularFiles(in dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(fileKeys), options: []) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    /// ディレクトリ配下の合計バイトと最新 mtime(ディレクトリが無ければ nil)。
    /// 起点はディレクトリ自身の mtime —— 中身が空の recordings/ も「いつのものか」を持たせる
    private static func measure(directory: URL) -> (bytes: Int64, newest: Date)? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue,
              let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
        else { return nil }
        var bytes: Int64 = 0
        var newest = values.contentModificationDate ?? Date.distantPast
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: Array(fileKeys))
        else { return (bytes, newest) }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: fileKeys) else { continue }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            if let modified = values.contentModificationDate, modified > newest { newest = modified }
        }
        return (bytes, newest)
    }

    /// ファイル群の合計バイトと最新 mtime(1件も読めなければ nil = セッションを作らない)
    private static func measure(files: [URL]) -> (bytes: Int64, newest: Date)? {
        var bytes: Int64 = 0
        var newest = Date.distantPast
        var found = false
        for url in files {
            guard let values = try? url.resourceValues(forKeys: fileKeys) else { continue }
            found = true
            bytes += Int64(values.fileSize ?? 0)
            if let modified = values.contentModificationDate, modified > newest { newest = modified }
        }
        return found ? (bytes, newest) : nil
    }
}
