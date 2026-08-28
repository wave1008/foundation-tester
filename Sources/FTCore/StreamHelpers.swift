// StreamHelpers.swift
// **モニターのタイルへ画面を流すヘルパーの名前の唯一の定義元**。
//
// 同期相手は2つで、**片方だけ変えない**:
//   - `RemoteSetupPlan.alignRevisionCommand` … リモート機のクローンでこれを建てる
//   - `Sources/fleetest/ApiDeviceStreamCommand.swift` … その機械で該当ヘルパーへ `execv` で化ける
//
// 建っていないヘルパーへ化けようとすると `api device-stream` は即死し、拡張はそのタイルを
// 「映像なし」にして諦める(2026-08-28: ランナー機の版合わせが `--product fleetest` しか
// 建てておらず、リモートのタイルが1枚も映らなかった)。

public enum StreamHelpers {
    /// iOS シミュレータ(CoreSimulator 私有 API で IOSurface を読む)
    public static let simstream = "fleetest-simstream"
    /// Android 実機/エミュレータ(adb screenrecord)
    public static let androidstream = "fleetest-androidstream"
    /// 実機(スクリーンショットのポーリング。iOS/Android 共通)
    public static let devicepoll = "fleetest-devicepoll"

    /// リモート機に建っていなければならない全部。`swift build --product <名>` にそのまま渡せる
    /// (executable target は暗黙 product として解決される)
    public static let all = [simstream, androidstream, devicepoll]
}
