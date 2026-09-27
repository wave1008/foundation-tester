// RunDeviceMachineAmbiguity.swift
// `run --device <name>` は名前でしか絞れないが、一意なのは (machine, name)。フリートでは
// 同じ名前のデバイスが手元とリモート機に並ぶのが普通なので、`--runner`/`--device-machine`/
// `--all-machines` のどれも無いまま --device の名前が2つ以上の機械に当たると、利用者は
// 「手元の1台で試す」つもりでも全機械が回る(黙って全台を掴む点は findDevice の `.ambiguous`
// と同じ問題)。**判定はここ1箇所・`fleetest run`/`fleetest api run` はこれを呼ぶだけ**
// (RunDeviceMachineAmbiguityWiringTests がソース走査で固定)。
//
// マシン別サブ実行(DeviceMachineRunner.childArgs / ApiRunMachineFanout.buildArgs)の子は
// 常に --runner と --device-machine の両方を伴って起こされるので、rejectionMessage はここへは
// 到達しない(子が自分自身をもう一度断ることは無い)。

import FTCore

enum RunDeviceMachineAmbiguity {
    struct Ambiguity: Equatable {
        let name: String
        /// display 済み(ローカルは "local")。初出順
        let machines: [String]
    }

    /// `deviceNames` のうち、`devices` の中で2つ以上の機械に居るものだけを要求順で返す。
    /// 名前が見つからない/1機だけのものは含めない(「見つからない」の扱いは既存の
    /// 「device not found」判定に任せる)
    static func ambiguousNames(deviceNames: [String], devices: [RunDeviceMachine]) -> [Ambiguity] {
        deviceNames.compactMap { name in
            let matching = devices.filter { $0.name == name }
            let grouped = DeviceMachineGrouping.groups(matching) { MachineDispatch.normalize($0.machine) }
            guard grouped.count > 1 else { return nil }
            return Ambiguity(name: name, machines: grouped.map { DeviceMachineGrouping.display($0.machine) })
        }
    }

    /// 断る条件をまとめた入口(run/api run はここだけ呼ぶ)。nil = 断らない。
    /// **`--runner`/`--device-machine`/`--all-machines` のどれか1つでもあれば断らない**
    /// (利用者・マシン別サブ実行のどちらかが機械を既に決めている)
    static func rejectionMessage(
        deviceNames: [String], runner: String?, deviceMachine: String?, allMachines: Bool,
        devices: [RunDeviceMachine]
    ) -> String? {
        guard !deviceNames.isEmpty, runner == nil, deviceMachine == nil, !allMachines else { return nil }
        let ambiguities = ambiguousNames(deviceNames: deviceNames, devices: devices)
        guard !ambiguities.isEmpty else { return nil }
        return message(ambiguities)
    }

    /// 貼って撃てる3つの道を示す(--runner local / --runner <machine> / --all-machines)
    static func message(_ ambiguities: [Ambiguity]) -> String {
        ambiguities.map {
            "\($0.name) exists on more than one machine (\($0.machines.joined(separator: ", ")))"
                + " — pass --runner local to run it on only this Mac, --runner <machine> to run it"
                + " on only that machine, or --all-machines to run it on every one of them"
                + " (the previous behavior)"
        }.joined(separator: "\n")
    }

    /// `--all-machines`(全機械で)と `--runner`/`--device-machine`(1機に絞る)は意味が矛盾する。
    /// 引数だけで決まる(validate() 向け)
    static func allMachinesConflictMessage(
        allMachines: Bool, runner: String?, deviceMachine: String?
    ) -> String? {
        guard allMachines else { return nil }
        if runner != nil {
            return "--all-machines cannot be combined with --runner (--all-machines means every"
                + " machine a --device name matches; --runner restricts the run to one)"
        }
        if deviceMachine != nil {
            return "--all-machines cannot be combined with --device-machine (--all-machines means"
                + " every machine a --device name matches; --device-machine restricts the run to one)"
        }
        return nil
    }
}
