// run が台を使い始める前(供給フェーズが自分の run-lease を書き始める前)に、その台の
// run-lease を既に握っている生きた別プロセスがいないか確かめる(ユーザー決定「拒否して
// 止める」)。リモートの dispatch.lock と同じ fail-fast をローカルの同時実行にも適用する。
//
// 判定は conflicts(pure function)に切り出し、鮮度判定(RunLease.holderPID)だけを呼び出し側が
// 注入する。呼び出し側(ProfileRunner.run / ApiRunCommand)は、workers を構築し終えて
// supplyLease?.hold(keys:) で自分の lease を書き始める**直前**にこれを呼ぶ。

import Foundation

public enum RunLeaseGuard {
    public struct Conflict: Sendable, Equatable {
        /// 表示用のデバイス名(worker.label 等)
        public let device: String
        public let key: String
        public let holderPID: Int32

        public init(device: String, key: String, holderPID: Int32) {
            self.device = device
            self.key = key
            self.holderPID = holderPID
        }
    }

    /// devices: これから lease を書こうとしているデバイス(表示名, lease key)の集合。
    /// selfPID: 自分自身の pid — 同じプロセスが2回チェックしても衝突と見なさない
    /// (供給フェーズの SupplyLeaseHolder と RunOrchestrator の両方が同じ pid で書くため)。
    /// holderPID: その key の lease が生きていて鮮度内なら保持者 pid を返す(RunLease.holderPID)。
    /// 同じ key が複数回渡っても(iOS/Android 混在の呼び出し元をまとめて渡すケース等)結果は1件だけ返す
    public static func conflicts(
        devices: [(device: String, key: String)],
        selfPID: Int32,
        holderPID: (String) -> Int32?
    ) -> [Conflict] {
        var seenKeys: Set<String> = []
        var result: [Conflict] = []
        for entry in devices {
            guard seenKeys.insert(entry.key).inserted else { continue }
            guard let pid = holderPID(entry.key), pid != selfPID else { continue }
            result.append(Conflict(device: entry.device, key: entry.key, holderPID: pid))
        }
        return result
    }

    /// 台と保持者 pid を名指しする拒否メッセージ(ユーザー決定「拒否して止める」。無警告で走らせない)
    public static func message(_ conflicts: [Conflict]) -> String {
        let list = conflicts.map { "\($0.device) (held by pid \($0.holderPID))" }
            .joined(separator: ", ")
        return "refusing to start: already in use by another fleetest run — \(list). "
            + "Wait for that run to finish, or target a different device/profile."
    }
}
