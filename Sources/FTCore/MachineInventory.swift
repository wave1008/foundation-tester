// MachineInventory.swift
// **実行プロファイルを選んでいないときの監視対象**(拡張の「(プロファイルなし)」)を決める。
//
// マシンプロファイルは「この Mac に何が登録されているか」の台帳で、**1つのプロジェクトに複数
// 置ける**(構成の使い分け。例: 手元だけの台帳と、ランナーも含む台帳)。実行プロファイルを
// 選んでいれば台帳は一意に決まるが、選んでいないときは決められない —— 以前はそこで諦めて
// 「今動いている台」だけを見ていたため、**台帳が2つある案件では1台も出なかった**
// (実害 2026-08-28。全台が「マシンプロファイル未記載」扱いになり、拡張の表示フィルタが落とした)。
//
// 決め方は「どれか1つを選ぶ」ではなく **全部の台帳を畳んで、観測できるマシンの台だけ残す**:
//   - **観測できるマシン = 手元 + リモート実行の登録簿にあるマシン**(設定タブのホスト表。
//     ユーザー決定 2026-08-29)。登録簿に無いマシンの台は、監視の fan-out が張られないので
//     状態が永久に "unknown" のタイルになるだけ = 出す意味が無い
//   - 重複((platform, machine, name)が同じ)は**最初の1件**。台帳をまたいで同じ台を書くのは
//     普通(手元の台は両方の台帳に居る)なので、重複はエラーではない。**入力の順序で決まる**ので
//     呼び出し側はファイル名順など安定した順で渡すこと
//
// **I/O は loadAll だけ**(残りは純粋関数)。テストは Tests/FleetestTests/MachineInventoryTests.swift。

import Foundation

public enum MachineInventory {

    /// machines/ の全マシンプロファイル。**ファイル名順**(下の重複解決が入力順で決まるので、
    /// 走査順で結果が揺れないようにする)。壊れた JSON は警告して飛ばす —— 実行プロファイルを
    /// 選んでいないときは「見えるものを見せる」経路なので、1枚の壊れた台帳で全部を止めない
    /// (選んでいるときは従来どおり decodeFailed で落ちる)。
    /// **ここだけが I/O** —— 下の2つは純粋関数
    public static func loadAll(project: TestProject, warn: (String) -> Void) -> [MachineProfile] {
        ProfileResolver.machineNames(project: project).sorted().compactMap { name in
            let url = project.machinesDir.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: url),
                  let profile = try? JSONDecoder().decode(MachineProfile.self, from: data) else {
                warn("skipping machine profile \(name): it cannot be read")
                return nil
            }
            return profile
        }
    }

    /// 畳んだカタログを1つのマシンプロファイルの姿へ戻す(`machine` は各デバイスに焼き込み済み
    /// なので既定は持たない)。**既存の (machine, name) 解決をそのまま使うため** ——
    /// 探索の規律を2つ持たない(ApiDeviceOperation.findDevice / RunProfileScope と同じ入力にする)
    public static func mergedProfile(_ entries: [DeviceMachineGrouping.CatalogEntry]) -> MachineProfile {
        MachineProfile(
            machine: nil,
            ios: MachineDeviceList(devices: entries.filter { $0.platform == "ios" }.map(\.spec)),
            android: MachineDeviceList(devices: entries.filter { $0.platform == "android" }.map(\.spec)))
    }

    /// 複数のマシンプロファイルを1つのカタログへ畳む。`registry` はリモート実行の登録簿の
    /// マシン名(手元は登録簿に載らないので常に残す)。並びは渡された台帳の順 → その中は
    /// ios → android(DeviceMachineGrouping.entries と同じ)。
    public static func observableEntries(
        profiles: [MachineProfile],
        registry: [String]
    ) -> [DeviceMachineGrouping.CatalogEntry] {
        let registered = Set(registry.compactMap { MachineDispatch.normalize($0) })
        var result: [DeviceMachineGrouping.CatalogEntry] = []
        var seen = Set<String>()
        for profile in profiles {
            for entry in DeviceMachineGrouping.entries(machine: profile) {
                // entries() が実効マシンを spec へ焼き込んである(nil = 手元)
                if let machine = entry.machine, !registered.contains(machine) {
                    continue
                }
                // マシン名にタブは現れない(登録名は ssh 宛先ではなく識別子)ので区切りに使える
                let key = "\(entry.platform)\t\(DeviceMachineGrouping.display(entry.machine))\t\(entry.name)"
                guard seen.insert(key).inserted else { continue }
                result.append(entry)
            }
        }
        return result
    }
}
