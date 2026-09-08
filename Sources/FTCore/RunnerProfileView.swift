// RunnerProfileView.swift
// **ランナー機へ送るプロファイルの姿**。用語の定義(2026-08-26 ユーザー決定):
//   host    = ホスト名 / IP アドレス(ネットワーク上の実体)
//   machine = その host に対する**ローカルエイリアス**(このマシンの登録簿だけが知る名前)
// エイリアスは発行側のローカル概念なので、**リモートへ出してはいけない**。
//
// ところがプロファイルは「どの機械の台か」を machine で書くため、そのまま転送すると
// ランナー機のディスクに M1Ultra 等が残り、子プロセスにも `--device-machine M1Ultra` として渡っていた。
// ここでは転送前に**そのランナーから見た姿**へ畳む:
//   - そのランナー(alias)に居る台は machine を "local" に書き換える(向こうでは実際に手元)
//   - 他の機械の台は落とす(そのランナーが動かすことは無い。エイリアスも一緒に消える)
//   - プロファイル直下の既定 machine も落とす(全台が local になったので意味を持たない)
// これで転送物・引数のどちらにもエイリアスが出ない。子は従来どおり `--host local` で走る。
//
// **注記の無い台を alias の台とみなす推定(`wholeProfile`)は、プロジェクト単位で入り切りする** ——
// 呼び手は `isMachineAnnotated` でプロジェクト内の全マシンプロファイルを見て、
// **1台でも実効マシンを持つ台があれば `projectIsMachineAnnotated: true`** を渡す。
//   - 注記済みプロジェクトで推定を働かせない理由: 発行側の全台 `"machine": "local"` の台帳が
//     丸ごと転送され、ランナー機の台として再スタンプされる(実在する台と id が衝突して監視から落ちる)。
//   - **明示 `local` を単独で落とす形にはできない**理由: `ProfileSetupCommand.deviceEntry` が
//     必ず `"host": "local"` を書くので、台帳1枚だけの受け手が丸ごと 0 台に畳まれ、向こうで
//     「none of the devices referenced by run profile … exist in machine profile」になる。
// FTRemote.RemoteDispatchDeviceScope の `.wholeProfile` は**実行プロファイル1枚だけ**で決める判定で、
// ここの推定とは範囲が違う(機械を明示した台帳が同居するプロジェクトでは両者は一致しない)。
//
// 未知キーは温存する(利用者が手で足したキーを消さない。MachineProfileEditor と同じ規律)。

import Foundation

public enum RunnerProfileView {

    private static let platformKeys = ["ios", "android"]
    /// 手元を表す予約名(FTCore.DeviceMachineGrouping.localDisplayName と同じ値)
    private static let localName = DeviceMachineGrouping.localDisplayName

    /// デバイス1件の実効マシン(デバイス指定 > 直下の既定 > 手元)。**旧キー "host" も読む**
    /// (改名の互換。DeviceSpec.init(from:) と同じ規律)
    static func effectiveMachine(device: [String: Any], profileDefault: String?) -> String? {
        let raw = (device["machine"] ?? device["host"]) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed == localName ? nil : trimmed
        }
        return profileDefault
    }

    /// プロファイル直下の既定マシン(旧キー "host" も読む。"local" と空は「既定なし」)
    private static func profileDefaultMachine(_ object: [String: Any]) -> String? {
        ((object["machine"] ?? object["host"]) as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0 == localName ? nil : $0 }
    }

    private static func devices(_ object: [String: Any]) -> [[String: Any]] {
        platformKeys.flatMap { ((object[$0] as? [String: Any])?["devices"] as? [[String: Any]]) ?? [] }
    }

    /// プロジェクト内の**全マシンプロファイル**を見て「機械を明示している台が1台でもあるか」。
    /// 真なら localize は注記の無い台を alias の台とみなす推定を働かせない(ファイル冒頭)。
    /// プラットフォームを跨いで見る(android 側の注記だけでも注記済み)
    public static func isMachineAnnotated(machineProfiles: [[String: Any]]) -> Bool {
        machineProfiles.contains { object in
            let profileDefault = profileDefaultMachine(object)
            return devices(object).contains { effectiveMachine(device: $0, profileDefault: profileDefault) != nil }
        }
    }

    /// マシンプロファイルを alias のランナーから見た姿へ畳む。
    /// 返り値の devices は **alias の台だけ**で、その machine は "local"。
    /// `projectIsMachineAnnotated` が偽で全台が machine 未指定("local" 含む)のときだけ、
    /// 全台を alias の台として残す(ファイル冒頭)。**既定値は置かない** ——
    /// 呼び忘れをコンパイルで止めるため
    public static func localizeMachineProfile(_ object: [String: Any], alias: String,
                                              projectIsMachineAnnotated: Bool) -> [String: Any] {
        var result = object
        let profileDefault = profileDefaultMachine(object)
        let wholeProfile = !projectIsMachineAnnotated && devices(object)
            .allSatisfy { effectiveMachine(device: $0, profileDefault: profileDefault) == nil }
        // 直下の既定は畳んだ後には意味を持たない(全台が local)
        result["machine"] = nil
        result["host"] = nil
        for key in platformKeys {
            guard var section = result[key] as? [String: Any],
                  let devices = section["devices"] as? [[String: Any]] else { continue }
            section["devices"] = devices.compactMap { device -> [String: Any]? in
                guard wholeProfile
                        || effectiveMachine(device: device, profileDefault: profileDefault) == alias else {
                    return nil
                }
                var localized = device
                localized["host"] = nil          // 旧キーが残っていても持ち込まない
                localized["machine"] = localName
                return localized
            }
            result[key] = section
        }
        return result
    }

    /// 実行プロファイルを alias のランナーから見た姿へ畳む。**machine(マシンプロファイル名)は
    /// 触らない** —— あれは機械の別名ではなくプロファイルのファイル名で、向こうでも同じものを引く。
    /// 畳むのは devices[] の参照だけ(alias のものを "local" に、他機のものを落とす)。
    /// **マシン指定の無い参照は残す** —— 名前だけの参照は、畳んだ後のマシンプロファイルに
    /// 残った1台へ解決する(元から曖昧な参照は向こうで同じように曖昧だと報告される)。
    /// `projectIsMachineAnnotated` はマシンプロファイル側と**同じ値を渡す** —— 台帳が空へ畳まれるのに
    /// `"local"` 参照だけ残ると、向こうで解決できない参照になる
    public static func localizeRunProfile(_ object: [String: Any], alias: String,
                                          projectIsMachineAnnotated: Bool) -> [String: Any] {
        var result = object
        guard let devices = result["devices"] as? [[String: Any]] else { return result }
        let wholeProfile = !projectIsMachineAnnotated
            && devices.allSatisfy { effectiveMachine(device: $0, profileDefault: nil) == nil }
        result["devices"] = devices.compactMap { ref -> [String: Any]? in
            let raw = (ref["machine"] ?? ref["host"]) as? String
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            var localized = ref
            localized["host"] = nil
            guard let trimmed, !trimmed.isEmpty else { return localized }  // 名前だけの参照は残す
            if trimmed == alias || wholeProfile {
                localized["machine"] = localName
                return localized
            }
            return nil  // 発行側の手元("local")も他機の台も、そのランナーでは走らない
        }
        return result
    }
}
