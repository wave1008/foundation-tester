// RunnerProfileView.swift
// **ランナー機へ送るプロファイルの姿**。用語の定義(ユーザー決定):
//   host    = ホスト名 / IP アドレス(ネットワーク上の実体)
//   machine = その host に対する**ローカルエイリアス**(このマシンの登録簿だけが知る名前)
// エイリアスは発行側のローカル概念なので、**リモートへ出してはいけない**。
//
// ところがプロファイルは「どの機械の台か」を machine で書くため、そのまま転送すると
// ランナー機のディスクに M1Ultra 等が残り、子プロセスにも `--device-machine M1Ultra` として渡っていた。
// ここでは転送前に**そのランナーから見た姿**へ畳む(実行プロファイルの devices[]):
//   - そのランナー(alias)に居る台は machine を "local" に書き換える(向こうでは実際に手元)
//   - 他の機械の台は落とす(そのランナーが動かすことは無い。エイリアスも一緒に消える)
// これで転送物・引数のどちらにもエイリアスが出ない。子は `--host local` で走る。
//
// **注記の無い台を alias の台とみなす推定(`wholeProfile`)は、プロジェクト単位で入り切りする** ——
// 呼び手は `isMachineAnnotated` でプロジェクト内の全実行プロファイルを見て、
// **1台でも実効マシンを持つ台があれば `projectIsMachineAnnotated: true`** を渡す。
//   - 注記済みプロジェクトで推定を働かせない理由: 発行側の全台 `"machine": "local"` のプロファイルが
//     丸ごと転送され、ランナー機の台として再スタンプされる(実在する台と id が衝突して監視から落ちる)。
//   - **明示 `local` を単独で落とす形にはできない**理由: `ProfileSetupCommand` が
//     必ず `"machine": "local"` を書くので、手元の台だけの受け手が丸ごと 0 台に畳まれる。
// FTRemote.RemoteDispatchDeviceScope の `.wholeProfile` は**実行プロファイル1枚だけ**で決める判定で、
// ここの推定とは範囲が違う(機械を明示したプロファイルが同居するプロジェクトでは両者は一致しない)。
//
// 未知キーは温存する(利用者が手で足したキーを消さない。RunProfileDeviceEditor と同じ規律)。

import Foundation

public enum RunnerProfileView {

    /// 手元を表す予約名(FTCore.DeviceMachineGrouping.localDisplayName と同じ値)
    private static let localName = DeviceMachineGrouping.localDisplayName

    /// デバイス1件の実効マシン(nil = 手元)
    static func effectiveMachine(device: [String: Any]) -> String? {
        MachineDispatch.normalize(device["machine"] as? String)
    }

    private static func devices(_ object: [String: Any]) -> [[String: Any]] {
        (object["devices"] as? [[String: Any]]) ?? []
    }

    /// プロジェクト内の**全実行プロファイル**を見て「機械を明示している台が1台でもあるか」。
    /// 真なら localize は注記の無い台を alias の台とみなす推定を働かせない(ファイル冒頭)
    public static func isMachineAnnotated(runProfiles: [[String: Any]]) -> Bool {
        runProfiles.contains { object in
            devices(object).contains { effectiveMachine(device: $0) != nil }
        }
    }

    /// 実行プロファイルを alias のランナーから見た姿へ畳む。
    /// 返り値の devices は **alias の台だけ**で、その machine は "local"。
    /// `projectIsMachineAnnotated` が偽で全台が手元のときだけ、全台を alias の台として残す
    /// (ファイル冒頭)。**既定値は置かない** —— 呼び忘れをコンパイルで止めるため
    public static func localizeRunProfile(_ object: [String: Any], alias: String,
                                          projectIsMachineAnnotated: Bool) -> [String: Any] {
        var result = object
        guard let list = object["devices"] as? [[String: Any]] else { return result }
        let wholeProfile = !projectIsMachineAnnotated
            && list.allSatisfy { effectiveMachine(device: $0) == nil }
        result["devices"] = list.compactMap { device -> [String: Any]? in
            guard wholeProfile || effectiveMachine(device: device) == alias else {
                return nil  // 発行側の手元("local")も他機の台も、そのランナーでは走らない
            }
            var localized = device
            localized["machine"] = localName
            return localized
        }
        return result
    }
}
