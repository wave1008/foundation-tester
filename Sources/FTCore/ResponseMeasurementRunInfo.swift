/// レスポンス計測の run の識別(run.json の `RunMetaRecord.responseMeasurement`。計測モードの run にだけ書く)。
/// 前回比(`fleetest results response`)は「同じデバイス・同じ機械」の run どうしだけを比べるので、デバイスを
/// 論理名(worker)ではなく端末そのもので識別する —— 論理名はプロファイルの書き換えで別の端末を指しうる。
/// 機械は `RunMetaRecord.host`
public struct ResponseMeasurementRunInfo: Codable, Sendable, Equatable {
    /// プロファイル上の論理名(ScenarioRunRecord.worker の `<platform>:` の後ろと同じ)
    public var deviceName: String
    /// Android の adb serial(計測は Android の実機1台だけ = ResponseMeasurementPolicy)
    public var serial: String?
    /// プロファイルの `model` / `osVersion`(書かれていれば。端末から読み直さない)
    public var model: String?
    public var osVersion: String?
    /// 各シナリオを続けて回した回数(`responseRepeat`)
    public var repeatCount: Int

    public init(deviceName: String, serial: String?, model: String?, osVersion: String?, repeatCount: Int) {
        self.deviceName = deviceName
        self.serial = serial
        self.model = model
        self.osVersion = osVersion
        self.repeatCount = repeatCount
    }
}
