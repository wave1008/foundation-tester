// RemoteHostFacts.swift
// ディスパッチが観測した「ホストの事実」の手元キャッシュ。書き手は RemoteRunDispatcher、
// 読み手は FleetRunner / DeviceHostRunner(FleetSplit.MachineContext を組み立てる側)。
// 同一ホストへのディスパッチは dispatch.lock で直列化される(RemoteDispatchLock)ため、
// このストアはファイル競合を気にしなくてよい(DeviceFrozenStore と違い pid 生存判定は不要 ——
// 「最新の観測値」を保つだけの単純なキャッシュ)。

import Foundation

/// リモートホスト1台ぶんの観測キャッシュ。
public struct RemoteHostFacts: Codable, Equatable, Sendable {
    /// 回収した実績レコードの machine と同じ語彙(観測値。プローブでの推測はしない)
    public var machine: String?
    /// 直近ディスパッチのセットアップ固定費(プローブ〜リモート run 開始前)の実測秒
    public var dispatchOverheadSeconds: Double?
    public var updatedAt: String

    public init(machine: String? = nil, dispatchOverheadSeconds: Double? = nil, updatedAt: String) {
        self.machine = machine
        self.dispatchOverheadSeconds = dispatchOverheadSeconds
        self.updatedAt = updatedAt
    }
}

public enum RemoteHostFactsStore {

    /// 受け手パッケージ直下 .ftester/remote-hosts/(LastResultsStore.stateDir と同じアンカー規則:
    /// ScenarioHost.packageRoot() 優先、無ければ project.rootURL から2階層遡る)。
    /// ホストの事実はプロジェクトをまたいで同じ機械を指すので project 名では分けない。
    public static func dir(project: TestProject) -> URL {
        let root = ScenarioHost.packageRoot() ?? project.rootURL
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".ftester/remote-hosts")
    }

    /// ホストラベル(profiles/machines の識別子・"user@host" 等)→ ファイル名。
    /// [A-Za-z0-9_.-] 以外は "_" に置換(書き手と読み手で同一の変換を通ること)
    public static func fileKey(hostLabel: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        return String(hostLabel.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func entryURL(dir: URL, hostLabel: String) -> URL {
        dir.appendingPathComponent("\(fileKey(hostLabel: hostLabel)).json")
    }

    /// 読めない(存在しない・壊れた JSON)場合は nil
    public static func load(dir: URL, hostLabel: String) -> RemoteHostFacts? {
        guard let data = try? Data(contentsOf: entryURL(dir: dir, hostLabel: hostLabel)) else { return nil }
        return try? JSONDecoder().decode(RemoteHostFacts.self, from: data)
    }

    /// best-effort(失敗しても呼び出し側の run 成否に影響させない)。atomic 書き込み
    public static func save(_ facts: RemoteHostFacts, dir: URL, hostLabel: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(facts) else { return }
        try? data.write(to: entryURL(dir: dir, hostLabel: hostLabel), options: .atomic)
    }
}
