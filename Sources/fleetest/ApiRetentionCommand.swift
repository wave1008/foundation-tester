// VSCode拡張向け: 保持容量ポリシー(LocalConfig.retention)の読み書きと現在の使用量
// (fleetest api retention)。stdout には結果 1 行の JSON だけを出す(診断は stderr のみ。
// ApiRemoteHostsCommand.swift と同じ流儀)。
//
// **拡張側と1:1の契約**: policy / defaults / usage の3つとも**全キーを必ず出す**
// (省略可能フィールドでも undefined 判定を書かせない)。`policy` は nil を既定で埋めた
// **実効値** —— 拡張は「今なにが効いているか」を表示するので、未設定と既定の差は出さない。

import ArgumentParser
import Foundation
import FTCore

struct ApiRetentionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retention",
        abstract: "Read or update the retention policy (~/.config/fleetest/config.json) and print it"
            + " with the current usage as JSON on stdout (diagnostics on stderr only)")

    @Option(name: .customLong("import"),
            // ArgumentHelp は文字列リテラルからしか作れない(連結した String は渡せない)
            help: ArgumentHelp("Update only the keys present in this JSON object "
                + "(a null value resets that key to its default), then print the result"))
    var importJSON: String?

    /// **使用量は opt-in**。集計は全ファイルを stat して回るので実測 21 秒かかり、
    /// 毎回払うと設定タブがその間ずっと空欄になる。ポリシーの読み書きだけなら即座に返るので、
    /// 呼び手(拡張)は先に値を出してから、これを付けた2回目で使用量を埋める。
    /// 付けないときの `usage` は**キーごと null**(0 と混ぜない = 「測っていない」と
    /// 「1バイトも無い」は別)
    @Flag(name: .customLong("usage"), help: "Also measure and report the current usage (slow)")
    var withUsage = false

    func run() async throws {
        let roots = try RetentionSweeper.Roots.resolve()
        var config = LocalConfig.load()
        if let importJSON {
            config.retention = Self.merge(config.retention, with: try Self.decode(importJSON))
            try config.save()
        }
        let policy = config.retention ?? RetentionPolicy()
        let usage = withUsage ? RetentionSweeper.usage(roots: roots) : nil
        Self.emit(policy: policy, usage: usage)
    }

    /// **キーが無い = 据え置き / null = 既定へ戻す(LocalConfig から消す)/ 値 = 上書き**。
    /// 全欄が未設定になったら欄ごと nil にする(既定だけの retention を設定ファイルに残さない)。
    /// 純粋関数にしてあるのは検証がロジックの再実装にならないようにするため
    static func merge(_ current: RetentionPolicy?, with update: Import) -> RetentionPolicy? {
        var policy = current ?? RetentionPolicy()
        update.deviceCapturesMaxBytes.apply(to: &policy.deviceCapturesMaxBytes)
        update.recordingsMaxBytes.apply(to: &policy.recordingsMaxBytes)
        update.reportsMaxBytes.apply(to: &policy.reportsMaxBytes)
        update.logsMaxBytes.apply(to: &policy.logsMaxBytes)
        update.sweepAfterRun.apply(to: &policy.sweepAfterRun)
        return policy.isEmpty ? nil : policy
    }

    static func decode(_ json: String) throws -> Import {
        guard let data = json.data(using: .utf8) else {
            throw ValidationError("--import is not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(Import.self, from: data)
        } catch {
            throw ValidationError("--import is not a valid retention JSON object:"
                + " \(error.localizedDescription)")
        }
    }

    /// 送られてきたキーだけを上書きするための3値。**キー欠落と null を畳まない** ——
    /// 畳むと「触っていない欄」と「既定へ戻す指定」が同じ形になり、片方が必ず消える
    enum Field<Value> {
        case unchanged
        case reset
        case set(Value)

        func apply(to target: inout Value?) {
            switch self {
            case .unchanged: break
            case .reset: target = nil
            case .set(let value): target = value
            }
        }
    }

    struct Import: Decodable {
        var deviceCapturesMaxBytes: Field<Int64>
        var recordingsMaxBytes: Field<Int64>
        var reportsMaxBytes: Field<Int64>
        var logsMaxBytes: Field<Int64>
        var sweepAfterRun: Field<Bool>

        private enum CodingKeys: String, CodingKey {
            case deviceCapturesMaxBytes, recordingsMaxBytes, reportsMaxBytes, logsMaxBytes
            case sweepAfterRun
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceCapturesMaxBytes = try Self.field(container, .deviceCapturesMaxBytes)
            recordingsMaxBytes = try Self.field(container, .recordingsMaxBytes)
            reportsMaxBytes = try Self.field(container, .reportsMaxBytes)
            logsMaxBytes = try Self.field(container, .logsMaxBytes)
            sweepAfterRun = try Self.field(container, .sweepAfterRun)
        }

        /// **`decodeIfPresent` を使わない** —— あれは JSON の null に対しても nil を返すので、
        /// 「キーが無い」と「null(既定へ戻す)」が同じ形に潰れる
        private static func field<Value: Decodable>(
            _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) throws -> Field<Value> {
            guard container.contains(key) else { return .unchanged }
            if try container.decodeNil(forKey: key) { return .reset }
            return .set(try container.decode(Value.self, forKey: key))
        }
    }

    private static func emit(policy: RetentionPolicy, usage: [RetentionSweeper.Category: Int64]?) {
        let output = Output(
            policy: PolicyOutput(policy.resolved), defaults: PolicyOutput(RetentionPolicy.defaults),
            usage: UsageOutput(
                deviceCaptures: usage?[.deviceCaptures], recordings: usage?[.recordings],
                reports: usage?[.reports], logs: usage?[.logs]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(output),
              let line = String(data: data, encoding: .utf8) else { return }
        ConsoleOut.out(line)
    }

    /// 実効値なので Optional を持たない(RetentionPolicy をそのまま encode すると
    /// 未設定の欄がキーごと消える = 契約違反になる)
    private struct PolicyOutput: Encodable {
        let deviceCapturesMaxBytes: Int64
        let recordingsMaxBytes: Int64
        let reportsMaxBytes: Int64
        let logsMaxBytes: Int64
        let sweepAfterRun: Bool

        init(_ policy: RetentionPolicy) {
            deviceCapturesMaxBytes = policy.effectiveDeviceCapturesMaxBytes
            recordingsMaxBytes = policy.effectiveRecordingsMaxBytes
            reportsMaxBytes = policy.effectiveReportsMaxBytes
            logsMaxBytes = policy.effectiveLogsMaxBytes
            sweepAfterRun = policy.effectiveSweepAfterRun
        }
    }

    /// **`--usage` を付けなかったときは全欄 null**(0 と混ぜない)。
    /// 欄は必ず出す(拡張に undefined 判定を書かせない。ApiRemoteHostsCommand と同じ流儀)
    private struct UsageOutput: Encodable {
        let deviceCaptures: Int64?
        let recordings: Int64?
        let reports: Int64?
        let logs: Int64?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(deviceCaptures, forKey: .deviceCaptures)
            try c.encode(recordings, forKey: .recordings)
            try c.encode(reports, forKey: .reports)
            try c.encode(logs, forKey: .logs)
        }

        enum CodingKeys: String, CodingKey {
            case deviceCaptures, recordings, reports, logs
        }
    }

    private struct Output: Encodable {
        let policy: PolicyOutput
        let defaults: PolicyOutput
        let usage: UsageOutput
    }
}
