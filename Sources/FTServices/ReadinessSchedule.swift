// 起動完了の待ちの状態機械(docs/remote-runner.md §17「順序と失敗の扱い」)。純粋: 時刻は入力(秒。基準は呼び手が揃える)。
// probe の実行・コンテナの監視は呼び手。ここは「次に何をするか」だけを返す。
// 対象は起動したまま動くコンテナだけ —— `service_completed_successfully` の相手(初期化サービス)は呼び手が前面で実行して
// 終了コードで決着する(Apple Container の inspect は終了コードを持たないので、待ちながら読む形では決められない)。

import Foundation

public struct HealthcheckPolicy: Sendable, Equatable {
    public var intervalSeconds: Double
    public var timeoutSeconds: Double
    public var retries: Int
    public var startPeriodSeconds: Double

    public init(intervalSeconds: Double, timeoutSeconds: Double, retries: Int, startPeriodSeconds: Double) {
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.retries = retries
        self.startPeriodSeconds = startPeriodSeconds
    }

    /// compose の既定値(interval 30s・timeout 30s・retries 3・start_period 0s)。compose と同じ意味に合わせる
    /// (Docker と Apple で待ちが割れない)。尽きたとき = `retries` 回の失敗で起動の失敗。
    public static let composeDefaults = HealthcheckPolicy(
        intervalSeconds: 30, timeoutSeconds: 30, retries: 3, startPeriodSeconds: 0)

    /// 欄が無い・duration が読めない項目は既定値(読めない値は検査が先に断る)。
    public init(_ hc: Healthcheck?) {
        let d = Self.composeDefaults
        intervalSeconds = hc?.interval.flatMap(Self.seconds(duration:)) ?? d.intervalSeconds
        timeoutSeconds = hc?.timeout.flatMap(Self.seconds(duration:)) ?? d.timeoutSeconds
        retries = hc?.retries ?? d.retries
        startPeriodSeconds = hc?.startPeriod.flatMap(Self.seconds(duration:)) ?? d.startPeriodSeconds
    }

    /// `ComposePolicy.isDuration` と同じ文法(`<数>(us|ms|s|m|h)` の連結・数は小数可)。読めなければ nil。
    public static func seconds(duration s: String) -> Double? {
        guard ComposePolicy.isDuration(s) else { return nil }
        let chars = Array(s.utf8)
        var i = 0
        var total = 0.0
        while i < chars.count {
            let start = i
            while i < chars.count, (chars[i] >= 48 && chars[i] <= 57) || chars[i] == 46 { i += 1 }
            guard let number = Double(String(decoding: chars[start..<i], as: UTF8.self)) else { return nil }
            let rest = chars[i...]
            if rest.starts(with: Array("us".utf8)) { total += number / 1_000_000; i += 2 }
            else if rest.starts(with: Array("ms".utf8)) { total += number / 1000; i += 2 }
            else if chars[i] == UInt8(ascii: "s") { total += number; i += 1 }
            else if chars[i] == UInt8(ascii: "m") { total += number * 60; i += 1 }
            else { total += number * 3600; i += 1 }
        }
        return total
    }
}

public enum ReadinessKind: Sendable, Equatable {
    /// healthcheck なし(`disable` / `test: NONE` を含む)。「コンテナが起動した」で使えるとみなす。
    case started
    case healthy(HealthcheckPolicy)

    /// 依存の条件と healthcheck から待ちの種類を決める。`service_completed_successfully` は nil
    /// (この状態機械の対象外 = 呼び手が前面実行の終了コードで決める)。
    public static func make(condition: Dependency.Condition, healthcheck: Healthcheck?) -> ReadinessKind? {
        switch condition {
        case .serviceCompletedSuccessfully:
            return nil
        case .serviceStarted:
            return .started
        case .serviceHealthy:
            guard let hc = healthcheck, !hc.disable, hc.test != .none else { return .started }
            return .healthy(HealthcheckPolicy(hc))
        }
    }
}

public enum ReadinessEvent: Sendable, Equatable {
    case probeSucceeded(at: Double)
    case probeFailed(at: Double)
    case probeTimedOut(at: Double)
    /// 終了コードはランタイムが報告するときだけ(Apple Container の inspect には無い = nil)。
    case containerExited(code: Int32?, at: Double)
    case tick(at: Double)
}

public enum ReadinessAction: Sendable, Equatable {
    case probe
    case wait(untilSeconds: Double)
    case ready
    case failed(reason: String)
}

public struct ReadinessSchedule: Sendable, Equatable {
    private let kind: ReadinessKind
    private let startedAt: Double
    private var consecutiveFailures = 0
    private var lastProbeResultAt: Double?
    private var probeInFlightSince: Double?
    private var terminal: ReadinessAction?

    public init(kind: ReadinessKind, startedAt: Double) {
        self.kind = kind
        self.startedAt = startedAt
    }

    public mutating func apply(_ event: ReadinessEvent) -> ReadinessAction {
        if let terminal { return terminal }
        if case let .containerExited(code, _) = event {
            let code = code.map { " with code \($0)" } ?? ""
            return finish(.failed(reason: "container exited\(code) before it became ready"))
        }
        switch kind {
        case .started:
            return finish(.ready)
        case .healthy(let policy):
            return applyHealthy(event, policy)
        }
    }

    private mutating func finish(_ action: ReadinessAction) -> ReadinessAction {
        terminal = action
        return action
    }

    /// 最初の probe は開始直後(interval を待たない)。以降は前回の結果から interval 後。
    private mutating func applyHealthy(_ event: ReadinessEvent, _ policy: HealthcheckPolicy) -> ReadinessAction {
        switch event {
        case .probeSucceeded:
            return finish(.ready)
        case .probeFailed(let at), .probeTimedOut(let at):
            probeInFlightSince = nil
            lastProbeResultAt = at
            // start_period の間の失敗は数えない
            if at - startedAt >= policy.startPeriodSeconds { consecutiveFailures += 1 }
            if consecutiveFailures >= max(policy.retries, 1) {
                return finish(.failed(reason: "healthcheck failed \(consecutiveFailures) consecutive times"))
            }
            return .wait(untilSeconds: at + policy.intervalSeconds)
        case .tick(let at):
            if let since = probeInFlightSince { return .wait(untilSeconds: since + policy.timeoutSeconds) }
            let next = lastProbeResultAt.map { $0 + policy.intervalSeconds } ?? startedAt
            if at >= next {
                probeInFlightSince = at
                return .probe
            }
            return .wait(untilSeconds: next)
        case .containerExited:  // apply が先に終端へ送る
            return .wait(untilSeconds: lastProbeResultAt.map { $0 + policy.intervalSeconds } ?? startedAt)
        }
    }
}
