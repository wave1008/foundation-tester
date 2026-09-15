// F8b(2026-09-15 実測): ポート奪取(占有中のブリッジが別デバイスへ差し替わる)の検知。
//
// ホスト側 `RunOrchestrator.bridgeUnreachable` は疎通しか見ない —— 奪った側も /status に
// 正しく応答する(実測: 実機 SE3 の iproxy が張っていたポートへ、別シミュレータの in-app
// ブリッジが同じ bundle ID で居座り、そのまま S0020 が別デバイス上で PASS した)ため、
// 奪取後も「到達できる」と誤判定して見逃す。この検査はシナリオ実行サブプロセス
// (ScenarioRunnerMain)側で、駆動を始める前に読んだ /status の中身を接続の期待値と
// 突き合わせる多層防御であって、ポート奪取そのものの防止はブリッジ供給側の責務。
//
// 純粋関数。判断材料が無ければ ok(fail-closed にすると健全なブリッジまで run を止める)。
public enum BridgeIdentityCheck {
    /// 呼び出し元(ScenarioRunnerMain の CLI 引数 = DriverConnection の転写)が持つ期待値
    public struct Expected: Sendable {
        public let port: UInt16
        /// iOS のシミュレータ UDID、または実機の識別子(DriverConnection.udid と同じ)
        public let udid: String?
        public let physical: Bool
        /// nil = xcuitest(既定)。"inapp"/"hybrid" を渡すこの検査の呼び出し元は無い
        /// (in-app/hybrid で同一アプリに繋がる経路は InAppDriver/WebViewDelegatingDriver として
        /// 事前確認そのものから除外される)が、判定自体は汎用に保つ
        public let engine: String?
        /// udid が無いときの表示用フォールバックだけに使う(判定には使わない)
        public let deviceName: String?

        public init(port: UInt16, udid: String?, physical: Bool, engine: String?,
                    deviceName: String? = nil) {
            self.port = port
            self.udid = udid
            self.physical = physical
            self.engine = engine
            self.deviceName = deviceName
        }
    }

    /// ホスト側プローブ用: DriverConnection から期待値を組む。**probedPort が xcuiPort なら期待エンジンは
    /// xcuitest**(hybrid の死活確認は in-app 側でなく xcuitest 側ポートを叩く。RunOrchestrator.bridgeUnreachable)。
    /// それ以外は connection.engine(nil = xcuitest 既定は verdict 側の規則)
    public static func expected(for connection: DriverConnection, probedPort: UInt16) -> Expected {
        let engine = (connection.xcuiPort != nil && connection.xcuiPort == probedPort)
            ? "xcuitest" : connection.engine
        return Expected(port: probedPort, udid: connection.udid, physical: connection.physical,
                        engine: engine, deviceName: connection.deviceName)
    }

    public enum Verdict: Equatable {
        case ok
        case mismatch(detail: String)
    }

    /// 規則(材料が無ければ ok):
    /// ① status.udid があり期待 udid と違う → mismatch
    /// ② status.udid が無いとき: 期待が実機なのに status.engine=="inapp"(実機に in-app は無い=
    ///    相手はシミュレータ) → mismatch。期待エンジンと status.engine の inapp/非inapp が
    ///    食い違う(どちらの向きも) → mismatch
    public static func verdict(expected: Expected, status: StatusResponse) -> Verdict {
        if let statusUDID = status.udid, let expectedUDID = expected.udid {
            return statusUDID == expectedUDID ? .ok : .mismatch(detail: detail(expected: expected, status: status))
        }
        if status.udid == nil {
            if expected.physical, status.engine == "inapp" {
                return .mismatch(detail: detail(expected: expected, status: status))
            }
            let expectedEngine = expected.engine ?? "xcuitest"
            if let statusEngine = status.engine, (statusEngine == "inapp") != (expectedEngine == "inapp") {
                return .mismatch(detail: detail(expected: expected, status: status))
            }
        }
        return .ok
    }

    private static func detail(expected: Expected, status: StatusResponse) -> String {
        let expectedID = expected.udid ?? expected.deviceName ?? "unknown"
        return "the bridge on port \(expected.port) now belongs to another device: \(status.device)"
            + " (engine \(status.engine ?? "unknown"), udid \(status.udid ?? "unknown"))"
            + " — expected \(expectedID). The lane's port was taken over; the worker must be re-provisioned"
    }
}
