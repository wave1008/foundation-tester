// RemoteHostFacts.swift
// ディスパッチが観測した「ホストの事実」の手元キャッシュ。書き手は RemoteRunDispatcher、
// 読み手は FleetRunner / DeviceHostRunner(FleetSplit.MachineContext を組み立てる側)。
// 同一ホストへのディスパッチは dispatch.lock で直列化される(RemoteDispatchLock)ため、
// このストアはファイル競合を気にしなくてよい(DeviceFrozenStore と違い pid 生存判定は不要 ——
// 「最新の観測値」を保つだけの単純なキャッシュ)。

import Foundation

/// リモートホスト1台ぶんの観測キャッシュ。
public struct RemoteHostFacts: Codable, Equatable, Sendable {
    /// その機械の**ホスト名**(回収した実績レコードの host と同じ語彙。観測値で、プローブでの
    /// 推測はしない)。**JSON キーは "host"**(2026-08-26 改名。旧キー "machine" も読む)
    public var host: String?
    /// **表示用のマシン名(ローカルエイリアス)**。このファイルは「その machine 自身に関する構成」
    /// なので、エイリアスを**欄として**持ってよい(鍵にはしない —— 鍵はホスト。2026-08-26 ユーザー決定)。
    /// 用途は記録(ホスト名)の読み替え1つだけ: 結果 JSON は host で残るので、画面に登録名を出すには
    /// ホスト名 → エイリアスの対応が要る。ディスパッチのたびに書き直すので改名にも追随する
    public var machineAlias: String?
    /// 直近ディスパッチのセットアップ固定費(プローブ〜リモート run 開始前)の実測秒
    public var dispatchOverheadSeconds: Double?
    /// プローブの実測(sysctl machdep.cpu.brand_string)
    public var processorModel: String?
    /// プローブの実測(sysctl hw.ncpu。論理コア)
    public var coreCount: Int?
    /// 直近の run で同時に使ったデバイス数の観測値
    public var concurrentDevices: Int?
    public var updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case host, machine, machineAlias
        case dispatchOverheadSeconds, processorModel, coreCount, concurrentDevices, updatedAt
    }

    /// 旧キー "machine"(改名前のキャッシュ)も読む。書きは "host" だけ
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host)
            ?? c.decodeIfPresent(String.self, forKey: .machine)
        machineAlias = try c.decodeIfPresent(String.self, forKey: .machineAlias)
        dispatchOverheadSeconds = try c.decodeIfPresent(Double.self, forKey: .dispatchOverheadSeconds)
        processorModel = try c.decodeIfPresent(String.self, forKey: .processorModel)
        coreCount = try c.decodeIfPresent(Int.self, forKey: .coreCount)
        concurrentDevices = try c.decodeIfPresent(Int.self, forKey: .concurrentDevices)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encodeIfPresent(machineAlias, forKey: .machineAlias)
        try c.encodeIfPresent(dispatchOverheadSeconds, forKey: .dispatchOverheadSeconds)
        try c.encodeIfPresent(processorModel, forKey: .processorModel)
        try c.encodeIfPresent(coreCount, forKey: .coreCount)
        try c.encodeIfPresent(concurrentDevices, forKey: .concurrentDevices)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    public init(host: String? = nil, machineAlias: String? = nil,
               dispatchOverheadSeconds: Double? = nil,
               processorModel: String? = nil, coreCount: Int? = nil, concurrentDevices: Int? = nil,
               updatedAt: String) {
        self.host = host
        self.machineAlias = machineAlias
        self.dispatchOverheadSeconds = dispatchOverheadSeconds
        self.processorModel = processorModel
        self.coreCount = coreCount
        self.concurrentDevices = concurrentDevices
        self.updatedAt = updatedAt
    }
}

public enum RemoteHostFactsStore {

    /// 受け手パッケージ直下 .fleetest/remote-hosts/(LastResultsStore.stateDir と同じアンカー規則:
    /// ScenarioHost.packageRoot() 優先、無ければ project.rootURL から2階層遡る)。
    /// ホストの事実はプロジェクトをまたいで同じ機械を指すので project 名では分けない。
    public static func dir(project: TestProject) -> URL {
        let root = ScenarioHost.packageRoot() ?? project.rootURL
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".fleetest/remote-hosts")
    }

    /// **鍵はホスト(ホスト名 / IP)**。ローカルエイリアス(machine)は頻繁に変わりうるので
    /// 記録の鍵にしない(2026-08-26 ユーザー決定) —— 変えた瞬間に実測が孤児になる。
    /// ssh 宛先を渡されたら user@ を落として実体だけを鍵にする。
    /// [A-Za-z0-9_.-] 以外は "_" に置換(書き手と読み手で同一の変換を通ること)
    public static func fileKey(host: String) -> String {
        let hostLabel = host.contains("@") ? String(host.split(separator: "@").last ?? "") : host
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        return String(hostLabel.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func entryURL(dir: URL, host: String) -> URL {
        dir.appendingPathComponent("\(fileKey(host: host)).json")
    }

    /// **ローカルエイリアス(machine)から鍵(ホスト)を引く**。登録簿にあればその ssh 宛先、
    /// 無ければ渡された文字列を生の宛先として扱う。手元(nil / "local")はこの機械のホスト名。
    /// 呼び手が別々に解決すると読みと書きで鍵がずれるので、**解決はここだけ**
    public static func hostKey(machine: String?, entries: [RemoteHostEntry],
                               localHost: String) -> String {
        guard let machine, !machine.isEmpty,
              !MachineHostDispatch.isExplicitLocal(machine) else { return localHost }
        switch RemoteHostRegistry.resolve(machine, entries: entries) {
        case .registered(let entry): return entry.host
        case .rawTarget(let target): return target
        case .reserved: return localHost
        }
    }

    /// 読めない(存在しない・壊れた JSON)場合は nil
    public static func load(dir: URL, host: String) -> RemoteHostFacts? {
        guard let data = try? Data(contentsOf: entryURL(dir: dir, host: host)) else { return nil }
        return try? JSONDecoder().decode(RemoteHostFacts.self, from: data)
    }

    /// best-effort(失敗しても呼び出し側の run 成否に影響させない)。atomic 書き込み
    public static func save(_ facts: RemoteHostFacts, dir: URL, host: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(facts) else { return }
        try? data.write(to: entryURL(dir: dir, host: host), options: .atomic)
    }
}
