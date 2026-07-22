// HostMetricsSampler.swift
// ホストMac負荷(CPU/GPU/メモリ)のサンプラー群+NDJSON行の型(HostMetricsSample)+
// run 単位の 1Hz 記録器(HostMetricsRecorder)。
// NDJSON の hostMetrics 行形(フィールド一覧)は vscode-ftester/src/monitorProcessManager.ts の
// isHostMetricsEvent/HostMetricsRawEvent と Sources/ftester/ApiHostMetricsSummaryCommand.swift の
// パーサーが読む契約。フィールドを増減したら両方も更新すること(一覧はここに1箇所、重複させない)。

import Foundation
import IOKit

// MARK: - 履歴ログ(NDJSON 追記)

/// hostMetrics の各行を NDJSON ファイルへ追記する(呼び出し側が単一スレッド/直列で呼ぶ前提。
/// 排他は不要)。O_APPEND での write(2) は1回のシステムコールなら他プロセスの追記と混じらない
/// (POSIX保証。1行 ~150B は PIPE_BUF 未満)ため、複数プロセスが同一パスへ追記しても行単位ではアトミック。
/// 上限到達時のみ flock でローテを排他する。
public final class HostMetricsLog {
    private static let capBytes: Int64 = 16 * 1024 * 1024

    private let path: String
    private var fd: Int32
    private var bytesWritten: Int64
    private var loggedFailure = false
    private let logFailure: (String) -> Void

    /// 親ディレクトリ作成・open のいずれかに失敗したら nil を返す(呼び出し側は logger=nil として
    /// 続行する契約。ここでは絶対にクラッシュさせない)
    public init?(path: String, logFailure: @escaping (String) -> Void) {
        self.path = path
        self.logFailure = logFailure

        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
        let opened = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard opened >= 0 else {
            logFailure("ログファイルを開けません: \(path)(errno \(errno))。ログ記録は無効化します")
            return nil
        }
        self.fd = opened

        var st = stat()
        self.bytesWritten = fstat(opened, &st) == 0 ? Int64(st.st_size) : 0
    }

    public func append(_ line: String) {
        let data = Array((line + "\n").utf8)
        let written = data.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        guard written >= 0 else {
            logIfNeeded("ログファイルへの書き込みに失敗しました: \(path)(errno \(errno))")
            return
        }
        bytesWritten += Int64(written)
        if bytesWritten >= Self.capBytes {
            rotate()
        }
    }

    /// 上限到達時のみ呼ばれる。複数プロセスの同時ローテ競合を flock で防ぐ。
    /// ロック区間は必ず LOCK_UN で抜ける(失敗しても継続できるよう既存 fd は極力温存する)。
    private func rotate() {
        guard flock(fd, LOCK_EX) == 0 else {
            logIfNeeded("ログローテのロックに失敗しました: \(path)(errno \(errno))")
            return
        }
        defer { flock(fd, LOCK_UN) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            logIfNeeded("ログローテ前の fstat に失敗しました: \(path)(errno \(errno))")
            return
        }
        guard Int64(st.st_size) >= Self.capBytes else {
            // 他プロセスが先にローテ済み
            bytesWritten = Int64(st.st_size)
            return
        }

        close(fd)
        guard rename(path, path + ".1") == 0 else {
            logIfNeeded("ログローテの rename に失敗しました: \(path)(errno \(errno))")
            let reopened = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if reopened >= 0 { fd = reopened }
            return
        }
        let reopened = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard reopened >= 0 else {
            logIfNeeded("ログローテ後の再オープンに失敗しました: \(path)(errno \(errno))")
            return
        }
        fd = reopened
        bytesWritten = 0
    }

    private func logIfNeeded(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        logFailure(message)
    }
}

// MARK: - CPU サンプラー

/// host_processor_info(PROCESSOR_CPU_LOAD_INFO) で全コア合計の累積 tick を取得し、
/// 前回サンプルとのデルタから busy/(busy+idle) を算出する。初回はデルタが無いため nil。
public final class CPUSampler {
    /// 1コア分の累積 tick(各カウンタは 32bit・ラップし得る)。
    public struct CoreTicks { let user: UInt32; let system: UInt32; let nice: UInt32; let idle: UInt32 }
    private var previous: [CoreTicks]?
    private var loggedFailure = false
    private let logFailure: (String) -> Void

    public init(logFailure: @escaping (String) -> Void) {
        self.logFailure = logFailure
    }

    public func sample() -> Double? {
        guard let current = Self.ticks(log: logIfNeeded) else { return nil }
        defer { previous = current }
        // コア数が変わった直後(サンプラー跨ぎ等)はデルタ不能なのでスキップ。
        guard let previous, previous.count == current.count else { return nil }
        // デルタは**コアごとに 32bit 単位で** &- する(ラップ跨ぎでも正しい小さな正のデルタになる)。
        // コア横断で合算してから引くと、1コアのカウンタが 2^32 をまたいだ tick で総和が減り
        // UInt64 の underflow で巨大値=偽の ~100% が出る(長時間稼働ホストの実害)。
        var busy: UInt64 = 0, idle: UInt64 = 0
        for (p, c) in zip(previous, current) {
            busy += UInt64(c.user &- p.user) + UInt64(c.system &- p.system) + UInt64(c.nice &- p.nice)
            idle += UInt64(c.idle &- p.idle)
        }
        let total = busy + idle
        guard total > 0 else { return nil }
        return min(1.0, max(0.0, Double(busy) / Double(total)))
    }

    /// 全コア分の累積 tick(user/system/idle/nice)をコア別に返す。
    /// 返却された info 配列は vm_deallocate で解放する(呼び出し側の責務)
    private static func ticks(log: (String) -> Void) -> [CoreTicks]? {
        var processorCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let infoArray else {
            log("host_processor_info に失敗しました(kern_return_t \(result))。CPU負荷は取得できません")
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        // tick カウンタはカーネル側では符号なし32bitだが integer_t(Int32)として返るため、
        // 長時間稼働で 2^31 を超えると負値に見える。UInt64(負値) は実行時トラップするので
        // 必ず UInt32(bitPattern:) を経由する(デルタ計算も 32bit 単位。sample() 参照)。
        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(processorCount))
        for core in 0..<Int(processorCount) {
            let offset = Int(CPU_STATE_MAX) * core
            cores.append(CoreTicks(
                user: UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_SYSTEM)]),
                nice: UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_NICE)]),
                idle: UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_IDLE)])))
        }
        return cores
    }

    private func logIfNeeded(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        logFailure(message)
    }
}

// MARK: - GPU サンプラー

/// IOAccelerator にマッチする全サービスの "PerformanceStatistics" 辞書から
/// "Device Utilization %"(0..100 の整数)を読み、最大値を採用する(キーが無ければ nil)
public final class GPUSampler {
    private var loggedFailure = false
    private let logFailure: (String) -> Void

    public init(logFailure: @escaping (String) -> Void) {
        self.logFailure = logFailure
    }

    public func sample() -> Double? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator") else {
            logIfNeeded("IOServiceMatching(IOAccelerator) に失敗しました。GPU負荷は取得できません")
            return nil
        }
        let matchResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard matchResult == KERN_SUCCESS else {
            logIfNeeded(
                "IOServiceGetMatchingServices(IOAccelerator) に失敗しました" +
                "(kern_return_t \(matchResult))。GPU負荷は取得できません")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var maxUtilization: Int?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
               let utilization = stats["Device Utilization %"] as? Int {
                maxUtilization = max(maxUtilization ?? 0, utilization)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        guard let maxUtilization else { return nil }
        return min(1.0, max(0.0, Double(maxUtilization) / 100.0))
    }

    private func logIfNeeded(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        logFailure(message)
    }
}

// MARK: - メモリサンプラー

/// host_statistics64(HOST_VM_INFO64) の active+wire+compressor ページ数 × ページサイズを
/// 使用中メモリとみなす。合計は ProcessInfo.physicalMemory
public final class MemorySampler {
    public struct Result {
        public let used: Int
        public let total: Int
    }

    private var loggedFailure = false
    private let logFailure: (String) -> Void

    public init(logFailure: @escaping (String) -> Void) {
        self.logFailure = logFailure
    }

    public func sample() -> Result? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            logIfNeeded("host_page_size の取得に失敗しました。メモリ使用量は取得できません")
            return nil
        }
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            logIfNeeded(
                "host_statistics64(HOST_VM_INFO64) に失敗しました(kern_return_t \(result))。" +
                "メモリ使用量は取得できません")
            return nil
        }
        let usedPages = UInt64(info.active_count) + UInt64(info.wire_count)
            + UInt64(info.compressor_page_count)
        let used = usedPages * UInt64(pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        return Result(used: Int(used), total: Int(total))
    }

    private func logIfNeeded(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        logFailure(message)
    }
}

// MARK: - JSON サンプル(NDJSON 1行)

/// hostMetrics サンプル1件。省略可能なフィールドは JSON 上で null を明示する
/// (自動合成の Encodable は Optional を encodeIfPresent で「キーごと省略」してしまい null に
/// ならないため、手書き encode(to:) にする)
public struct HostMetricsSample: Encodable {
    let kind = "hostMetrics"
    public let ts: Double
    public let cpu: Double?
    public let gpu: Double?
    public let memUsedBytes: Int?
    public let memTotalBytes: Int?

    public init(ts: Double, cpu: Double?, gpu: Double?,
                memUsedBytes: Int?, memTotalBytes: Int?) {
        self.ts = ts
        self.cpu = cpu
        self.gpu = gpu
        self.memUsedBytes = memUsedBytes
        self.memTotalBytes = memTotalBytes
    }

    private enum CodingKeys: String, CodingKey {
        case kind, ts, cpu, gpu, memUsedBytes, memTotalBytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ts, forKey: .ts)
        try container.encode(cpu, forKey: .cpu)
        try container.encode(gpu, forKey: .gpu)
        try container.encode(memUsedBytes, forKey: .memUsedBytes)
        try container.encode(memTotalBytes, forKey: .memTotalBytes)
    }

    /// JSONEncoder([.sortedKeys, .withoutEscapingSlashes]) で1行の NDJSON にする
    /// (常駐 CLI 側の同等ロジックと同じ設定。フィールド順は sortedKeys で決まるため
    /// CodingKeys の宣言順には依存しない)
    public func encodedLine() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line
    }
}

// MARK: - run 単位の 1Hz 記録器

/// stdin 監視や DispatchSourceSignal を持たない常駐 Thread の停止フラグ
/// (Sources/ftester/ApiHostMetricsCommand.swift の StopFlag と同型。private のためファイル間で
/// 共有できず複製)
private final class StopGate: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }
}

/// RunRecorder が 1 run のライフサイクルで使う、ホスト負荷の背景 1Hz サンプラー。
/// 同期コンテキスト(RunRecorder は async ではない)から確実に stop() できるよう GCD/Task ではなく
/// 素の Thread + StopGate + DispatchSemaphore で実装する(async ランタイムに依存しない)。
public final class HostMetricsRecorder: @unchecked Sendable {
    private let logger: HostMetricsLog?
    /// HostMetricsLog が開けた(=書き込み先がある)ときだけ true。false ならスレッドは
    /// そもそも起動していない(stop() のセマフォ待ちを無意味に行わないための判定に使う)
    private let hasThread: Bool
    private let stopFlag = StopGate()
    private let exitSemaphore = DispatchSemaphore(value: 0)

    /// HostMetricsLog を開けなければ(親ディレクトリ不可・open失敗等)サンプリングスレッドごと
    /// 起動しない生涯 no-op にする — 書き込み先が無い状態でサンプリングし続けても
    /// CPU/dlopen コストの無駄でしかないため(--log 未指定時の既存契約と同じ「クラッシュさせない」方針)
    public init(outputURL: URL, interval: TimeInterval = 1.0, logFailure: @escaping (String) -> Void) {
        let openedLogger = HostMetricsLog(path: outputURL.path, logFailure: logFailure)
        self.logger = openedLogger
        self.hasThread = openedLogger != nil
        guard let logger = openedLogger else { return }

        let cpuSampler = CPUSampler(logFailure: logFailure)
        let gpuSampler = GPUSampler(logFailure: logFailure)
        let memorySampler = MemorySampler(logFailure: logFailure)
        let stopFlag = self.stopFlag
        let exitSemaphore = self.exitSemaphore

        let thread = Thread {
            // 初回は差分が取れないサンプラー(CPU)のための捨てサンプル
            // (常駐 CLI の run() 冒頭と同じ理由。最初の interval 経過後の1行目から値を出せる)
            _ = cpuSampler.sample()

            while !stopFlag.isSet {
                var remaining = interval
                while remaining > 0, !stopFlag.isSet {
                    Thread.sleep(forTimeInterval: 0.1)
                    remaining -= 0.1
                }
                guard !stopFlag.isSet else { break }

                let cpu = cpuSampler.sample()
                let gpu = gpuSampler.sample()
                let mem = memorySampler.sample()
                let sample = HostMetricsSample(
                    ts: Date().timeIntervalSince1970, cpu: cpu, gpu: gpu,
                    memUsedBytes: mem?.used, memTotalBytes: mem?.total)
                if let line = sample.encodedLine() {
                    logger.append(line)
                }
            }
            exitSemaphore.signal()
        }
        thread.name = "ftester-host-metrics-recorder"
        thread.start()
    }

    /// 2 回目以降の呼び出しは no-op(セマフォを二重に待つと永久ブロックするため)。
    /// HostMetricsLog が開けず未起動(hasThread=false)のときはフラグを立てるだけで即返す。
    public func stop() {
        let alreadyRequested = stopFlag.isSet
        stopFlag.set()
        guard hasThread, !alreadyRequested else { return }
        _ = exitSemaphore.wait(timeout: .now() + 2.0)
    }
}
