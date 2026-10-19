// 宛先(iOS ブリッジのポート / Android の serial / 実行プロファイル)を省略したときの案内文が、
// 呼び手の引数名で書かれるための組。判定は FTBridgeClient / FTAndroid が共有し、文言の引数名だけ呼び手が渡す
// (既定値を置かない = 渡し忘れをコンパイルで止める)。

public struct TargetArgumentNames: Sendable, Equatable {
    public let port: String
    public let serial: String
    /// nil = その呼び手に profile 指定が無い(案内に出さない)
    public let profile: String?

    public init(port: String, serial: String, profile: String?) {
        self.port = port
        self.serial = serial
        self.profile = profile
    }

    /// MCP(ft_*)の引数名
    public static let mcp = TargetArgumentNames(port: "port:", serial: "serial:", profile: "profile:")
    /// CLI の手動駆動サブコマンド(--profile を持たない)
    public static let cliManual = TargetArgumentNames(port: "--port", serial: "--serial", profile: nil)
    /// CLI の run / api run(--profile を持つ)
    public static let cliRun = TargetArgumentNames(port: "--port", serial: "--serial", profile: "--profile")

    /// "X or P" / "X"(P が無いとき)
    public func either(_ argument: String) -> String {
        guard let profile else { return argument }
        return "\(argument) or \(profile)"
    }

    /// "Pass X to pick one, or P to use a run profile's device." / "Pass X to pick one."
    public func pickOne(_ argument: String) -> String {
        guard let profile else { return "Pass \(argument) to pick one." }
        return "Pass \(argument) to pick one, or \(profile) to use a run profile's device."
    }
}
