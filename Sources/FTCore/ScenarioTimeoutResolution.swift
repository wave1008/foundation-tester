// シナリオ全体の watchdog 秒の優先順位の定義元(ScenarioHost.run だけが使う)。

import Foundation

public enum ScenarioTimeoutResolution {
    public enum Source: String, Sendable {
        case scenario = "@Test scenarioTimeout"
        case profile = "run profile scenarioTimeout"
        case defaultValue = "default"
    }

    /// `@Test(scenarioTimeout:)` > 実行プロファイル / `--scenario-timeout` > `ScenarioHost.defaultScenarioTimeout`。
    /// シナリオ側が短くても勝つ(そのシナリオだけ短く切る用途を殺さない)
    public static func resolve(scenario: Int?, settings: Int?) -> (seconds: Int, source: Source) {
        if let scenario { return (scenario, .scenario) }
        if let settings { return (settings, .profile) }
        return (ScenarioHost.defaultScenarioTimeout, .defaultValue)
    }

    /// `@Test(scenarioTimeout:)` が 0 以下なら赤にする理由。マクロが弾くのは整数リテラルだけで、式(`let t = 0`)は
    /// ここまで届く —— 解かずに通すと watchdog が 0 秒で即打ち切る(プロファイルの値は入口で正の数だけ通すのと揃える)
    public static func invalidScenarioValueReason(_ scenario: Int?) -> String? {
        guard let scenario, scenario <= 0 else { return nil }
        return "@Test scenarioTimeout must be a positive number of seconds (got \(scenario)), so this scenario was not run"
    }

    public static func seconds(scenario: Int?, settings: Int?) -> Int {
        resolve(scenario: scenario, settings: settings).seconds
    }
}
