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

    /// マシンプロファイルを alias のランナーから見た姿へ畳む。
    /// 返り値の devices は **alias の台だけ**で、その machine は "local"。
    public static func localizeMachineProfile(_ object: [String: Any], alias: String) -> [String: Any] {
        var result = object
        let rawDefault = (object["machine"] ?? object["host"]) as? String
        let profileDefault = rawDefault
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0 == localName ? nil : $0 }
        // 直下の既定は畳んだ後には意味を持たない(全台が local)
        result["machine"] = nil
        result["host"] = nil
        for key in platformKeys {
            guard var section = result[key] as? [String: Any],
                  let devices = section["devices"] as? [[String: Any]] else { continue }
            section["devices"] = devices.compactMap { device -> [String: Any]? in
                guard effectiveMachine(device: device, profileDefault: profileDefault) == alias else {
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
    /// 残った1台へ解決する(元から曖昧な参照は向こうで同じように曖昧だと報告される)
    public static func localizeRunProfile(_ object: [String: Any], alias: String) -> [String: Any] {
        var result = object
        guard let devices = result["devices"] as? [[String: Any]] else { return result }
        result["devices"] = devices.compactMap { ref -> [String: Any]? in
            let raw = (ref["machine"] ?? ref["host"]) as? String
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            var localized = ref
            localized["host"] = nil
            guard let trimmed, !trimmed.isEmpty else { return localized }  // 名前だけの参照は残す
            if trimmed == alias {
                localized["machine"] = localName
                return localized
            }
            return nil  // 発行側の手元("local")も他機の台も、そのランナーでは走らない
        }
        return result
    }
}
