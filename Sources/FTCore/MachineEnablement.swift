// MachineEnablement.swift
// 設定タブの「マシン有効」(登録簿 `remoteHosts[].enabled` と手元の `LocalConfig.localMachineEnabled`)
// から、**プロファイル駆動の振り分けで配らない機械**を決める純粋ロジック。
//
// 効かせるのは「どの機械へ配るかをツールが決める」経路だけ(DeviceMachineRunner.plan・FleetRunner)。
// **明示の `--runner` には効かせない** —— 機械分担・フリートの子は必ず `--runner <machine|local>` で
// 起こされ、ランナー機の上でも `--runner local` で走る。ここで断ると配った先で自分の run を止める。

import Foundation

public enum MachineEnablement {
    /// 無効な機械の表示名の集合(手元は `DeviceMachineGrouping.localDisplayName`)
    public static func disabledMachines(config: LocalConfig) -> Set<String> {
        var result = Set((config.remoteHosts ?? []).filter { !$0.isEnabled }.map(\.machine))
        if config.localMachineEnabled == false {
            result.insert(DeviceMachineGrouping.localDisplayName)
        }
        return result
    }

    /// 台を有効な機械のものと無効な機械のものに分ける。excluded は無効で外した機械(出現順・重複なし)
    public static func partition(
        _ devices: [RunDeviceMachine], disabled: Set<String>
    ) -> (kept: [RunDeviceMachine], excludedMachines: [String]) {
        var kept: [RunDeviceMachine] = []
        var excluded: [String] = []
        for device in devices {
            let label = DeviceMachineGrouping.display(device.machine)
            if disabled.contains(label) {
                if !excluded.contains(label) { excluded.append(label) }
            } else {
                kept.append(device)
            }
        }
        return (kept, excluded)
    }

    /// 無効で外した機械を知らせる1行
    public static func skippedNotice(_ machines: [String]) -> String {
        "→ Skipping disabled machine(s): \(machines.joined(separator: ", "))"
            + " (\"Machine enabled\" is off in the monitor's Settings tab)"
    }

    /// 配れる機械が1つも残らなかったときの文言
    public static func allDisabledMessage(_ machines: [String], subject: String) -> String {
        "every machine that \(subject) is disabled: \(machines.joined(separator: ", "))"
            + " — turn \"Machine enabled\" back on in the monitor's Settings tab,"
            + " or pass --runner <machine> to run there explicitly"
    }
}
