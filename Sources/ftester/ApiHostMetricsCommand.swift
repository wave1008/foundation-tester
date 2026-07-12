// VSCode拡張のデバイスモニターパネル向け常駐CLI(ftester api host-metrics)。ホストMacの
// CPU/GPU/ANE負荷とメモリ使用量を一定間隔でサンプリングし NDJSON(hostMetrics)で stdout に
// 流す(このイベントのみ。診断は stderr)。テストプロジェクトに依存しないため --project は無い。
// 終了条件: stdin EOF または SIGTERM/SIGINT。各サンプラーの実装方針・実測知見は各クラスの
// doc コメント参照(失敗時はクラッシュさせず該当フィールドを null にし、stderr ログは
// サンプラー毎に初回1回だけ)。

import ArgumentParser
import Foundation
import IOKit

struct ApiHostMetricsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host-metrics",
        abstract: "ホストMacのCPU/GPU/ANE負荷とメモリ使用量を一定間隔でサンプリングし"
            + "NDJSON(hostMetrics)でstdoutに流し続ける(診断は stderr のみ。"
            + "stdin の EOF または SIGTERM/SIGINT で終了)")

    @Option(help: "サンプリング間隔(秒。既定 1.0)")
    var interval: Double = 1.0

    func run() async throws {
        // ストリーミング読み取りが前提のため常に行バッファにする(ApiMonitorCommand.swift と同じ理由)
        setvbuf(stdout, nil, _IOLBF, 0)
        ResidentProcessGuard.startOrphanWatchdog(logLabel: "host-metrics")

        let stop = StopFlag()
        startStdinWatcher(stop: stop)
        // ループを抜けるまでシグナルソースを保持する(解放されるとハンドラが外れる)
        let signalSources = installSignalHandlers(stop: stop)
        defer { for source in signalSources { source.cancel() } }

        let cpuSampler = CPUSampler(logFailure: logStderr)
        let gpuSampler = GPUSampler(logFailure: logStderr)
        let aneSampler = ANESampler(logFailure: logStderr)
        let memorySampler = MemorySampler(logFailure: logStderr)

        // 初回は差分が取れないサンプラー(CPU/ANE)のための捨てサンプル。これにより
        // 最初の interval 経過後に出す1行目から値を出せる
        _ = cpuSampler.sample()
        _ = aneSampler.sample()

        while !stop.isSet {
            await Self.sleepInterruptible(seconds: interval, stop: stop)
            guard !stop.isSet else { break }

            let cpu = cpuSampler.sample()
            let gpu = gpuSampler.sample()
            let ane = aneSampler.sample()
            let mem = memorySampler.sample()

            emitLine(ApiHostMetricsEvent(
                ts: Date().timeIntervalSince1970,
                // aneWatts: 常に null(理由は ANESampler のdocコメント参照)
                cpu: cpu, gpu: gpu, ane: ane, aneWatts: nil,
                memUsedBytes: mem?.used, memTotalBytes: mem?.total))
        }
    }

    /// SIGTERM/SIGINT/EOF を最大 0.1 秒粒度で検知しながら interval 秒待つ
    /// (待ち時間いっぱい固まって終了が遅れないようにするため。ApiMonitorCommand.swift と同じ実装)
    private static func sleepInterruptible(seconds: Double, stop: StopFlag) async {
        var remaining = seconds
        while remaining > 0, !stop.isSet {
            try? await Task.sleep(nanoseconds: 100_000_000)
            remaining -= 0.1
        }
    }

    // MARK: - 終了検知(stdin / シグナル)

    /// stdin の EOF(親プロセスがパイプを閉じた)を検知して停止フラグを立てる。行の内容は
    /// 使わない(monitor と異なり制御コマンドを受け付けない)。readLine はブロッキングなので
    /// メインループとは別スレッドで読み続ける(ApiMonitorCommand.swift の stdin 監視と同じ方式)
    private func startStdinWatcher(stop: StopFlag) {
        let thread = Thread {
            while readLine(strippingNewline: true) != nil {}
            stop.set()
            ResidentProcessGuard.scheduleForcedExit(logLabel: "host-metrics")
        }
        thread.name = "ftester-api-host-metrics-stdin"
        thread.start()
    }

    /// SIGTERM/SIGINT を捕捉して停止フラグを立てる(既定の即時終了を上書きし、ループの
    /// 区切りでクリーンに終了できるようにする)。戻り値はループを抜けるまで呼び出し側が
    /// 保持すること(DispatchSourceSignal は解放されるとハンドラが外れる。
    /// ApiMonitorCommand.swift と同じ実装)
    private func installSignalHandlers(stop: StopFlag) -> [DispatchSourceSignal] {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "ftester-api-host-metrics-signal")
        return [SIGTERM, SIGINT].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                stop.set()
                ResidentProcessGuard.scheduleForcedExit(logLabel: "host-metrics")
            }
            source.resume()
            return source
        }
    }

    private func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data(("[host-metrics] " + message + "\n").utf8))
    }
}

/// stdin 読み取りスレッド・シグナルハンドラ・メインループの間で共有する停止フラグ
/// (ApiMonitorCommand.swift の StopFlag と同じ実装。private のためファイル間で共有できず複製)
private final class StopFlag: @unchecked Sendable {
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

// MARK: - CPU サンプラー

/// host_processor_info(PROCESSOR_CPU_LOAD_INFO) で全コア合計の累積 tick を取得し、
/// 前回サンプルとのデルタから busy/(busy+idle) を算出する。初回はデルタが無いため nil。
private final class CPUSampler {
    private var previous: (user: UInt64, system: UInt64, nice: UInt64, idle: UInt64)?
    private var loggedFailure = false
    private let logFailure: (String) -> Void

    init(logFailure: @escaping (String) -> Void) {
        self.logFailure = logFailure
    }

    func sample() -> Double? {
        guard let current = Self.ticks(log: logIfNeeded) else { return nil }
        defer { previous = current }
        guard let previous else { return nil }
        let busy = Double((current.user &- previous.user) &+ (current.system &- previous.system)
                          &+ (current.nice &- previous.nice))
        let idle = Double(current.idle &- previous.idle)
        let total = busy + idle
        guard total > 0 else { return nil }
        return min(1.0, max(0.0, busy / total))
    }

    /// 全コア分の累積 tick(user/system/idle/nice)を合算して返す。
    /// 返却された info 配列は vm_deallocate で解放する(呼び出し側の責務)
    private static func ticks(
        log: (String) -> Void
    ) -> (user: UInt64, system: UInt64, nice: UInt64, idle: UInt64)? {
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
        // 必ず UInt32(bitPattern:) を経由する
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for core in 0..<Int(processorCount) {
            let offset = Int(CPU_STATE_MAX) * core
            user += UInt64(UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_USER)]))
            system += UInt64(UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_IDLE)]))
            nice += UInt64(UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_NICE)]))
        }
        return (user, system, nice, idle)
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
private final class GPUSampler {
    private var loggedFailure = false
    private let logFailure: (String) -> Void

    init(logFailure: @escaping (String) -> Void) {
        self.logFailure = logFailure
    }

    func sample() -> Double? {
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

// MARK: - ANE サンプラー(IOReport 私有API)

/// ANE(Apple Neural Engine)負荷を IOReport 私有API 経由で取得する。libIOReport.dylib を
/// dlopen し、"SoC Stats" グループのチャネルをサブスクライブして tick 毎に
/// IOReportCreateSamplesDelta で区間デルタを取り、state 形式の residency チャネル
/// SOCn_ANE_Fn(単位 24Mticks)の ACT residency 合算 / 総 ticks(ACT+INACT)を
/// 負荷率(0..1)として返す。
/// "Energy Model" グループの ANE0 エネルギーチャネルは macOS 27 beta では常に 0 を返す
/// (ANE 割り込み・DMA が活発でも計上されない実測)ため使わない。
/// dlopen/dlsym や IOReportCopyChannelsInGroup/IOReportCreateSubscription のいずれかが
/// 失敗したら以降ずっと nil を返す(初期化失敗は起動直後に stderr へ1回だけログし、
/// クラッシュはさせない)。
private final class ANESampler {
    /// 対象チャネル名のパターン。SOC0_ANE_F1 / SOC0_ANE_F2 のような周波数段別チャネルだけを
    /// 拾い、SOC0_F1_ANE_F2 のような複合名は除外する
    private static let channelNamePattern = #"^SOC\d+_ANE_F\d+$"#
    /// IOReportChannelGetFormat が state 形式(residency 配列を持つ)チャネルに返す値
    private static let stateFormat: UInt8 = 2

    private let api: IOReportAPI?
    private let subscription: UnsafeMutableRawPointer?
    private let subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var loggedFailure = false
    private let logFailure: (String) -> Void

    init(logFailure: @escaping (String) -> Void) {
        self.logFailure = logFailure

        guard let api = IOReportAPI.load() else {
            self.api = nil
            self.subscription = nil
            self.subscribedChannels = nil
            logFailure(
                "IOReport 私有API の読み込みに失敗しました(libIOReport.dylib)。" +
                "ANE負荷は取得できません")
            return
        }
        guard let channels = api.copyChannelsInGroup(
            "SoC Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            self.api = nil
            self.subscription = nil
            self.subscribedChannels = nil
            logFailure(
                "IOReportCopyChannelsInGroup(SoC Stats) が失敗しました。" +
                "ANE負荷は取得できません")
            return
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = api.createSubscription(nil, channels, &subscribed, 0, nil) else {
            self.api = nil
            self.subscription = nil
            self.subscribedChannels = nil
            logFailure("IOReportCreateSubscription が失敗しました。ANE負荷は取得できません")
            return
        }
        self.api = api
        self.subscription = sub
        // サンプリングには subscription の out-param(購読済みチャネル辞書)を使う
        // (元の channels 辞書だと値が全部 0 になる。実測済みの罠)
        self.subscribedChannels = subscribed?.takeRetainedValue() ?? channels
    }

    /// 0..1 に正規化した負荷率を返す。初回サンプルはデルタが無いため nil
    func sample() -> Double? {
        guard let api, let subscription, let subscribedChannels else { return nil }
        guard let current = api.createSamples(
            subscription, subscribedChannels, nil)?.takeRetainedValue() else {
            logIfNeeded("IOReportCreateSamples が失敗しました。ANE負荷は取得できません")
            return nil
        }
        defer { previousSample = current }
        guard let previous = previousSample else { return nil }
        guard let delta = api.samplesDelta(previous, current, nil)?.takeRetainedValue() else {
            logIfNeeded("IOReportCreateSamplesDelta が失敗しました。ANE負荷は取得できません")
            return nil
        }
        let residency = Self.aneResidency(delta: delta, api: api)
        guard residency.matchedChannels > 0 else {
            logIfNeeded(
                "SoC Stats に SOCn_ANE_Fn 形式の residency チャネルが見つかりません" +
                "(OS 更新でチャネル名が変わった可能性)。ANE負荷は取得できません")
            return nil
        }
        guard residency.totalTicks > 0 else { return nil }
        return min(1.0, max(0.0, Double(residency.busyTicks) / Double(residency.totalTicks)))
    }

    /// delta の "IOReportChannels" 配列を巡回し、チャネル名が SOCn_ANE_Fn にマッチする
    /// state 形式チャネルの residency を集計する。
    /// - busyTicks: 全対象チャネルの state 名 "ACT" の residency 合算(F1/F2 等の周波数段は
    ///   排他的に ACT になるため合算してよい)
    /// - totalTicks: 1 チャネル分の全 state(ACT+INACT)合計。各 F チャネルは同じ観測窓を
    ///   張るため、いずれか 1 チャネル分(最大値を採用)が窓全体の ticks になる
    /// CF型のまま扱う(Swift Dictionary へブリッジすると、IOReportChannelGetChannelName が
    /// チャネル辞書へ書き戻すためimmutableなブリッジ辞書上でクラッシュする。実測済みの罠)
    private static func aneResidency(
        delta: CFDictionary, api: IOReportAPI
    ) -> (busyTicks: Int64, totalTicks: Int64, matchedChannels: Int) {
        let key = "IOReportChannels" as CFString
        guard let itemsRaw = withExtendedLifetime(key, {
            CFDictionaryGetValue(delta, Unmanaged.passUnretained(key).toOpaque())
        }) else { return (0, 0, 0) }
        let items = Unmanaged<CFArray>.fromOpaque(itemsRaw).takeUnretainedValue()
        let count = CFArrayGetCount(items)
        var busyTicks: Int64 = 0
        var totalTicks: Int64 = 0
        var matchedChannels = 0
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(items, i) else { continue }
            let dict = Unmanaged<CFDictionary>.fromOpaque(raw).takeUnretainedValue()
            guard let name = api.getChannelName(dict)?.takeUnretainedValue() as String?,
                  name.range(of: channelNamePattern, options: .regularExpression) != nil,
                  api.getChannelFormat(dict) == stateFormat else { continue }
            matchedChannels += 1
            var channelTotal: Int64 = 0
            for stateIndex in 0..<api.getStateCount(dict) {
                let ticks = api.getStateResidency(dict, stateIndex)
                channelTotal += ticks
                if let stateName = api.getStateNameForIndex(dict, stateIndex)?
                    .takeUnretainedValue() as String?, stateName == "ACT" {
                    busyTicks += ticks
                }
            }
            totalTicks = max(totalTicks, channelTotal)
        }
        return (busyTicks, totalTicks, matchedChannels)
    }

    private func logIfNeeded(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        logFailure(message)
    }
}

/// libIOReport.dylib の dlopen/dlsym で解決した関数ポインタ群
private struct IOReportAPI {
    let copyChannelsInGroup: IOReportCopyChannelsInGroupFn
    let createSubscription: IOReportCreateSubscriptionFn
    let createSamples: IOReportCreateSamplesFn
    let samplesDelta: IOReportCreateSamplesDeltaFn
    let getChannelName: IOReportChannelGetChannelNameFn
    let getChannelFormat: IOReportChannelGetFormatFn
    let getStateCount: IOReportStateGetCountFn
    let getStateNameForIndex: IOReportStateGetNameForIndexFn
    let getStateResidency: IOReportStateGetResidencyFn

    static func load() -> IOReportAPI? {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard
            let copyChannels = sym("IOReportCopyChannelsInGroup", IOReportCopyChannelsInGroupFn.self),
            let createSub = sym("IOReportCreateSubscription", IOReportCreateSubscriptionFn.self),
            let createSamples = sym("IOReportCreateSamples", IOReportCreateSamplesFn.self),
            let samplesDelta = sym("IOReportCreateSamplesDelta", IOReportCreateSamplesDeltaFn.self),
            let getName = sym("IOReportChannelGetChannelName", IOReportChannelGetChannelNameFn.self),
            let getFormat = sym("IOReportChannelGetFormat", IOReportChannelGetFormatFn.self),
            let getStateCount = sym("IOReportStateGetCount", IOReportStateGetCountFn.self),
            let getStateName = sym("IOReportStateGetNameForIndex",
                                   IOReportStateGetNameForIndexFn.self),
            let getResidency = sym("IOReportStateGetResidency", IOReportStateGetResidencyFn.self)
        else { return nil }
        return IOReportAPI(
            copyChannelsInGroup: copyChannels, createSubscription: createSub,
            createSamples: createSamples, samplesDelta: samplesDelta,
            getChannelName: getName, getChannelFormat: getFormat,
            getStateCount: getStateCount, getStateNameForIndex: getStateName,
            getStateResidency: getResidency)
    }
}

private typealias IOReportCopyChannelsInGroupFn =
    @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
private typealias IOReportCreateSubscriptionFn =
    @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                    UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64,
                    CFTypeRef?) -> UnsafeMutableRawPointer?
private typealias IOReportCreateSamplesFn =
    @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias IOReportCreateSamplesDeltaFn =
    @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias IOReportChannelGetChannelNameFn =
    @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias IOReportChannelGetFormatFn =
    @convention(c) (CFDictionary) -> UInt8
private typealias IOReportStateGetCountFn =
    @convention(c) (CFDictionary) -> Int32
private typealias IOReportStateGetNameForIndexFn =
    @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
private typealias IOReportStateGetResidencyFn =
    @convention(c) (CFDictionary, Int32) -> Int64

// MARK: - メモリサンプラー

/// host_statistics64(HOST_VM_INFO64) の active+wire+compressor ページ数 × ページサイズを
/// 使用中メモリとみなす。合計は ProcessInfo.physicalMemory
private final class MemorySampler {
    struct Result {
        let used: Int
        let total: Int
    }

    private var loggedFailure = false
    private let logFailure: (String) -> Void

    init(logFailure: @escaping (String) -> Void) {
        self.logFailure = logFailure
    }

    func sample() -> Result? {
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

// MARK: - JSON イベント

/// hostMetrics イベント: サンプリングサイクル毎に1回、stdout に1行 NDJSON で出す。
/// 省略可能なフィールドは JSON 上で null を明示する(ApiScenarioInfo(ApiCommands.swift)と
/// 同方針。サンプラーが失敗したフィールドのみ null で、他フィールドは生かす)
private struct ApiHostMetricsEvent: Encodable {
    let kind = "hostMetrics"
    let ts: Double
    let cpu: Double?
    let gpu: Double?
    let ane: Double?
    let aneWatts: Double?
    let memUsedBytes: Int?
    let memTotalBytes: Int?

    private enum CodingKeys: String, CodingKey {
        case kind, ts, cpu, gpu, ane, aneWatts, memUsedBytes, memTotalBytes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ts, forKey: .ts)
        try container.encode(cpu, forKey: .cpu)
        try container.encode(gpu, forKey: .gpu)
        try container.encode(ane, forKey: .ane)
        try container.encode(aneWatts, forKey: .aneWatts)
        try container.encode(memUsedBytes, forKey: .memUsedBytes)
        try container.encode(memTotalBytes, forKey: .memTotalBytes)
    }
}
