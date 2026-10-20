// FM が死んだときの原因切り分け用に、ホストのメモリの推移を毎分1点ずつ残す(機械グローバル・リング)。
// 台帳(`FMLiveness`)も履歴(`FMHistory`)も死の「後」しか持たず、Mac 全体の逼迫か modelmanagerd の膨張かを分けられなかった。
//
// 規律:
//  ① **取れなかった値は欄ごと省く**(nil。0 や「その他」に丸めない)。取得は root 不要の手段だけ
//  ② **書き手は FM の常駐プロセス(`fm-serve`)の周期**(`sampleIfDue`)。FM を使っているあいだ生きているのはそのプロセスなので、
//     死の直前の推移を確実に持つ。取得は専用の直列キューで撃ち、呼び手(受け付けループ)を待たせない
//  ③ **置き場は `FMHistory` と同じ判断**(`FMLiveness.writeURL` の隣。nil なら書かない = テストの本番汚染を防ぐ既存の門)。
//     リンクを辿らない(`~/.fleetest` はサンドボックスのシナリオも書ける = `FMHistory.openRegularFile`)
//  ④ **証拠として履歴へ添えるのは死に変わった回だけ**(`FMHistory.recordTransition`)。読み口は `evidence` と `jetsamEvidence`

import Darwin
import Foundation
import Synchronization

public enum FMHostMemory {
    public struct Sample: Codable, Sendable, Equatable {
        /// 採った時刻(epoch 秒)
        public var at: Double
        public var freeBytes: Int64?
        /// 圧縮器が保持しているページ(圧縮後)
        public var compressedBytes: Int64?
        /// 圧縮器に入っているページの圧縮前の量
        public var compressedSourceBytes: Int64?
        public var swapUsedBytes: Int64?
        /// ホストの modelmanagerd の footprint(`top` の mem。別ユーザーのプロセスなので proc_pid_rusage は EPERM)
        public var modelmanagerdFootprintBytes: Int64?
        /// 書き手(fm-serve)が前の点からこの点までに撃った FM の呼び出し(`noteFMCall`)。書き手が数えていなければ nil
        public var fmCalls: FMCalls?

        public init(at: Double, freeBytes: Int64? = nil, compressedBytes: Int64? = nil,
                    compressedSourceBytes: Int64? = nil, swapUsedBytes: Int64? = nil,
                    modelmanagerdFootprintBytes: Int64? = nil, fmCalls: FMCalls? = nil) {
            self.at = at
            self.freeBytes = freeBytes
            self.compressedBytes = compressedBytes
            self.compressedSourceBytes = compressedSourceBytes
            self.swapUsedBytes = swapUsedBytes
            self.modelmanagerdFootprintBytes = modelmanagerdFootprintBytes
            self.fmCalls = fmCalls
        }
    }

    /// fm-serve が撃った FM の呼び出しの種類。暖機と実要求を分けて数える(modelmanagerd の伸びがどちらに比例するかを見る)
    public enum FMCallKind: Sendable { case keepWarm, prewarm, transcribe, screen, probe }

    /// 種類ごとの回数。**数えるのは fm-serve が FM を撃った回**(撃ち直しも1回。応答の成否は問わない)
    public struct FMCalls: Codable, Sendable, Equatable {
        public var keepWarm = 0
        public var prewarm = 0
        public var transcribe = 0
        public var screen = 0
        public var probe = 0

        public init(keepWarm: Int = 0, prewarm: Int = 0, transcribe: Int = 0, screen: Int = 0, probe: Int = 0) {
            self.keepWarm = keepWarm
            self.prewarm = prewarm
            self.transcribe = transcribe
            self.screen = screen
            self.probe = probe
        }
    }

    // MARK: - 定数

    /// 採る間隔(秒)。FM 死活プローブの周期(`FMLivenessProbe.probeIntervalSeconds` = 60)と同じ刻み。
    /// 取得中(`top` が約1秒)に次の周期が来たらその周期は飛ばす(重ねない)
    static let sampleIntervalSeconds: TimeInterval = 60
    /// リングの保持(秒)= 24 時間。実例は Mac の起動から約6時間で modelmanagerd が殺された回と、約21時間で FM が死んだ回(maintainer-notes §84.5)なので、それを覆う。
    /// 1440 行 × 約 200 バイト ≈ 300KB。超えた行は次の書き込みのついでに捨てる
    static let ringMaxAgeSeconds: TimeInterval = 24 * 3600
    /// 証拠に全点を載せる直近の窓(秒)= 30 分。死の検出は最大で数分遅れる(実例は jetsam から died の記録まで 18 秒 = §84.5)ので、
    /// 直前の傾きを毎分で見る窓。これより古い側は枠ごとに間引く
    static let evidenceRecentSeconds: TimeInterval = 30 * 60
    /// 古い側の間引きの枠(秒)= 1 時間。膨張の傾きを見るのに十分で、古い側の証拠の行を ≤ 23(24 時間 - 窓)に抑える
    static let evidenceBucketSeconds: TimeInterval = 3600
    /// JetsamEvent を拾う窓(秒)= 30 分(`evidenceRecentSeconds` と同じ理由)。外れた報告は読まない
    static let jetsamWindowSeconds: TimeInterval = 30 * 60
    /// 読む JetsamEvent の最大件数(新しい順)。尽きたら古い報告は載せない
    static let jetsamMaxFiles = 2
    /// 1つの報告から載せる「殺された」行の最大数。尽きたら残りは載せない(先頭から)
    static let jetsamMaxKilledLines = 5
    /// `top` の期限(秒)。実測は約1秒、その10倍。尽きたら modelmanagerd の欄だけ省いて残りは書く
    static let topTimeoutSeconds: Double = 10

    static let ringFileName = "fm-host-memory.ndjson"
    static let lockFileName = "fm-host-memory.lock"
    static let modelmanagerdPath = "/usr/libexec/modelmanagerd"
    static let jetsamDirectories = [
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports/Retired"),
    ]

    // MARK: - 取る

    public static func capture(now: Date = Date()) -> Sample {
        var sample = Sample(at: now.timeIntervalSince1970)
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), $0, &count)
            }
        }
        if status == KERN_SUCCESS, let page = pageSize() {
            sample.freeBytes = Int64(stats.free_count) * page
            sample.compressedBytes = Int64(stats.compressor_page_count) * page
            sample.compressedSourceBytes = Int64(stats.total_uncompressed_pages_in_compressor) * page
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            sample.swapUsedBytes = Int64(swap.xsu_used)
        }
        if let pid = hostModelmanagerdPID(),
           let output = try? Shell.run(["/usr/bin/top", "-l", "1", "-pid", String(pid), "-stats", "mem"],
                                       timeout: topTimeoutSeconds).outputIfSucceeded {
            sample.modelmanagerdFootprintBytes = parseTopMemory(output)
        }
        return sample
    }

    /// vm_kernel_page_size と同じ値(C のグローバル変数は Swift 6 の並行性検査に通らないので sysctl で読む)
    private static func pageSize() -> Int64? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.pagesize", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int64(value)
    }

    /// ホストの modelmanagerd。パスが完全一致するものだけ(Simulator 内の同名プロセスはパスが違う)
    private static func hostModelmanagerdPID() -> pid_t? {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path == modelmanagerdPath { return pid }
        }
        return nil
    }

    /// `top -l 1 -pid <pid> -stats mem` の出力。最終の非空行が値("7249K"・"15M+"・"1.5G"。K/M/G は 1024 進)。読めなければ nil
    static func parseTopMemory(_ output: String) -> Int64? {
        guard var token = output.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else { return nil }
        while let last = token.last, last == "+" || last == "-" { token.removeLast() }
        var multiplier = 1.0
        if let unit = token.last, unit.isLetter {
            switch unit {
            case "B": multiplier = 1
            case "K": multiplier = 1024
            case "M": multiplier = 1024 * 1024
            case "G": multiplier = 1024 * 1024 * 1024
            default: return nil
            }
            token.removeLast()
        }
        guard let number = Double(token), number >= 0, number.isFinite else { return nil }
        return Int64(number * multiplier)
    }

    // MARK: - リング

    static var ringURL: URL? {
        FMLiveness.writeURL?.deletingLastPathComponent().appendingPathComponent(ringFileName)
    }

    /// 1点を足す。flock の内側で全体を読み、`ringMaxAgeSeconds` より古い行と読めない行を捨て、一時ファイル → rename で書き直す
    static func append(_ sample: Sample, now: Date) {
        guard let url = ringURL else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let lockFD = FMHistory.openLocked(dir.appendingPathComponent(lockFileName)) else { return }
        defer { close(lockFD) }
        guard let handle = FMHistory.openRegularFile(url) else { return }
        defer { try? handle.close() }
        let existing = (try? handle.readToEnd()) ?? Data()
        let cutoff = now.timeIntervalSince1970 - ringMaxAgeSeconds
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var out = Data()
        for line in existing.split(separator: 0x0A) {
            guard let old = try? JSONDecoder().decode(Sample.self, from: Data(line)), old.at >= cutoff else { continue }
            out.append(line)
            out.append(0x0A)
        }
        guard let added = try? encoder.encode(sample) else { return }
        out.append(added)
        out.append(0x0A)
        let tmp = dir.appendingPathComponent(
            ".fm-host-memory.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp")
        guard (try? out.write(to: tmp)) != nil else { return }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }

    /// 保持期間内の点を時刻順で。読むのは書き込みの門に関係なく `FMLiveness.directory`(`FMHistory.recent` と同じ)
    public static func recent(now: Date = Date()) -> [Sample] {
        guard let data = try? Data(contentsOf: FMLiveness.directory.appendingPathComponent(ringFileName)) else { return [] }
        let cutoff = now.timeIntervalSince1970 - ringMaxAgeSeconds
        return data.split(separator: 0x0A)
            .compactMap { try? JSONDecoder().decode(Sample.self, from: Data($0)) }
            .filter { $0.at >= cutoff }
            .sorted { $0.at < $1.at }
    }

    /// 証拠に載せる点。直近 `evidenceRecentSeconds` は全部、それより古く保持内は枠ごとの最初の1点
    static func selectForEvidence(_ samples: [Sample], now: Double) -> [Sample] {
        var recent: [Sample] = []
        var firstInBucket: [Int64: Sample] = [:]
        for sample in samples {
            let age = now - sample.at
            if age > ringMaxAgeSeconds { continue }
            if age <= evidenceRecentSeconds {
                recent.append(sample)
                continue
            }
            let bucket = Int64((sample.at / evidenceBucketSeconds).rounded(.down))
            if let kept = firstInBucket[bucket], kept.at <= sample.at { continue }
            firstInBucket[bucket] = sample
        }
        return (recent + firstInBucket.values).sorted { $0.at < $1.at }
    }

    /// 履歴に添える推移。空なら nil
    static func memoryEvidence(now: Date = Date()) -> [String]? {
        let lines = selectForEvidence(recent(now: now), now: now.timeIntervalSince1970).map { describe($0, now: now) }
        return lines.isEmpty ? nil : lines
    }

    private static func gib(_ bytes: Int64) -> String { String(format: "%.1fGiB", Double(bytes) / 1_073_741_824) }
    private static func mib(_ bytes: Int64) -> String { String(format: "%.1fMiB", Double(bytes) / 1_048_576) }

    /// 1点の1行。nil の欄は出さない。時刻はローカル(今日でなければ日付を前に)
    static func describe(_ sample: Sample, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: sample.at)
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
        var parts = [formatter.string(from: date)]
        if let free = sample.freeBytes { parts.append("free=\(gib(free))") }
        if let compressed = sample.compressedBytes {
            parts.append("compressed=\(gib(compressed))" + (sample.compressedSourceBytes.map { " of \(gib($0))" } ?? ""))
        } else if let source = sample.compressedSourceBytes {
            parts.append("compressed-source=\(gib(source))")
        }
        if let swap = sample.swapUsedBytes { parts.append("swap=\(gib(swap))") }
        if let footprint = sample.modelmanagerdFootprintBytes { parts.append("modelmanagerd=\(mib(footprint))") }
        if let calls = sample.fmCalls {
            parts.append("fm-calls keepWarm=\(calls.keepWarm) prewarm=\(calls.prewarm) transcribe=\(calls.transcribe)"
                         + " screen=\(calls.screen) probe=\(calls.probe)")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - サンプラ

    private struct SamplerState {
        var lastStart: Date?
        var inFlight = false
    }
    private static let samplerState = Mutex(SamplerState())
    private static let samplerQueue = DispatchQueue(label: "fleetest.fm-host-memory.sampler")
    /// 取得口と書き込み口。テストは差し替える(`top` を撃たず本番の置き場を使わない)
    static let captureHook = Mutex<@Sendable (Date) -> Sample>({ capture(now: $0) })
    static let appendHook = Mutex<@Sendable (Sample, Date) -> Void>({ append($0, now: $1) })

    /// 前回の開始から `sampleIntervalSeconds` 経っていて取得中でなければ、専用キューで取得と書き込みを撃って**すぐ戻る**。
    /// 呼び手は fm-serve の受け付けループ(`top` が約1秒かかるので待たせない)
    public static func sampleIfDue(now: Date = Date()) {
        let due = samplerState.withLock { state -> Bool in
            if state.inFlight { return false }
            if let last = state.lastStart, now.timeIntervalSince(last) < sampleIntervalSeconds { return false }
            state.lastStart = now
            state.inFlight = true
            return true
        }
        guard due else { return }
        // 撃った点にだけ回数を渡して零に戻す = 飛ばした周期の回数は次の点へ繰り越す(取りこぼさない)
        let calls = callCounts.withLock { counts -> FMCalls in
            let taken = counts
            counts = FMCalls()
            return taken
        }
        let capture = captureHook.withLock { $0 }
        let append = appendHook.withLock { $0 }
        samplerQueue.async {
            var sample = capture(now)
            sample.fmCalls = calls
            append(sample, now)
            samplerState.withLock { $0.inFlight = false }
        }
    }

    private static let callCounts = Mutex(FMCalls())

    /// fm-serve が FM を撃つ直前に呼ぶ。次の点(`sampleIfDue`)まで溜める
    public static func noteFMCall(_ kind: FMCallKind) {
        callCounts.withLock { counts in
            switch kind {
            case .keepWarm: counts.keepWarm += 1
            case .prewarm: counts.prewarm += 1
            case .transcribe: counts.transcribe += 1
            case .screen: counts.screen += 1
            case .probe: counts.probe += 1
            }
        }
    }

    static func waitForPendingSample() { samplerQueue.sync {} }

    /// テスト用。周期の状態を捨てる
    static func resetSamplerState() {
        samplerState.withLock { $0 = SamplerState() }
        callCounts.withLock { $0 = FMCalls() }
    }

    // MARK: - JetsamEvent

    /// 報告1件の要約行と「殺された」行。1行目 = ヘッダ JSON(timestamp)、2行目以降 = 本体 JSON。読めなければ nil
    static func jetsamLines(fileName: String, contents: String) -> [String]? {
        guard let newline = contents.firstIndex(of: "\n"),
              let header = json(String(contents[..<newline])),
              let body = json(String(contents[contents.index(after: newline)...])) else { return nil }
        let page = num(body["pageSize"]) ?? 16384
        var summary = [fileName]
        if let stamp = header["timestamp"] as? String { summary.append(String(stamp.prefix(19))) }
        if let status = body["memoryStatus"] as? [String: Any] {
            if let free = num((status["memoryPages"] as? [String: Any])?["free"]) { summary.append("free=\(gib(free * page))") }
            if let compressed = num(status["compressorSize"]) {
                summary.append("compressed=\(gib(compressed * page))"
                               + (num(status["uncompressed"]).map { " of \(gib($0 * page))" } ?? ""))
            }
        }
        if let largest = body["largestProcess"] as? String { summary.append("largest=\(largest)") }
        var lines = [summary.joined(separator: " ")]
        for process in (body["processes"] as? [[String: Any]] ?? []) {
            guard lines.count <= jetsamMaxKilledLines, let reason = process["reason"] as? String else { continue }
            var parts = "killed \(process["name"] as? String ?? "?")"
            if let pid = num(process["pid"]) { parts += "[\(pid)]" }
            parts += " reason=\(reason)"
            if let rpages = num(process["rpages"]) { parts += " resident=\(mib(rpages * page))" }
            if let peak = num(process["lifetimeMax"]) { parts += " lifetimeMax=\(mib(peak * page))" }
            lines.append(parts)
        }
        return lines
    }

    private static func json(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private static func num(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

    /// 直近 `jetsamWindowSeconds` の JetsamEvent(新しい順に最大 `jetsamMaxFiles` 件)の行。
    /// 台帳の置き場を差し替えている(テスト)間は撃たない(`FMHistory.aneLogEvidence` と同じ門)
    static func jetsamEvidence(now: Date = Date(), directories: [URL] = jetsamDirectories) -> [String]? {
        if let override = ProcessInfo.processInfo.environment[FMLiveness.directoryOverrideKey], !override.isEmpty { return nil }
        var found: [(url: URL, modified: Date)] = []
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasPrefix("JetsamEvent-") && name.hasSuffix(".ips") {
                let url = directory.appendingPathComponent(name)
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, now.timeIntervalSince(modified) <= jetsamWindowSeconds else { continue }
                found.append((url, modified))
            }
        }
        var lines: [String] = []
        for file in found.sorted(by: { $0.modified > $1.modified }).prefix(jetsamMaxFiles) {
            guard let contents = try? String(contentsOf: file.url, encoding: .utf8),
                  let parsed = jetsamLines(fileName: file.url.lastPathComponent, contents: contents) else { continue }
            lines += parsed.map { FMHistory.truncated($0, maxBytes: FMHistory.errorLimit) }
        }
        return lines.isEmpty ? nil : lines
    }
}
