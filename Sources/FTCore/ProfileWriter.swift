// ProfileWriter.swift
// アプリ/実行プロファイルを書くための純粋ロジック(`fleetest profile setup`)。
// エージェントに JSON を手書きさせると、指示していないプラットフォームの run が残る等の
// 不整合が実際に起きた。書き手をここ1箇所にする。
//
// ファイル I/O は呼び出し側(ProfileSetupCommand)。ここは辞書 → 辞書の変換だけを扱う
// (RunProfileDeviceEditor と同方針。ユーザーが手編集した未知キーを失わないよう JSONSerialization の
// [String: Any] を直接編集し、Codable の往復はしない)。

import Foundation

public enum ProfileWriter {

    /// プラットフォームごとの既定デバイス論理名(scaffold の runs 雛形と対。片方だけ変えない)
    public static func defaultDeviceName(platform: String) -> String {
        platform == "android" ? "emulator1" : "simulator1"
    }

    /// デバイス「実体」を表すキー(host / name は**論理名と所在**であって実体ではない)。
    /// **キー数で実体の有無を判定しない** —— host を常に書くようになったことで
    /// `profile setup` の `device.count == 1` という番兵が恒真になり、`--auto-device` が
    /// 一度も発火しないまま実体の無い simulator1 / emulator1 が受け手のプロファイルへ
    /// 書かれた(しかも既に実体付きで登録されていた同名デバイスを実体なしで上書きした)。
    /// engine / port のような**実体を指さないキー**が増えても false のままであること
    public static let deviceBodyKeys: Set<String> = ["osVersion", "udid", "avd", "serial"]

    /// デバイスの実体(機種/OS/UDID/AVD/シリアル)が1つでも入っているか
    public static func hasDeviceBody(_ device: [String: Any]) -> Bool {
        device.keys.contains(where: deviceBodyKeys.contains)
    }

    /// アプリプロファイルをマージする。フィールドの置き場所は固定(AppProfileSection.merging):
    /// appName・app(ID)・appPath は platform セクション、autoInstall は common(こちらは触らない)。
    /// 既存の未知キーは温存し、指定した値だけを上書きする。
    public static func mergingAppProfile(
        into object: [String: Any], platform: String,
        appName: String, appID: String, appPath: String?
    ) -> [String: Any] {
        var object = object
        var section = (object[platform] as? [String: Any]) ?? [:]
        section["appName"] = appName
        section["app"] = appID
        if let appPath {
            section["appPath"] = appPath
        } else {
            section.removeValue(forKey: "appPath")
        }
        object[platform] = section
        return object
    }

    /// 新しい実行プロファイル。devices は RunDeviceEntry の形(platform / machine / name / 実体)の辞書。
    /// 既存の実行プロファイルへ台を足すときは RunProfileDeviceEditor.upsertingDevice を使う。
    /// reportDir は書かない(未指定 = 既定の reports。拡張のフォームは既定を透かしで見せる)
    public static func runProfile(appRef: String, devices: [[String: Any]]) -> [String: Any] {
        [
            "app": appRef,
            "devices": devices,
            "textVisualCheck": true,
            "heal": true,
        ]
    }

    /// 人が読む前提のファイルなので、キー順を固定して整形する(差分が安定する)。
    /// 順序の定義元は OrderedProfileJSON(platform → machine → name を先頭に出す。アルファベット順ではない)
    public static func json(_ object: [String: Any]) throws -> Data {
        try OrderedProfileJSON.data(object)
    }
}
