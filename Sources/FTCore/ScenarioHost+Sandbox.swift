// ScenarioHost+Sandbox.swift
// シナリオ実行バイナリを起こす全経路(run・dry-run・一覧取得・OCR の暖機)が通る、サンドボックスの入口。
// **バイナリは起こし方に関わらず利用者のコードを実行しうる**(`_Main.swift` もシナリオの置き場にある)ので、
// 一覧取得と暖機も同じ枠で包む。
import Foundation

extension ScenarioHost {
    struct SandboxedLaunch {
        let executable: URL
        let arguments: [String]
        /// 子の環境へ足すぶん
        let environment: [String: String]
        /// 子が生きている間だけ要る。呼び手が子の終了後に `stop()` する
        let broker: SandboxBroker?
    }

    /// nil = 包まない(マシン側で `sandbox.disabled: true` のときだけ)。**包むと決まったのに枠を組めないときは
    /// 投げる**(枠なしで黙って起こさない)。`drivesDevice` が false(一覧取得・暖機・dry-run)なら
    /// Simulator の操作の口を開けない。`settings` は差し替え口(テスト用)
    static func sandboxedLaunch(project: TestProject, runner: URL, arguments: [String],
                                reportDir: String?, extraWritable: [String] = [],
                                connection: DriverConnection?, drivesDevice: Bool,
                                settings: () throws -> ScenarioSandbox.MachineSettings = {
                                    try ScenarioSandbox.machineSettings()
                                }) throws -> SandboxedLaunch? {
        guard let plan = try ScenarioSandbox.plan(settings: try settings()) else { return nil }
        if let reportDir {
            // 枠の中から作れるのは出力先そのものから下だけ(途中の親は作れない)
            try FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
        }
        var scope = try ScenarioSandbox.scope(
            project: project, plan: plan, reportDir: reportDir, extraWritable: extraWritable,
            packageRoot: packageRoot(),
            runner: runner, connection: connection)
        // CoreSimulator の直叩き(FTCoreSimShim)を止めて simctl = broker 経由へ倒す
        var environment = ["FT_SIMULATOR_CONTROL": "simctl"]
        if let temp = ScenarioSandbox.childTemporaryDirectory() { environment["TMPDIR"] = temp }
        if !plan.allowedDomains.isEmpty {
            scope.usesProxy = true
            environment.merge(try SandboxProxyRegistry.shared.environment(for: plan.allowedDomains)) { $1 }
        }
        var broker: SandboxBroker?
        do {
            if drivesDevice {
                let started = try SandboxBroker(
                    context: try ScenarioSandbox.brokerContext(scope, connection: connection),
                    directory: NSTemporaryDirectory())
                broker = started
                scope.brokerSocket = started.socketPath
                environment[SandboxGateway.environmentKey] = started.socketPath
            }
            let wrapped = ScenarioSandbox.wrap(
                runner: runner, arguments: arguments, profile: try ScenarioSandbox.profile(scope))
            return SandboxedLaunch(executable: wrapped.executable, arguments: wrapped.arguments,
                                   environment: environment, broker: broker)
        } catch {
            broker?.stop()
            throw error
        }
    }
}

/// 許可ドメインの集合ごとにプロキシを1つ、fleetest のプロセスが生きている間だけ立てる
/// (並列のレーンと連続するシナリオで共有する。止める口は持たない = プロセスの終了で消える)
// @unchecked: 可変の `proxies` は `lock` の内側でだけ読み書きする
final class SandboxProxyRegistry: @unchecked Sendable {
    static let shared = SandboxProxyRegistry()
    private let lock = NSLock()
    private var proxies: [[String]: SandboxProxy] = [:]

    func environment(for allowedDomains: [String]) throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let running = proxies[allowedDomains] { return running.environment }
        let proxy = try SandboxProxy(allowedDomains: allowedDomains)
        proxies[allowedDomains] = proxy
        return proxy.environment
    }
}
