// XCUITest ランナーが劣化したまま run をまたいで放置される問題への対処 —— run の**プロセスを跨いで**
// 「建て直しても直らなかった」台を配る共有ストア。DeviceFrozenStore.swift の姉妹型(同じ棚 `.fleetest/`・
// 同じキー体系 = シミュレータ UDID)だが、鮮度(pid 生存・mtime)は持たない。DeviceFrozenStore の鮮度は
// 「観測者(run)が生きている間だけ有効」という事象を表すためのものだが、こちらの印は特定の観測者に
// 紐付かない「その台で実測した事実」なので、書いたプロセスが死んでも意味を失わない(時間の定数も
// 置かない。次に読むプロセスが 1 問プローブし直して答えを更新する)。
//
// 書き手・読み手: FTBridgeClient.BridgeProvisioner(供給の入口)。段階は2つ:
//   .runnerRestartDidNotHelp    ランナーだけ建て直しても直らなかった(FTBridgeClient の
//                               RunnerRestartFutility と同じ事象をプロセスを跨いで持ち越す)。
//                               次の供給ではシミュレータごとの再起動を試す
//   .simulatorRestartDidNotHelp シミュレータを再起動しても直らなかった。以後は何も自動で撃たない

import Foundation

public enum RunnerSlowness: String, Codable, Sendable {
    case runnerRestartDidNotHelp
    case simulatorRestartDidNotHelp
}

public enum RunnerSlownessStore {
    /// key: シミュレータ UDID(RunLease/DeviceFrozenStore と同じ体系)
    public static func entryURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent("slow-runner-\(key).json")
    }

    private struct Entry: Codable {
        let state: RunnerSlowness
    }

    public static func mark(stateDir: URL, key: String, state: RunnerSlowness) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Entry(state: state)) else { return }
        try? data.write(to: entryURL(stateDir: stateDir, key: key), options: .atomic)
    }

    public static func clear(stateDir: URL, key: String) {
        try? FileManager.default.removeItem(at: entryURL(stateDir: stateDir, key: key))
    }

    public static func current(stateDir: URL, key: String) -> RunnerSlowness? {
        guard let data = try? Data(contentsOf: entryURL(stateDir: stateDir, key: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return entry.state
    }
}
