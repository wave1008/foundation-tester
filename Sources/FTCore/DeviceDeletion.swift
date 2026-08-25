// DeviceDeletion.swift
// シミュレータ/AVD の実体削除(fleetest api delete-device)の純粋ロジック。
// コマンド組み立て・入口検証・起動中/不存在の拒否判定・マシンプロファイル参照の洗い出しを
// ここへ集約し、ファイル I/O(simctl/avdmanager 実行・プロファイル読み込み・起動中判定の実照会)は
// 呼び出し側(Sources/fleetest/ApiDeleteDeviceCommand.swift)に置く(MachineProfileEditor と同方針)。

import Foundation

public enum DeviceDeletionError: Error, LocalizedError, Equatable {
    case invalidUDID(String)
    case invalidAVDName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUDID(let raw):
            return "not a valid simulator UDID (expected e.g. 12345678-1234-1234-1234-123456789012): \(raw)"
        case .invalidAVDName(let raw):
            return "not a valid AVD id (letters, digits, and . _ - only, non-empty): \(raw)"
        }
    }
}

public enum DeviceDeletion {

    /// iOS シミュレータ UDID の形(8-4-4-4-12 桁の16進・ハイフン区切り)。
    /// シェルへ渡す前にここで弾く(RemoteLayout.validateBase と同じ規律)
    public static func validateIOSUDID(_ raw: String) throws {
        let pattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        guard raw.range(of: pattern, options: .regularExpression) != nil else {
            throw DeviceDeletionError.invalidUDID(raw)
        }
    }

    /// avdmanager -n が受ける文字種(MachineProfileEditor.sanitizedAVDID の許可集合と同じ)。空文字も拒否
    public static func validateAndroidAVDName(_ raw: String) throws {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !raw.isEmpty, raw.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DeviceDeletionError.invalidAVDName(raw)
        }
    }

    /// `xcrun simctl delete <udid>`(完全一致で固定。実行時は先頭要素をそのまま渡せる)
    public static func iosCommand(udid: String) -> [String] {
        ["xcrun", "simctl", "delete", udid]
    }

    /// `avdmanager delete avd -n <avd>`(完全一致で固定。先頭要素は論理名 —
    /// 実行時は呼び出し側が AndroidSDKLocator.findAVDManager() で解決した絶対パスに差し替える。
    /// create-device の runAVDManagerCreate と同じ分担)
    public static func androidCommand(avd: String) -> [String] {
        ["avdmanager", "delete", "avd", "-n", avd]
    }

    /// 起動中/不存在を理由に削除を拒否するときの文言。両方 false なら削除してよい(nil)。
    /// isRunning を exists より先に見る —— 走っている run を巻き添えにしないことが最優先のため。
    ///
    /// **判定は共有・末尾の一手だけ呼び手が決める**(`then:`)。削除コマンドなら "delete it"、
    /// 作り直し(create --overwrite)なら "create it again" —— 共有された文言をそのまま流用すると、
    /// 上書きしようとした人に「then delete it」と言うことになる(2026-08-17 に実際に出た)
    public static func refusalReason(isRunning: Bool, exists: Bool,
                                     then: String = "delete it") -> String? {
        if isRunning {
            return "the device is currently running — stop it first (fleetest devices down, "
                + "or the monitor), then \(then)"
        }
        if !exists {
            return "no such simulator/AVD (it may already be deleted)"
        }
        return nil
    }

    /// identifier(iOS udid / Android avd id)を参照しているマシンプロファイル名の一覧
    /// (machineProfiles の登場順)。削除そのものは止めず、呼び出し側が「宙ぶらりんのエントリが
    /// 残る」ことを利用者へ伝えるための情報提供のみに使う
    public static func referencedBy(
        machineProfiles: [(name: String, profile: MachineProfile)], identifier: String
    ) -> [String] {
        machineProfiles.filter { _, profile in
            let iosMatch = (profile.ios?.devices ?? []).contains { $0.udid == identifier }
            let androidMatch = (profile.android?.devices ?? []).contains { $0.avd == identifier }
            return iosMatch || androidMatch
        }.map(\.name)
    }
}
