// マシンプロファイルのデバイスを「どの機械に居るか」で解決・分類する純粋ロジック。
// **一意なのは name 単体ではなく (host, name)** —— フリートの各機は同じ命名規則で
// シミュレータを作るため、別ホストの同名は例外ではなく通常。
//
// 実行プロファイルの参照(RunDeviceRef)は name だけでも書けるが、同名が複数ホストに居るときは
// **候補を挙げて中止する**(片方を黙って選ばない = 別の機械のデバイスを操作しない)。
// ホスト名の正規化(nil・""・"local" → nil)は MachineHostDispatch.normalize が唯一の定義元。

import Foundation

/// 実行プロファイルが使うデバイス1台と、それが居る機械(nil = 手元)。
/// ディスパッチ先の決定と、ホスト別サブ実行への割り当てに使う
public struct RunDeviceHost: Equatable, Sendable {
    public let host: String?
    public let name: String
    public let platform: String

    public init(host: String?, name: String, platform: String) {
        self.host = host
        self.name = name
        self.platform = platform
    }
}

public enum DeviceHostGrouping {
    /// 表示・エラーメッセージ用のホスト名(ローカルは "local")。ログとメッセージはこれで揃える
    public static let localDisplayName = "local"

    public static func display(_ host: String?) -> String {
        host ?? localDisplayName
    }

    /// ワーカー/監視タイルの識別子(手元は "<platform>:<name>"・ホストありは
    /// "<platform>:<host>/<name>")。同名デバイスは別ホストに居るのが普通で、host を含めないと
    /// 拡張側の Map(id が鍵)で複数台が1つに潰れる。**判定はここだけ**
    /// (ApiMonitorCommand.MonitorTarget.id / ApiRunHostFanout が両方これを呼ぶ)。
    /// 手元の id は "<platform>:<name>" のまま変えないこと(1台構成の既存契約)
    public static func workerID(platform: String, host: String?, name: String) -> String {
        guard let host = MachineHostDispatch.normalize(host) else { return "\(platform):\(name)" }
        return "\(platform):\(host)/\(name)"
    }

    /// マシンプロファイル1件ぶんのデバイス。spec.host には**実効ホスト**(デバイス指定 →
    /// マシンプロファイルの既定 → ローカル、を正規化した値)が入っている
    public struct CatalogEntry: Equatable, Sendable {
        public let platform: String
        public let spec: DeviceSpec

        public init(platform: String, spec: DeviceSpec) {
            self.platform = platform
            self.spec = spec
        }

        public var host: String? { spec.machine }
        public var name: String { spec.name }
    }

    /// デバイスの実効ホスト。デバイス指定 > マシンプロファイルの既定 > ローカル(nil)。
    /// **デバイス側の "local" は「手元」の明示指定で、マシン既定より強い** —— normalize は
    /// "local" を nil に畳むので、素の `normalize(device.host) ?? normalize(machineHost)` だと
    /// 未指定と区別が付かずマシン既定(リモート)へ落ちる。空文字は未指定として既定へ落とす
    public static func effectiveHost(device: DeviceSpec, machineHost: String?) -> String? {
        if MachineHostDispatch.isExplicitLocal(device.machine) { return nil }
        return MachineHostDispatch.normalize(device.machine) ?? MachineHostDispatch.normalize(machineHost)
    }

    /// マシンプロファイルを ios → android の順に平坦化する(実効ホストを spec.host へ書き戻すので、
    /// これ以降は spec.host だけ見ればよい)
    public static func entries(machine: MachineProfile) -> [CatalogEntry] {
        var result: [CatalogEntry] = []
        for (platform, list) in [("ios", machine.ios), ("android", machine.android)] {
            for spec in list?.devices ?? [] {
                var resolved = spec
                resolved.machine = effectiveHost(device: spec, machineHost: machine.machine)
                result.append(CatalogEntry(platform: platform, spec: resolved))
            }
        }
        return result
    }

    /// 同じ (host, name) が2つ以上あれば最初の1件を返す(ホストが違えば同名でも重複ではない)
    public static func firstDuplicate(in entries: [CatalogEntry]) -> CatalogEntry? {
        var seen = Set<String>()
        for entry in entries {
            // ホスト名にタブは現れない(登録名は ssh 宛先ではなく識別子)ので区切りに使える
            let key = "\(display(entry.host))\t\(entry.name)"
            if !seen.insert(key).inserted {
                return entry
            }
        }
        return nil
    }

    public enum Resolution: Equatable {
        case found(CatalogEntry)
        /// このマシンプロファイルに無い(従来どおり警告してスキップする)
        case missing
        /// 同名が複数ホストに居て、参照が host を書いていない。候補は表示名(ローカルは "local")
        case ambiguous(hosts: [String])
    }

    /// 実行プロファイルの参照1件を解決する。ref.host を書いていればそのホストのものだけを見る
    public static func resolve(_ ref: RunDeviceRef, in entries: [CatalogEntry]) -> Resolution {
        let byName = entries.filter { $0.name == ref.name }
        guard !byName.isEmpty else { return .missing }

        if let wanted = MachineHostDispatch.normalize(ref.machine) {
            return byName.first { $0.host == wanted }.map { .found($0) } ?? .missing
        }
        // ref が "local" を明示していれば、ローカルのものだけを見る(未指定とは区別する)
        if MachineHostDispatch.isExplicitLocal(ref.machine) {
            return byName.first { $0.host == nil }.map { .found($0) } ?? .missing
        }
        if byName.count == 1 { return .found(byName[0]) }
        return .ambiguous(hosts: byName.map { display($0.host) })
    }

    /// 解決済みデバイスをホストごとに束ねる。**順序は最初に現れたホスト順**(実行の割り当てと
    /// ログの並びを入力から決まる形にする = 同じプロファイルなら毎回同じ順)
    public static func groups<T>(
        _ devices: [T], host: (T) -> String?
    ) -> [(host: String?, devices: [T])] {
        var order: [String] = []
        var buckets: [String: [T]] = [:]
        for device in devices {
            let key = display(host(device))
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(device)
        }
        return order.map { key in
            (host: key == localDisplayName ? nil : key, devices: buckets[key] ?? [])
        }
    }
}
