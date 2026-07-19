#!/usr/bin/env swift
// bench.swift
// 計測基盤: ftester のベンチハーネス。
// `<binary> api host-metrics` をホスト負荷の記録用に常駐させたまま、
// `<binary> api run --profile ...` を N 回繰り返し実行し、各回の NDJSON(ScenarioEvent 相当)を
// 保存しつつ、壁時計・ステップ時間内訳(durationMs/snapshotMs/actionMs/waitMs。StepExecutor が
// 計測して ScenarioEvent に載せたもの)・成功率・ヒール発生数・ホスト負荷をサマリ化する。
//
// Package.swift には追加しない単体スクリプト(#!/usr/bin/env swift)。jq 等の外部ツールには
// 依存せず、NDJSON/JSON の解析は Foundation の JSONSerialization のみで行う。
//
// 使い方:
//   Scripts/bench.swift --project <名前> --profile <名前> [--iterations <N>] \
//       [--binary <ftesterパス>] [--out <出力dir>] [--scenario <ID> ...]
//
//   --project <名前>      テストプロジェクト名(必須。Projects/<名前>)
//   --profile <名前>      実行プロファイル名(必須。profiles/runs/<名前>.json。デバイス供給込み)
//   --iterations <N>      繰り返し回数(既定 3)
//   --binary <パス>       ftester 実行ファイルのパス(既定 .build/debug/ftester)
//   --out <ディレクトリ>  出力先(既定 bench-results/<タイムスタンプ>)
//   --scenario <ID>       対象シナリオ ID(複数可。省略時はプロジェクトの全シナリオ
//                         [削除済み(@Deleted)を除く]を 1 回の api run にまとめて渡す)
//
// 出力(--out 配下):
//   host-metrics.ndjson   ベンチ全体を通したホスト CPU/GPU/ANE/メモリのサンプリング
//   run-<i>.ndjson        i 回目のイテレーションの生 NDJSON(ftester api run の出力そのもの)
//   summary.md            上記から集計したサマリ

import Foundation

// MARK: - Duration → ミリ秒

/// ContinuousClock の Duration → 整数ミリ秒(秒成分×1000 + attoseconds成分から算出。
/// 1ms = 1e15 attoseconds。Sources/FTCore/StepExecutor.swift の同名ロジックと同じ計算式だが、
/// このスクリプトは Package.swift 非参加の単体ファイルのためモジュールをまたいで共有できず複製する)
func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
}

// MARK: - 引数解析

struct Args {
    var project: String
    var profile: String
    var iterations = 3
    var binary = ".build/debug/ftester"
    var out: String?
    var scenarios: [String] = []
}

func printUsage() {
    print("""
    使い方: Scripts/bench.swift --project <名前> --profile <名前> [オプション]

    必須:
      --project <名前>        テストプロジェクト名(Projects/<名前>)
      --profile <名前>        実行プロファイル名(profiles/runs/<名前>.json)

    オプション:
      --iterations <N>        繰り返し回数(既定 3)
      --binary <パス>         ftester 実行ファイルのパス(既定 .build/debug/ftester)
      --out <ディレクトリ>    出力先(既定 bench-results/<タイムスタンプ>)
      --scenario <ID>          対象シナリオ ID(複数可。省略時は全シナリオ)
      -h, --help               このヘルプを表示
    """)
}

/// 引数エラー・実行時致命的エラーの共通出口(使い方を出して exit 64。ArgumentParser の
/// ValidationError 相当の終了コード)
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("エラー: \(message)\n".utf8))
    printUsage()
    exit(64)
}

func parseArgs(_ arguments: [String]) -> Args {
    var project: String?
    var profile: String?
    var iterations = 3
    var binary = ".build/debug/ftester"
    var out: String?
    var scenarios: [String] = []

    var i = 0
    while i < arguments.count {
        let arg = arguments[i]
        func nextValue() -> String? {
            guard i + 1 < arguments.count else { return nil }
            i += 1
            return arguments[i]
        }
        switch arg {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "--project":
            guard let v = nextValue() else { fail("--project には値が必要です") }
            project = v
        case "--profile":
            guard let v = nextValue() else { fail("--profile には値が必要です") }
            profile = v
        case "--iterations":
            guard let v = nextValue(), let n = Int(v), n > 0 else {
                fail("--iterations には正の整数が必要です")
            }
            iterations = n
        case "--binary":
            guard let v = nextValue() else { fail("--binary には値が必要です") }
            binary = v
        case "--out":
            guard let v = nextValue() else { fail("--out には値が必要です") }
            out = v
        case "--scenario":
            guard let v = nextValue() else { fail("--scenario には値が必要です") }
            scenarios.append(v)
        default:
            fail("不明な引数です: \(arg)")
        }
        i += 1
    }

    guard let project else { fail("--project は必須です") }
    guard let profile else { fail("--profile は必須です") }
    return Args(project: project, profile: profile, iterations: iterations,
               binary: binary, out: out, scenarios: scenarios)
}

// MARK: - 数値集計ヘルパー

func median(_ values: [Int]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count % 2 == 0 {
        return Double(sorted[mid - 1] + sorted[mid]) / 2
    }
    return Double(sorted[mid])
}

func mean(_ values: [Int]) -> Double? {
    guard !values.isEmpty else { return nil }
    return Double(values.reduce(0, +)) / Double(values.count)
}

func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

func secondsText(_ ms: Int) -> String { String(format: "%.2fs", Double(ms) / 1000) }
func secondsText(_ ms: Double?) -> String { ms.map { String(format: "%.2fs", $0 / 1000) } ?? "N/A" }
func millisecondsText(_ ms: Double?) -> String { ms.map { String(format: "%.0fms", $0) } ?? "N/A" }
func percentText(_ fraction: Double?) -> String {
    fraction.map { String(format: "%.1f%%", $0 * 100) } ?? "N/A"
}
func gigabytesText(_ bytes: Double?) -> String {
    bytes.map { String(format: "%.2fGB", $0 / 1_073_741_824) } ?? "N/A"
}

// MARK: - サブプロセス実行

/// 1 回で完結する短命コマンド(api list-scenarios 等)を実行し、stdout を丸ごと回収する。
/// パイプは「先に読み切ってから waitUntilExit」の順序を守る(先に待つと、出力が
/// パイプバッファを超えたときにプロセスと読み手が相互待ちでデッドロックしうるため)
func runCapturing(_ binaryPath: String, _ arguments: [String]) -> (exitCode: Int32, stdout: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.standardError
    do {
        try process.run()
    } catch {
        fail("プロセス起動に失敗しました(\(([binaryPath] + arguments).joined(separator: " "))): \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

/// FileHandle を「(行, 到着時刻)」の AsyncStream にする。readabilityHandler ベースで
/// データ到着ごとに行を切り出して即時配信し、EOF(空 Data)で残りを流して終了する
/// (Sources/FTCore/ScenarioHost.swift の lineStream と同じ方式。到着時刻はシナリオ毎の
/// 壁時計を近似するために使う)。生データは rawWriter へもそのまま書く
func lineStream(_ handle: FileHandle, rawWriter: FileHandle?) -> AsyncStream<(line: String, at: ContinuousClock.Instant)> {
    let clock = ContinuousClock()
    return AsyncStream { continuation in
        var buffer = Data()
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                if !buffer.isEmpty {
                    continuation.yield((String(decoding: buffer, as: UTF8.self), clock.now))
                    buffer.removeAll()
                }
                continuation.finish()
                return
            }
            rawWriter?.write(chunk)
            let arrivedAt = clock.now
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                continuation.yield((line, arrivedAt))
            }
        }
    }
}

// MARK: - NDJSON 集計

/// N 回のイテレーションを通じた集計値(ステップ時間内訳・成功率・ヒール発生数・
/// シナリオ毎の所要)。到着時刻ベースでシナリオ毎の壁時計を近似する
final class BenchAggregator {
    private(set) var scenarioDurationsMs: [Int] = []
    private(set) var stepDurationMs: [Int] = []
    private(set) var stepSnapshotMs: [Int] = []
    private(set) var stepActionMs: [Int] = []
    private(set) var stepWaitMs: [Int] = []
    private(set) var totalScenarios = 0
    private(set) var passedScenarios = 0
    private(set) var healedCount = 0
    private(set) var passedViaFallbackCount = 0

    /// worker+scenario をキーに scenarioStarted の到着時刻を覚えておき、対応する
    /// scenarioFinished が来た時点の到着時刻との差分をシナリオ 1 本分の壁時計とみなす
    private var scenarioStart: [String: ContinuousClock.Instant] = [:]

    private func key(scenario: String?, worker: String?) -> String {
        "\(worker ?? "-")::\(scenario ?? "-")"
    }

    func ingest(_ event: [String: Any], at instant: ContinuousClock.Instant) {
        guard let kind = event["kind"] as? String else { return }
        let scenario = event["scenario"] as? String
        let worker = event["worker"] as? String

        switch kind {
        case "scenarioStarted":
            scenarioStart[key(scenario: scenario, worker: worker)] = instant

        case "scenarioFinished":
            totalScenarios += 1
            if (event["passed"] as? Bool) == true { passedScenarios += 1 }
            if let started = scenarioStart.removeValue(forKey: key(scenario: scenario, worker: worker)) {
                scenarioDurationsMs.append(milliseconds(instant - started))
            }

        case "step":
            if let ms = event["durationMs"] as? Int { stepDurationMs.append(ms) }
            if let ms = event["snapshotMs"] as? Int { stepSnapshotMs.append(ms) }
            if let ms = event["actionMs"] as? Int { stepActionMs.append(ms) }
            if let ms = event["waitMs"] as? Int { stepWaitMs.append(ms) }
            switch event["status"] as? String {
            case "healed": healedCount += 1
            case "passedViaFallback": passedViaFallbackCount += 1
            default: break
            }

        default:
            break
        }
    }
}

/// host-metrics.ndjson を読み、CPU/GPU/ANE/メモリの平均・ピークを求める
struct HostMetricsSummary {
    var sampleCount = 0
    var cpuMean: Double?
    var cpuPeak: Double?
    var gpuMean: Double?
    var gpuPeak: Double?
    var aneMean: Double?
    var anePeak: Double?
    var memUsedMeanBytes: Double?
    var memUsedPeakBytes: Double?
    /// ane > 1% のサンプル数(healed が 0 件でも FM が動いていた形跡があるかの判定に使う)
    var aneActiveSamples = 0
}

func summarizeHostMetrics(url: URL) -> HostMetricsSummary {
    var summary = HostMetricsSummary()
    guard let data = try? Data(contentsOf: url) else { return summary }
    var cpu: [Double] = [], gpu: [Double] = [], ane: [Double] = [], mem: [Double] = []
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
        guard let lineData = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              obj["kind"] as? String == "hostMetrics" else { continue }
        summary.sampleCount += 1
        if let v = obj["cpu"] as? Double { cpu.append(v) }
        if let v = obj["gpu"] as? Double { gpu.append(v) }
        if let v = obj["ane"] as? Double {
            ane.append(v)
            if v > 0.01 { summary.aneActiveSamples += 1 }
        }
        if let v = obj["memUsedBytes"] as? Int { mem.append(Double(v)) }
    }
    summary.cpuMean = mean(cpu); summary.cpuPeak = cpu.max()
    summary.gpuMean = mean(gpu); summary.gpuPeak = gpu.max()
    summary.aneMean = mean(ane); summary.anePeak = ane.max()
    summary.memUsedMeanBytes = mean(mem); summary.memUsedPeakBytes = mem.max()
    return summary
}

// MARK: - host-metrics 常駐プロセス

/// `<binary> api host-metrics --interval 1` を記録用に spawn し、stdout をファイルへ直結する
func startHostMetrics(binaryPath: String, outputURL: URL) -> (process: Process, stdin: Pipe) {
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    guard let outHandle = try? FileHandle(forWritingTo: outputURL) else {
        fail("host-metrics 出力ファイルを作成できません: \(outputURL.path)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = ["api", "host-metrics", "--interval", "1"]
    process.standardOutput = outHandle
    process.standardError = FileHandle.standardError
    let stdin = Pipe()
    process.standardInput = stdin
    do {
        try process.run()
    } catch {
        fail("host-metrics の起動に失敗しました: \(error)")
    }
    return (process, stdin)
}

/// stdin を閉じて EOF を伝え、host-metrics を終了させる(終了しなければ SIGTERM)
func stopHostMetrics(_ handle: (process: Process, stdin: Pipe)) {
    try? handle.stdin.fileHandleForWriting.close()
    let deadline = Date().addingTimeInterval(5)
    while handle.process.isRunning, Date() < deadline {
        usleep(100_000)
    }
    if handle.process.isRunning {
        handle.process.terminate()
        usleep(300_000)
    }
}

// MARK: - 1 イテレーションの実行

struct IterationResult {
    let index: Int
    let wallMs: Int
    let exitCode: Int32
}

/// `<binary> api run --profile ... --scenario ...` を 1 回実行し、NDJSON を出力ファイルへ
/// 保存しながら aggregator に取り込む
func runIteration(index: Int, binaryPath: String, arguments: [String], outputURL: URL,
                  aggregator: BenchAggregator) async -> IterationResult {
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    guard let outHandle = try? FileHandle(forWritingTo: outputURL) else {
        fail("出力ファイルを作成できません: \(outputURL.path)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = arguments
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.standardError

    let clock = ContinuousClock()
    let start = clock.now
    do {
        try process.run()
    } catch {
        fail("プロセス起動に失敗しました(\(([binaryPath] + arguments).joined(separator: " "))): \(error)")
    }

    for await (line, at) in lineStream(stdoutPipe.fileHandleForReading, rawWriter: outHandle) {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        aggregator.ingest(obj, at: at)
    }
    try? outHandle.close()
    process.waitUntilExit()
    let wallMs = milliseconds(clock.now - start)
    return IterationResult(index: index, wallMs: wallMs, exitCode: process.terminationStatus)
}

// MARK: - メイン処理

let args = parseArgs(Array(CommandLine.arguments.dropFirst()))

guard FileManager.default.isExecutableFile(atPath: args.binary) else {
    fail("ftester バイナリが見つからないか実行できません: \(args.binary)"
        + "(先に swift build を実行するか --binary で指定してください)")
}

let timestamp: String = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}()
let outDir = URL(fileURLWithPath: args.out ?? "bench-results/\(timestamp)")
do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch {
    fail("出力ディレクトリを作成できません: \(outDir.path)(\(error))")
}
print("→ 出力先: \(outDir.path)")

// シナリオ一覧の取得(同時にビルドも済ませる。以降の api run は --skip-build で
// ビルド時間を計測から除外する)
print("→ シナリオ一覧を取得中(ビルド含む)...")
let listResult = runCapturing(args.binary, ["api", "list-scenarios", "--project", args.project])
guard listResult.exitCode == 0 else {
    fail("ftester api list-scenarios が失敗しました(exit \(listResult.exitCode))")
}
guard let listJSON = try? JSONSerialization.jsonObject(with: listResult.stdout) as? [String: Any],
      let scenarioDicts = listJSON["scenarios"] as? [[String: Any]] else {
    fail("api list-scenarios の出力を解析できませんでした")
}
let allScenarioIDs: [String] = scenarioDicts.compactMap { dict in
    guard let id = dict["id"] as? String, (dict["deleted"] as? Bool) != true else { return nil }
    return id
}
let scenarioIDs = args.scenarios.isEmpty ? allScenarioIDs : args.scenarios
guard !scenarioIDs.isEmpty else {
    fail("対象シナリオがありません(プロジェクト \(args.project) にシナリオが無いか、全て削除済みです)")
}
print("→ 対象シナリオ \(scenarioIDs.count) 件: \(scenarioIDs.joined(separator: ", "))")

// host-metrics 常駐開始(実イテレーションの間だけ記録する)
let hostMetricsURL = outDir.appendingPathComponent("host-metrics.ndjson")
print("→ host-metrics 記録を開始...")
let hostMetricsHandle = startHostMetrics(binaryPath: args.binary, outputURL: hostMetricsURL)

let aggregator = BenchAggregator()
var iterationResults: [IterationResult] = []

for i in 1...args.iterations {
    print("→ イテレーション \(i)/\(args.iterations) 実行中...")
    let ndjsonURL = outDir.appendingPathComponent("run-\(i).ndjson")
    let arguments = ["api", "run", "--project", args.project, "--profile", args.profile,
                     "--skip-build", "--scenario"] + scenarioIDs
    let result = await runIteration(index: i, binaryPath: args.binary, arguments: arguments,
                                    outputURL: ndjsonURL, aggregator: aggregator)
    iterationResults.append(result)
    let statusText = result.exitCode == 0 ? "OK" : "一部失敗(exit \(result.exitCode))"
    print("   完了: \(secondsText(result.wallMs)) — \(statusText)")
}

print("→ host-metrics 記録を停止...")
stopHostMetrics(hostMetricsHandle)
let hostSummary = summarizeHostMetrics(url: hostMetricsURL)

// MARK: - summary.md 生成

var md = "# ftester ベンチマーク結果\n\n"
md += "- プロジェクト: \(args.project)\n"
md += "- プロファイル: \(args.profile)\n"
md += "- 対象シナリオ: \(scenarioIDs.count) 件(\(scenarioIDs.joined(separator: ", ")))\n"
md += "- 反復回数: \(args.iterations)\n"
md += "- 実行日時: \(ISO8601DateFormatter().string(from: Date()))\n"

md += "\n## イテレーション別 壁時計\n\n"
md += "| # | 所要 | 結果 |\n|---|---|---|\n"
for r in iterationResults {
    md += "| \(r.index) | \(secondsText(r.wallMs)) | \(r.exitCode == 0 ? "OK" : "exit \(r.exitCode)") |\n"
}
md += "\n中央値: \(secondsText(median(iterationResults.map(\.wallMs))))\n"

md += "\n## シナリオ毎の所要(scenarioStarted〜scenarioFinished の到着時刻差分による近似)\n\n"
md += "- サンプル数: \(aggregator.scenarioDurationsMs.count)\n"
md += "- 中央値: \(secondsText(median(aggregator.scenarioDurationsMs)))\n"
md += "- 平均: \(secondsText(mean(aggregator.scenarioDurationsMs)))\n"
md += "- 最大: \(secondsText(aggregator.scenarioDurationsMs.max().map(Double.init)))\n"

md += "\n## ステップ所要(durationMs / snapshotMs / actionMs / waitMs)\n\n"
md += "- サンプル数: \(aggregator.stepDurationMs.count)\n"
md += "- durationMs 中央値: \(millisecondsText(median(aggregator.stepDurationMs)))"
    + " / 平均: \(millisecondsText(mean(aggregator.stepDurationMs)))\n"
md += "- 内訳平均(取得できたステップのみ): snapshot \(millisecondsText(mean(aggregator.stepSnapshotMs)))"
    + " / action \(millisecondsText(mean(aggregator.stepActionMs)))"
    + " / wait \(millisecondsText(mean(aggregator.stepWaitMs)))\n"

md += "\n## 成功率\n\n"
let successRate = aggregator.totalScenarios > 0
    ? Double(aggregator.passedScenarios) / Double(aggregator.totalScenarios) : nil
md += "- \(aggregator.passedScenarios) / \(aggregator.totalScenarios) シナリオ成功"
    + "(\(percentText(successRate)))\n"

md += "\n## 自己修復(ヒール)発生数\n\n"
md += "- healed: \(aggregator.healedCount) 件\n"
md += "- passedViaFallback: \(aggregator.passedViaFallbackCount) 件\n"

md += "\n## ホスト負荷(host-metrics)\n\n"
md += "- サンプル数: \(hostSummary.sampleCount)\n"
md += "- CPU: 平均 \(percentText(hostSummary.cpuMean)) / ピーク \(percentText(hostSummary.cpuPeak))\n"
md += "- GPU: 平均 \(percentText(hostSummary.gpuMean)) / ピーク \(percentText(hostSummary.gpuPeak))\n"
md += "- ANE: 平均 \(percentText(hostSummary.aneMean)) / ピーク \(percentText(hostSummary.anePeak))\n"
md += "- メモリ使用: 平均 \(gigabytesText(hostSummary.memUsedMeanBytes))"
    + " / ピーク \(gigabytesText(hostSummary.memUsedPeakBytes))\n"

if hostSummary.aneActiveSamples > 0 && aggregator.healedCount == 0 {
    md += "\n⚠️ 注意: 実行中に ANE 活動(> 1%)が \(hostSummary.aneActiveSamples) サンプル検知されましたが、"
        + "heal イベントは 0 件でした。healLocator 以外の用途(screenIs の画面検証や失敗時の"
        + "トリアージ等)で Foundation Models が稼働した可能性があります(FM介入検知)。\n"
}

let summaryURL = outDir.appendingPathComponent("summary.md")
do {
    try md.write(to: summaryURL, atomically: true, encoding: .utf8)
} catch {
    fail("summary.md の書き込みに失敗しました: \(error)")
}

print("→ 完了: \(summaryURL.path)")
