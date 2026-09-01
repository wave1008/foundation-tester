// VSCode拡張のデバイスモニターパネル向け常駐CLI(fleetest api host-metrics)。ホストMacの
// CPU/GPU負荷とメモリ使用量を一定間隔でサンプリングし NDJSON(hostMetrics)で stdout に
// 流す(このイベントのみ。診断は stderr)。テストプロジェクトに依存しないため --project は無い。
// 終了条件: stdin EOF または SIGTERM/SIGINT。サンプラー実装(CPUSampler 等)・実測知見の
// doc コメントは Sources/FTCore/HostMetricsSampler.swift 参照(失敗時はクラッシュさせず該当
// フィールドを null にし、stderr ログはサンプラー毎に初回1回だけ)。
// --log 指定時は各サンプルを NDJSON ファイルへも追記する(16MiB で .1 へ1世代ローテ・行アトミック追記)。
// 集計は api host-metrics-summary。
// fmCalls/fmFailures/fmTotalMs はこのプロセス自身の実測ではない —— FM を実際に呼ぶのは
// 各シナリオランナー(FTFoundationModels)で、このコマンドは FMUsageLedger の控えを毎 tick
// 読むだけ(Sources/FTCore/FMUsageLedger.swift 参照)。

import ArgumentParser
import Foundation
import FTCore
import IOKit

struct ApiHostMetricsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host-metrics",
        abstract: "Sample the host Mac CPU/GPU load and memory usage at a fixed interval and stream them"
            + " as NDJSON (hostMetrics) on stdout (diagnostics on stderr only;"
            + " exits on stdin EOF or SIGTERM/SIGINT)")

    @Option(help: "Sampling interval in seconds (default 1.0)")
    var interval: Double = 1.0

    @Option(name: .customLong("log"), help: "Path of an NDJSON file to append samples to (when omitted nothing is saved; stdout only)")
    var logPath: String?

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
        let memorySampler = MemorySampler(logFailure: logStderr)
        // open 失敗時は nil(stdout のみで継続。logFailure がクラッシュさせない契約は HostMetricsLog 参照)
        let logger = logPath.flatMap { HostMetricsLog(path: $0, logFailure: logStderr) }

        // 初回は差分が取れないサンプラー(CPU)のための捨てサンプル。これにより
        // 最初の interval 経過後に出す1行目から値を出せる
        _ = cpuSampler.sample()
        // nil = 基準未取得。最初の drain は控えるだけで増分を出さない(FMUsageLedger.drain 参照)
        var fmPrevious: [Int32: FMUsageLedger.Counters]?

        while !stop.isSet {
            await Self.sleepInterruptible(seconds: interval, stop: stop)
            guard !stop.isSet else { break }

            let cpu = cpuSampler.sample()
            let gpu = gpuSampler.sample()
            let mem = memorySampler.sample()
            let fm = FMUsageLedger.drain(previous: &fmPrevious)

            let sample = HostMetricsSample(
                ts: Date().timeIntervalSince1970,
                cpu: cpu, gpu: gpu,
                memUsedBytes: mem?.used, memTotalBytes: mem?.total,
                fmCalls: fm?.calls, fmFailures: fm?.failures, fmTotalMs: fm?.totalMs)
            if let line = sample.encodedLine() {
                print(line)
                logger?.append(line)
            }
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
        thread.name = "fleetest-api-host-metrics-stdin"
        thread.start()
    }

    /// SIGTERM/SIGINT を捕捉して停止フラグを立てる(既定の即時終了を上書きし、ループの
    /// 区切りでクリーンに終了できるようにする)。戻り値はループを抜けるまで呼び出し側が
    /// 保持すること(DispatchSourceSignal は解放されるとハンドラが外れる。
    /// ApiMonitorCommand.swift と同じ実装)
    private func installSignalHandlers(stop: StopFlag) -> [DispatchSourceSignal] {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "fleetest-api-host-metrics-signal")
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
