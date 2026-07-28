// ProfileWriter.swift
// マシン/アプリ/実行プロファイルを**同じ論理名で揃えて**書くための純粋ロジック(`ftester profile setup`)。
// エージェントに JSON を手書きさせると、マシン側の device 名と runs 側の参照名がずれる・
// 指示していないプラットフォームの run が残る、という不整合が実際に起きた。書き手をここ1箇所にする。
//
// ファイル I/O は呼び出し側(ProfileSetupCommand)。ここは辞書 → 辞書の変換だけを扱う
// (MachineProfileEditor と同方針。ユーザーが手編集した未知キーを失わないよう JSONSerialization の
// [String: Any] を直接編集し、Codable の往復はしない)。

import Foundation

public enum ProfileWriter {

    /// プラットフォームごとの既定デバイス論理名(scaffold の runs 雛形と対。片方だけ変えない)
    public static func defaultDeviceName(platform: String) -> String {
        platform == "android" ? "emulator1" : "simulator1"
    }

    /// マシンプロファイルへデバイスを upsert する(同名があれば置換・無ければ追加)。
    /// 同名が**別プラットフォーム**に居る場合は名前の一意性が崩れるので置換せず throw する。
    public static func upsertingDevice(
        inProfileObject object: [String: Any], platform: String, device: [String: Any]
    ) throws -> [String: Any] {
        guard let name = device["name"] as? String else {
            return try MachineProfileEditor.addingDevice(
                toProfileObject: object, platform: platform, device: device)
        }
        let other = platform == "ios" ? "android" : "ios"
        if let section = object[other] as? [String: Any],
           let devices = section["devices"] as? [[String: Any]],
           devices.contains(where: { ($0["name"] as? String) == name }) {
            throw MachineProfileEditorError.duplicateDeviceName(name)
        }

        var object = object
        var section = (object[platform] as? [String: Any]) ?? [:]
        var devices = (section["devices"] as? [[String: Any]]) ?? []
        if let index = devices.firstIndex(where: { ($0["name"] as? String) == name }) {
            devices[index] = device      // 同じ論理名は上書き(再実行しても増えない)
        } else {
            devices.append(device)
        }
        section["devices"] = devices
        object[platform] = section
        return object
    }

    /// アプリプロファイルをマージする。フィールドの置き場所は固定(AppProfileSection.merging):
    /// appName/autoInstall は common、app(ID)と appPath は platform セクション。
    /// 既存の未知キーは温存し、指定した値だけを上書きする。
    public static func mergingAppProfile(
        into object: [String: Any], platform: String,
        appName: String, appID: String, appPath: String?
    ) -> [String: Any] {
        var object = object
        var common = (object["common"] as? [String: Any]) ?? [:]
        common["appName"] = appName
        // appPath が無ければ自動インストールできない(インストール済みアプリを使う)
        common["autoInstall"] = appPath != nil
        object["common"] = common

        var section = (object[platform] as? [String: Any]) ?? [:]
        section["app"] = appID
        if let appPath {
            section["appPath"] = appPath
        } else {
            section.removeValue(forKey: "appPath")
        }
        object[platform] = section
        return object
    }

    /// 実行プロファイル。devices はマシンプロファイル側の論理名をそのまま参照する
    /// (この一致が崩れると ProfileResolver が「デバイスが見つかりません」で落ちる)
    public static func runProfile(appRef: String, deviceNames: [String]) -> [String: Any] {
        [
            "app": appRef,
            "devices": deviceNames.map { ["name": $0] },
            "heal": false,
            "reportDir": "reports",
        ]
    }

    /// 人が読む前提のファイルなので、キー順を固定して整形する(差分が安定する)
    public static func json(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
