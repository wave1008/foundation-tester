import Foundation

/// run が dispatch.lock で始まらなかった理由を、起こした側へ**構造化して**渡す(拒否の文言を一致で判定しない)。
/// **記録の意味は「起こされたプロセス自身が、ロックの拒否で終わった」**(読み手の MCP はこれがあれば別の run の結果と照合しない)。
/// そのために守ること: ①置き場は起こした側(MCP の ft_start_run)が環境変数で渡し、無ければ書かない ②書くのは FTRemote の
/// `DispatchWaitStatus.refused()` と、状態を作らずに断るリモートの1経路 ③機械分担の親が拒否を捕まえて残りの機械で続けるときは消す
/// (`DispatchPrelock`)④起こされたプロセスが起こす子へは置き場を渡さない —— fleetest の子(`ParentDeathWatch.childEnvironment` と、
/// それを通らない常駐3種 = services の所有者・FM の常駐・背景の掃除)・シナリオ実行バイナリ(`ScenarioHost.childEnvironment` /
/// `ScenarioSandbox.parentOnlyEnvironmentKeys`。置き場の `mcp-runs/` は `ScenarioSandbox.writeDeniedPaths`)。
/// `DispatchRefusalReportTests` が経路を固定する
public enum DispatchRefusalReport {
    public static let environmentKey = "FT_DISPATCH_REFUSAL_REPORT"

    public struct Record: Codable, Equatable, Sendable {
        /// 渡されていた待つ上限(秒)。nil = 待たずに断った
        public let limitSeconds: Int?
        /// 待った秒数
        public let waitedSeconds: Int

        public init(limitSeconds: Int?, waitedSeconds: Int) {
            self.limitSeconds = limitSeconds
            self.waitedSeconds = waitedSeconds
        }
    }

    public static func write(_ record: Record, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment[environmentKey], !path.isEmpty,
              let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// 拒否を捕まえて続ける呼び手が、書かれた記録を取り消す(終わらなかったので「拒否で終わった」ではない)
    public static func clear(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment[environmentKey], !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 無い・読めないなら nil(「拒否されなかった」と「拒否の記録を読めなかった」は区別しない = 案内を足さないだけ)
    public static func read(_ url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}
