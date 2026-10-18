// レスポンス計測モード(RunProfileDocument.responseMeasurement)の検査。純粋関数。
// 呼び手は ProfileResolver.resolve の1箇所(`fleetest run --profile` と `fleetest api run --profile` が共有)。
// 強制値(アニメーション ON・FM/OCR/録画 OFF)は DeviceIndependentRunSettings.resolve が持つ。
public enum ResponseMeasurementPolicy {

    /// 計測は 1 台ずつ順に回すので、全台で回す・分ける・複数機械へ並べる指定とは併用できない
    public static func combinationRejection(flag: String) -> String {
        "\(flag) cannot be combined with responseMeasurement (it measures one device at a time);"
            + " remove \(flag) or turn responseMeasurement off"
    }

    /// `--set` に responseMeasurement=true があるか(プロファイルを読まずに分かる範囲)
    public static func isRequested(by overrides: [String: RunProfileSetValue]) -> Bool {
        overrides["responseMeasurement"] == .bool(true)
    }

    /// 有効なときだけ呼ぶ。`devices` は有効な(enabled)デバイスだけ
    public static func validate(_ doc: RunProfileDocument, devices: [ResolvedDevice], run: String) throws {
        guard devices.count == 1, let device = devices.first else {
            throw ProfileError.responseMeasurementDeviceCount(run: run, count: devices.count)
        }
        guard device.spec.isPhysical else {
            throw ProfileError.responseMeasurementNotPhysical(run: run, device: device.name)
        }
        guard device.platform == "android" else {
            throw ProfileError.responseMeasurementUnsupportedPlatform(
                run: run, device: device.name, platform: device.platform)
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
