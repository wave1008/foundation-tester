// RunProfileDeviceEditor.swift
// 実行プロファイル(profiles/runs/<name>.json)の devices[] を編集する純粋ロジック。
// fleetest api create-device / profile setup が使う。ファイル I/O(読み込み・書き戻し)は呼び出し側の
// 責務とし、ここでは辞書の変換だけを扱う(テスト容易性のため。HealFixApplier と同方針)。
//
// プロファイルの JSON はユーザーが直接編集するファイルであり、Codable が知らない未知キーが
// 含まれ得る。Codable でデコード→再エンコードすると未知キーが失われるため、
// ここでは JSONSerialization の [String: Any] を直接編集する。
// devices[] 1要素の形は FTCore.RunDeviceEntry(平ら: platform / machine / name / enabled / 実体キー)。

import Foundation

/// RunProfileDeviceEditor の失敗
public enum RunProfileDeviceEditorError: Error, LocalizedError {
    case duplicateDeviceName(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateDeviceName(let name):
            return "duplicate device name: \(name) (names must be unique per machine, across ios and android)"
        }
    }
}

public enum RunProfileDeviceEditor {

    private static func devices(_ object: [String: Any]) -> [[String: Any]] {
        (object["devices"] as? [[String: Any]]) ?? []
    }

    /// 1要素の実効マシン(nil = 手元)。規則は MachineDispatch.normalize と同じ
    static func effectiveMachine(of device: [String: Any]) -> String? {
        MachineDispatch.normalize((device["machine"] ?? device["host"]) as? String)
    }

    /// devices[] に device(platform・machine・name を含む1要素)を末尾へ追加した新しい辞書を返す。
    /// 既存の未知キーは触れずに保持する。**同じ機械の**既存名と重複していれば duplicateDeviceName を
    /// throw する(platform を跨いで一意。**別の機械の同名は重複ではない** —— 各機が同じ命名規則で
    /// シミュレータを作るので同名が普通。FTCore.DeviceMachineGrouping)
    public static func addingDevice(
        toRunProfileObject object: [String: Any], device: [String: Any]
    ) throws -> [String: Any] {
        var list = devices(object)
        if let name = device["name"] as? String {
            let machine = effectiveMachine(of: device)
            if list.contains(where: { ($0["name"] as? String) == name && effectiveMachine(of: $0) == machine }) {
                throw RunProfileDeviceEditorError.duplicateDeviceName(name)
            }
        }
        var object = object
        list.append(device)
        object["devices"] = list
        return object
    }

    /// 同じ (machine, name) があれば置換、無ければ追加する(再実行しても増えない)。
    /// 置換は**同じ platform のときだけ** —— 別 platform の同名は一意性が崩れるので throw する。
    /// 置換時も元の enabled は保つ(再セットアップでチェックを勝手に戻さない)
    public static func upsertingDevice(
        inRunProfileObject object: [String: Any], device: [String: Any]
    ) throws -> [String: Any] {
        guard let name = device["name"] as? String else {
            return try addingDevice(toRunProfileObject: object, device: device)
        }
        let machine = effectiveMachine(of: device)
        var list = devices(object)
        guard let index = list.firstIndex(where: {
            ($0["name"] as? String) == name && effectiveMachine(of: $0) == machine
        }) else {
            return try addingDevice(toRunProfileObject: object, device: device)
        }
        guard (list[index]["platform"] as? String) == (device["platform"] as? String) else {
            throw RunProfileDeviceEditorError.duplicateDeviceName(name)
        }
        var replaced = device
        if replaced["enabled"] == nil, let enabled = list[index]["enabled"] {
            replaced["enabled"] = enabled
        }
        list[index] = replaced
        var object = object
        object["devices"] = list
        return object
    }

    /// **手元のデバイス名だけ**(実効マシンが nil のもの)。api create-device は手元にしか
    /// 実体を作らないので、重複判定の相手はこれ(別マシンの同名は重複ではない)
    public static func localDeviceNames(inRunProfileObject object: [String: Any]) -> [String] {
        devices(object).compactMap { device in
            effectiveMachine(of: device) == nil ? device["name"] as? String : nil
        }
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
