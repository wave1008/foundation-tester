// RunTunables.swift
// 層 C(受け手のアプリやデバイスの速さで正解が変わる既定)の束。欄名は将来の実行プロファイルの
// キー名と同じにする。開放は RunProfileDocument に欄を足し ScenarioExecutionSettings の変換 init で
// 写すだけ。判定の閾値(層 B)や不変条件(層 A)は入れない。
// 既定値は init の1箇所だけ(層ごとの既定引数は渡し忘れを合法にする)。
public struct RunTunables: Codable, Sendable, Equatable {
    /// ステップが待ちを明示しないときの既定(秒)。MCP と共有する定義元は `DefaultWait`
    public var defaultTimeout: Double
    /// DSL コマンド1つの壁時計の締切(秒)。超えるとステップを失敗にして次へ進む。
    /// 長すぎると固まったコマンド1つが全レーンを止め、短すぎると正常な長い操作
    /// (アプリ起動・インストール)を打ち切る。内側の待ち(110s 等)はこの値より小さく保つ
    public var commandTimeout: Double
    /// in-app ブリッジへの起動時プローブ(注入先アプリの判別)の締切(秒)。
    /// 待ちは判断の正しさと引き換え: 短いと冷えた実機ブリッジを「無応答」と誤読し、
    /// 長いと suspend 中のアプリ(TCP は受理して答えない)でその秒数を丸ごと払う
    public var injectedAppProbeTimeout: Double

    public init(defaultTimeout: Double = DefaultWait.seconds,
                commandTimeout: Double = 120,
                injectedAppProbeTimeout: Double = 10) {
        self.defaultTimeout = defaultTimeout
        self.commandTimeout = commandTimeout
        self.injectedAppProbeTimeout = injectedAppProbeTimeout
    }
}
