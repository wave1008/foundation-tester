// MCP(fleetest-mcp)が操作している台の印。RunLease の姉妹型(置き場所 `.fleetest/`・鍵 = iOS はシミュレータ UDID /
// Android は adb serial も同じ)。書き手: MCPServer.call(台を指すツールが通るたびに上書き)・MCP の終了で自分の印を消す。
// 読み手: run の台の絞り込み(ProfileRunner.limitingDevicesAvoidingMCP)・台を止める操作の門(DeviceBooter.deviceInUseRefusal /
// sweepRefusal)・別の MCP セッション(writeAndWarnIfInUse)。死んだ印の掃除は BridgeProvisioner.sweepStaleLeases。
// **生死は「pid + そのプロセスの開始時刻」で見る(時間の閾値を置かない)** —— run はこの印を「避ける」だけで断らない
// (ユーザー決定「避けて、足りなければ警告して使う」)ので、使い終わった後も MCP が生きている間は残る印の損は
// 「その台を避ける」に収まる。閾値を置くと考え中のエージェントの台を run が奪う形が戻る。
// 開始時刻まで見るのは、MCP が消えた後に同じ pid が別のプロセスへ再利用されると、印が生き返って台を避け続けるため

import FTCore
import Foundation

public enum MCPDeviceLease {
    static let prefix = "mcp-"
    static let suffix = ".lease"

    public static func leaseURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent("\(prefix)\(key)\(suffix)")
    }

    /// `<pid> <開始時刻 epoch 秒>`。ベストエフォート(失敗は無視。印が書けないだけで MCP の操作は止めない)
    public static func write(stateDir: URL, key: String, pid: Int32) {
        guard let started = ProcessLiveness.startTime(pid) else { return }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? "\(pid) \(Int(started.timeIntervalSince1970))"
            .write(to: leaseURL(stateDir: stateDir, key: key), atomically: true, encoding: .utf8)
    }

    /// 印のファイル1つの保持者(生きていて開始時刻も一致するときだけ)。それ以外は nil
    static func holder(at url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = text.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count == 2, let pid = Int32(fields[0]), pid > 0, let recorded = Int(fields[1]),
              ProcessLiveness.isAlive(pid), let started = ProcessLiveness.startTime(pid),
              Int(started.timeIntervalSince1970) == recorded else { return nil }
        return pid
    }

    static func isLeaseFile(_ name: String) -> Bool { name.hasPrefix(prefix) && name.hasSuffix(suffix) }

    /// 1つの鍵の生きている保持者(`excluding` の pid なら nil)。台を止める操作の門(DeviceBooter)が使う
    public static func holderPID(stateDir: URL, key: String, excluding: Set<Int32>) -> Int32? {
        guard let pid = holder(at: leaseURL(stateDir: stateDir, key: key)), !excluding.contains(pid)
        else { return nil }
        return pid
    }

    /// 生きている保持者の一覧(鍵 → pid)。`excluding` の pid が持つ印は数えない(自分・親)
    public static func liveHolders(stateDir: URL, excluding: Set<Int32>) -> [String: Int32] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else { return [:] }
        var holders: [String: Int32] = [:]
        for name in names where isLeaseFile(name) {
            guard let pid = holder(at: stateDir.appendingPathComponent(name)), !excluding.contains(pid)
            else { continue }
            holders[String(name.dropFirst(prefix.count).dropLast(suffix.count))] = pid
        }
        return holders
    }

    /// 印を書き、その台を run か**別の MCP セッション**(pid 別)が今使用中なら警告文を返す
    /// (`MCPServer.markDeviceInUse` と ft_run_scenario の共通口。断らない = run の衝突と同じ扱い)。
    /// **別セッションの印は書く前に読む**(書くと上書きして相手が見えなくなる。相手が次に同じ台を
    /// 触ると書き戻し、その時点でこちらの存在を警告として受け取る = 交互に触る限り双方が気付く)。
    /// **deviceKey は呼び手が解決済みの UDID/serial をそのまま渡す**
    public static func writeAndWarnIfInUse(stateDir: URL, key: String, pid: Int32) -> String? {
        let otherSession = holderPID(stateDir: stateDir, key: key, excluding: [pid])
        write(stateDir: stateDir, key: key, pid: pid)
        if let holder = RunLease.holderPID(stateDir: stateDir, key: key), holder != pid {
            return "⚠️ a fleetest run (pid \(holder)) is using this device right now — what you do here and what"
                + " the run does interfere with each other (screens, input, app state)."
                + " Wait for the run to finish, or drive another device."
        }
        guard let otherSession else { return nil }
        return "⚠️ another MCP session (fleetest-mcp pid \(otherSession)) is driving this device too — the two"
            + " sessions move each other's screens, so refs and snapshots go stale under you."
            + " Drive another device, or finish one of the sessions."
    }

    /// その pid が持つ印を全部消す(MCP の終了時)
    public static func removeAll(stateDir: URL, pid: Int32) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else { return }
        for name in names where isLeaseFile(name) {
            let url = stateDir.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.split(separator: " ").first.flatMap({ Int32($0) }) == pid {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
