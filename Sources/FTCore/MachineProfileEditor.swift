// MachineProfileEditor.swift
// マシンプロファイル(profiles/machines/<マシン名>.json)へ新規デバイスを追記する純粋ロジック。
// ftester api create-device が使う。ファイル I/O(読み込み・書き戻し)は呼び出し側の責務とし、
// ここではソース文字列/辞書の変換だけを扱う(テスト容易性のため。HealFixApplier と同方針)。
//
// プロファイルの JSON はユーザーが直接編集するファイルであり、DeviceSpec(Codable)が知らない
// 未知キーが含まれ得る。Codable でデコード→再エンコードすると未知キーが失われるため、
// ここでは JSONSerialization の [String: Any] を直接編集する(RunProfile.swift のマシンプロファイル
// Codable 型に関するコメントと同じ設計判断)。

import Foundation

/// MachineProfileEditor.addingDevice の失敗
public enum MachineProfileEditorError: Error, LocalizedError {
    case duplicateDeviceName(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateDeviceName(let name):
            return "デバイス名が重複しています: \(name)(name は ios/android 横断で一意にしてください)"
        }
    }
}

public enum MachineProfileEditor {

    private static let platformKeys = ["ios", "android"]

    /// ios/android 両セクションの devices[].name を列挙する(型が合わない要素は黙ってスキップする。
    /// プロファイルは手編集され得るため、壊れた要素があってもクラッシュせず続行する方針)
    public static func deviceNames(inProfileObject object: [String: Any]) -> [String] {
        var names: [String] = []
        for key in platformKeys {
            guard let section = object[key] as? [String: Any],
                  let devices = section["devices"] as? [[String: Any]] else { continue }
            for device in devices {
                if let name = device["name"] as? String {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// platform("ios"/"android")のセクションへ device を追加した新しい辞書を返す。
    /// セクションや devices 配列が無ければ作る。既存の未知キー(トップレベル・セクション内とも)は
    /// 触れずに保持する(このセクション以外/devices 以外のキーには一切書き込まないため)。
    /// device["name"] が ios/android 横断で既存名と重複していれば
    /// duplicateDeviceName を throw する(name が String でない/無い場合は重複チェックをスキップする)
    public static func addingDevice(
        toProfileObject object: [String: Any], platform: String, device: [String: Any]
    ) throws -> [String: Any] {
        if let name = device["name"] as? String {
            let existingNames = Set(deviceNames(inProfileObject: object))
            guard !existingNames.contains(name) else {
                throw MachineProfileEditorError.duplicateDeviceName(name)
            }
        }
        var object = object
        var section = (object[platform] as? [String: Any]) ?? [:]
        var devices = (section["devices"] as? [[String: Any]]) ?? []
        devices.append(device)
        section["devices"] = devices
        object[platform] = section
        return object
    }

    /// AVD ID として使える文字([A-Za-z0-9._-])以外を "_" に置換し、連続する "_"
    /// (置換由来・元から "_" だったもの問わず)は 1 つに圧縮、先頭・末尾の "_" は除去する。
    /// 結果が空なら "avd" を返す(avdmanager の -n が空文字を受け付けないため)
    public static func sanitizedAVDID(from name: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var result = ""
        var lastWasUnderscore = false
        for scalar in name.unicodeScalars {
            let mapped: Unicode.Scalar = allowed.contains(scalar) ? scalar : "_"
            if mapped == "_" {
                if !lastWasUnderscore { result.append("_") }
                lastWasUnderscore = true
            } else {
                result.unicodeScalars.append(mapped)
                lastWasUnderscore = false
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "avd" : trimmed
    }

    /// Android API レベル → バージョン表示名("Android 10" 等)。
    /// 21 未満(テーブル外の旧バージョン)は "API <レベル>" とする
    public static func androidVersionName(apiLevel: Int) -> String {
        if apiLevel < 21 { return "API \(apiLevel)" }
        // 21〜32 は数値どおりに 1 対 1 対応しないため(5.0/5.1, 7/7.1, 12/12L 等)テーブル化する
        let table: [Int: String] = [
            21: "5.0", 22: "5.1", 23: "6", 24: "7", 25: "7.1", 26: "8", 27: "8.1",
            28: "9", 29: "10", 30: "11", 31: "12", 32: "12L",
        ]
        if let version = table[apiLevel] { return "Android \(version)" }
        // 33 以降は apiLevel - 20 がそのままメジャーバージョン(33→13, 37→17 等)
        return "Android \(apiLevel - 20)"
    }
}
