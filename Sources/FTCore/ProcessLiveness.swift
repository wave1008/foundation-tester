// ProcessLiveness.swift
// プロセス生存判定の唯一の定義元。`kill(pid, 0) == 0` はゾンビ(終了済みだが親が
// まだ回収していないプロセス)にも成功するため「生きている」と誤判定し、それを鮮度条件に
// 使っている台帳(RunLease/RecordingLease/DeviceFrozenStore/hooks 等)を永久に回収不能にする
// (2026-08-18 に実害: ssh 越しに殺された run の pid がゾンビのまま残り hooks の lease が
// 回収されなかった)。sysctl(KERN_PROC_PID)でプロセス状態まで見て SZOMB と exit 処理中
// (P_WEXIT)を「死」として扱う。
//
// **別ユーザーのプロセスも sysctl KERN_PROC_PID は読める**(root 権限は不要。実測)ので、
// `kill(pid, 0)` が返す EPERM(存在するが権限が無い)を「生存」扱いにする分岐は不要 ——
// sysctl が直接プロセス状態を返すため、権限で判定を迂回する理由が無い。
import Foundation

public enum ProcessLiveness {

    /// `<sys/proc.h>` の `P_WEXIT`(Swift へは import されないので値を写す)。
    /// **exit 処理に入ったプロセスはもう戻ってこない** —— ssh 越しに殺された run は
    /// ゾンビになりきらず「終了の途中で刺さったまま」残ることがあり(2026-08-18 にリモートで
    /// 実測: `ps` の STAT が `?Es` のまま数十分)、生存扱いにすると lease が永久に回収されない
    private static let processExitingFlag: Int32 = 0x0000_2000

    /// 既定の生存判定。**`kill(pid, 0)` では足りない**(上記 doc 参照)
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // 居ないプロセスは「失敗」または「成功だが size 0」で返る(どちらも死んだ扱い)
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return isAliveState(Int32(info.kp_proc.p_stat), flags: info.kp_proc.p_flag)
    }

    /// プロセス状態(`kinfo_proc.kp_proc.p_stat` / `p_flag`)の判定だけを切り出した純粋関数
    /// (syscall 抜きでテストするため)
    public static func isAliveState(_ pStat: Int32, flags: Int32 = 0) -> Bool {
        guard pStat != SZOMB else { return false }
        return flags & processExitingFlag == 0
    }
}
