// 実行プロファイルのデバイスを「どの機械に居るか」で分類する純粋ロジック。
// **一意なのは name 単体ではなく (machine, name)** —— フリートの各機は同じ命名規則で
// シミュレータを作るため、別マシンの同名は例外ではなく通常。
//
// 用語(docs/remote-runner.md §0): machine = 登録簿のマシン名(この Mac だけのエイリアス)。
// ホスト名 / IP は host で、この型は一切扱わない。
// マシン名の正規化(nil・""・"local" → nil)は MachineDispatch.normalize が唯一の定義元。

import Foundation

/// 実行プロファイルが使うデバイス1台と、それが居る機械(nil = 手元)。
/// ディスパッチ先の決定と、マシン別サブ実行への割り当てに使う
public struct RunDeviceMachine: Equatable, Sendable {
    public let machine: String?
    public let name: String
    public let platform: String

    public init(machine: String?, name: String, platform: String) {
        self.machine = machine
        self.name = name
        self.platform = platform
    }
}

public enum DeviceMachineGrouping {
    /// 表示・エラーメッセージ用のマシン名(ローカルは "local")。ログとメッセージはこれで揃える
    public static let localDisplayName = "local"

    public static func display(_ machine: String?) -> String {
        machine ?? localDisplayName
    }

    /// ワーカー/監視タイルの識別子(手元は "<platform>:<name>"・マシンありは
    /// "<platform>:<machine>/<name>")。同名デバイスは別マシンに居るのが普通で、machine を
    /// 含めないと拡張側の Map(id が鍵)で複数台が1つに潰れる。**判定はここだけ**
    /// (ApiMonitorCommand.MonitorTarget.id / ApiRunMachineFanout が両方これを呼ぶ)。
    /// 手元の id は "<platform>:<name>" のまま変えないこと(1台構成の既存契約)
    public static func workerID(platform: String, machine: String?, name: String) -> String {
        guard let machine = MachineDispatch.normalize(machine) else { return "\(platform):\(name)" }
        return "\(platform):\(machine)/\(name)"
    }

    /// 台帳1件ぶんのデバイス。spec.machine には**実効マシン**(正規化済み。nil = 手元)が入っている
    public struct CatalogEntry: Equatable, Sendable {
        public let platform: String
        public let spec: DeviceSpec

        public init(platform: String, spec: DeviceSpec) {
            self.platform = platform
            self.spec = spec
        }

        public var machine: String? { spec.machine }
        public var name: String { spec.name }
    }

    /// 実行プロファイルの devices を平坦化する(記述順。実効マシンを spec.machine へ焼き込むので、
    /// これ以降は spec.machine だけ見ればよい)。enabledOnly = 実行対象(enabled != false)だけ
    public static func entries(runDevices: [RunDeviceEntry], enabledOnly: Bool) -> [CatalogEntry] {
        runDevices.filter { !enabledOnly || $0.isEnabled }.map { device in
            var resolved = device.spec
            resolved.machine = MachineDispatch.normalize(device.spec.machine)
            return CatalogEntry(platform: device.platform, spec: resolved)
        }
    }

    /// メモリ上の台帳を ios → android の順に平坦化する(spec.machine は正規化して焼き込む)
    public static func entries(roster: DeviceRoster) -> [CatalogEntry] {
        var result: [CatalogEntry] = []
        for (platform, list) in [("ios", roster.ios), ("android", roster.android)] {
            for spec in list?.devices ?? [] {
                var resolved = spec
                resolved.machine = MachineDispatch.normalize(spec.machine)
                result.append(CatalogEntry(platform: platform, spec: resolved))
            }
        }
        return result
    }

    /// 同じ (machine, name) が2つ以上あれば最初の1件を返す(マシンが違えば同名でも重複ではない)
    public static func firstDuplicate(in entries: [CatalogEntry]) -> CatalogEntry? {
        var seen = Set<String>()
        for entry in entries {
            // マシン名にタブは現れない(登録名は ssh 宛先ではなく識別子)ので区切りに使える
            let key = "\(display(entry.machine))\t\(entry.name)"
            if !seen.insert(key).inserted {
                return entry
            }
        }
        return nil
    }

    /// 解決済みデバイスをマシンごとに束ねる。**順序は最初に現れたマシン順**(実行の割り当てと
    /// ログの並びを入力から決まる形にする = 同じプロファイルなら毎回同じ順)
    public static func groups<T>(
        _ devices: [T], machine: (T) -> String?
    ) -> [(machine: String?, devices: [T])] {
        var order: [String] = []
        var buckets: [String: [T]] = [:]
        for device in devices {
            let key = display(machine(device))
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(device)
        }
        return order.map { key in
            (machine: key == localDisplayName ? nil : key, devices: buckets[key] ?? [])
        }
    }
}
