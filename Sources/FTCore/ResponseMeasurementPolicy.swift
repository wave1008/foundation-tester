// レスポンス計測モード(RunProfileDocument.responseMeasurement)の検査。純粋関数。
// 設定の検査(`validateSettings`)は ProfileResolver.resolve の1箇所(`fleetest run --profile` と `fleetest api run --profile` が共有)。
// デバイスの検査(`validateDevices`)は `--device` / `--runner local` で絞った**後**の台数に当てる = run / api run の入口の2箇所
// (ロックの前・機械へ配る前。マシン別のサブ実行の中だけで数えると、手元とリモートに1台ずつ配られて並行に測ってしまう)。
// 強制値(アニメーション ON・FM/OCR/録画 OFF)は DeviceIndependentRunSettings.resolve が持つ。
public enum ResponseMeasurementPolicy {

    /// 既定の繰り返し回数。根拠: 中央値・p90 は複数の標本が要る(docs/response-measurement.md §8.1)。
    /// t2 は1回目から出る(木の履歴で判定する = §5「2b の方式」)ので、5 なら 5 標本
    public static let defaultRepeat = 5
    /// 下限 1: 1回でも firstFrameMs と t2 は測れる(繰り返しは標本を増やすだけ)
    public static let minRepeat = 1
    /// 上限 50: 1回の計測 run の所要を有限に収める。これを超える値は意図より打ち間違いの可能性が高い
    public static let maxRepeat = 50

    /// 計測は 1 台ずつ順に回すので、全台で回す・分ける・複数機械へ並べる指定とは併用できない
    public static func combinationRejection(flag: String) -> String {
        "\(flag) cannot be combined with responseMeasurement (it measures one device at a time);"
            + " remove \(flag) or turn responseMeasurement off"
    }

    /// `--set` に responseMeasurement=true があるか(プロファイルを読まずに分かる範囲)
    public static func isRequested(by overrides: [String: RunProfileSetValue]) -> Bool {
        overrides["responseMeasurement"] == .bool(true)
    }

    /// run.json に書く計測 run の識別。計測モードでない・デバイスが 1 台でない(検査済みなら起きない)ときは nil
    public static func runInfo(resolved: ResolvedProfile) -> ResponseMeasurementRunInfo? {
        guard resolved.responseMeasurement, resolved.devices.count == 1, let device = resolved.devices.first else {
            return nil
        }
        return ResponseMeasurementRunInfo(
            deviceName: device.name, serial: device.spec.serial, udid: device.spec.udid,
            model: device.spec.model, osVersion: device.spec.osVersion,
            repeatCount: resolved.responseRepeat)
    }

    /// 計測モードでないのに responseRepeat があれば断る(黙って効かない形を作らない)
    public static func validateRepeatScope(_ doc: RunProfileDocument, run: String) throws {
        if doc.responseRepeat != nil, doc.responseMeasurement != true {
            throw ProfileError.responseRepeatWithoutMeasurement(run: run)
        }
    }

    /// 有効なときだけ呼ぶ。`devices` は有効な(enabled)デバイスだけ。設定とデバイスの両方を検査する
    public static func validate(_ doc: RunProfileDocument, devices: [ResolvedDevice], run: String) throws {
        try validateSettings(doc, run: run)
        try validateDevices(devices, run: run)
    }

    /// 計測の run が回すデバイスの検査。`devices` は絞った後の、有効なデバイスだけ
    public static func validateDevices(_ devices: [ResolvedDevice], run: String) throws {
        guard devices.count == 1, let device = devices.first else {
            throw ProfileError.responseMeasurementDeviceCount(run: run, count: devices.count)
        }
        guard device.spec.isPhysical else {
            throw ProfileError.responseMeasurementNotPhysical(run: run, device: device.name)
        }
        // iOS 実機はホストから Reduce Motion を変えられないので、端末自身のアニメーション設定のまま測る
        // (Android は run の開始時に倍率を合わせる = ProfileWorkerFactory.syncAnimationSettings)。
        // 実機のエンジンは xcuitest だけ(kind=physical に inapp を断る検査が RunProfile の解決にある)
        guard device.platform == "android" || device.platform == "ios" else {
            throw ProfileError.responseMeasurementUnsupportedPlatform(
                run: run, device: device.name, platform: device.platform)
        }
    }

    /// 計測モードの設定の検査(デバイスに依らない)。有効なときだけ呼ぶ
    public static func validateSettings(_ doc: RunProfileDocument, run: String) throws {
        if let value = doc.responseRepeat, !(minRepeat...maxRepeat).contains(value) {
            throw ProfileError.responseRepeatOutOfRange(run: run, value: value, min: minRepeat, max: maxRepeat)
        }
        if doc.enableAnimations == false {
            throw ProfileError.responseMeasurementConflict(run: run, key: "enableAnimations", required: "true")
        }
        let mustNotBeTrue: [(String, Bool?)] = [
            ("fmTextVisibilityCheck", doc.fmTextVisibilityCheck),
            ("ocrTextVisibilityCheck", doc.ocrTextVisibilityCheck),
            ("screenLooksLike", doc.screenLooksLike),
            ("record", doc.record),
        ]
        for (key, value) in mustNotBeTrue where value == true {
            throw ProfileError.responseMeasurementConflict(run: run, key: key, required: "false")
        }
    }
}
