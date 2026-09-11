// MCP(fleetest-mcp)が操作している台の印。RunLease の姉妹型(置き場所 `.fleetest/`・鍵 = iOS はシミュレータ UDID /
// Android は adb serial も同じ)。書き手: MCPServer.call(台を指すツールが通るたびに上書き)。
// 読み手: run の台の絞り込み(ProfileRunner.limitingDevicesAvoidingMCP)。
// **生死は pid だけで見る(時間の閾値を置かない)** —— run はこの印を「避ける」だけで断らない(ユーザー決定
// 「避けて、足りなければ警告して使う」)ので、操作を終えた後も MCP が生きている間は残る印の損は
// 「その台を後回しにする」に収まる。閾値を置くと、考え中のエージェントの台を run が奪う形が戻る

import FTCore
import Foundation

public enum MCPDeviceLease {
    static let prefix = "mcp-"
    static let suffix = ".lease"

    public static func leaseURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent("\(prefix)\(key)\(suffix)")
    }

    /// ベストエフォート(失敗は無視。印が書けないだけで MCP の操作は止めない)
    public static func write(stateDir: URL, key: String, pid: Int32) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? String(pid).write(to: leaseURL(stateDir: stateDir, key: key), atomically: true, encoding: .utf8)
    }

    /// 生きている保持者の一覧(鍵 → pid)。`excluding` の pid が持つ印は数えない(自分・親)
    public static func liveHolders(stateDir: URL, excluding: Set<Int32>) -> [String: Int32] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else { return [:] }
        var holders: [String: Int32] = [:]
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let key = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard let text = try? String(contentsOf: stateDir.appendingPathComponent(name), encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid > 0, !excluding.contains(pid), ProcessLiveness.isAlive(pid) else { continue }
            holders[key] = pid
        }
        return holders
    }
}
