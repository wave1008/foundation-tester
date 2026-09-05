// ParentDeathWatch.swift
// 親プロセスが死んだら自分も終わる(孤児として端末を叩き続けない。実測 2026-09-05:
// `fleetest run` の親を kill -9 すると、Process() で起こした子(fleetest-scenarios-<project> run …
// / ApiRunMachineFanout・RemoteDeviceFanout・RemoteMonitorFanout・FleetRunner が起こす
// fleetest 自身の子)が ppid 1 の孤児として残った。Foundation.Process は親の死を子へ伝えない
// (Sources/fleetest/InterruptRelay.swift の前提と同じ)。
//
// **opt-in**: 武装するのは spawn 側が環境変数 `FT_PARENT_PID` を渡した子だけ。端末のシェルから
// `fleetest run &` した親(シェル)が閉じたときに run を巻き込まないため、既定では何もしない。

import Foundation

public enum ParentDeathWatch {
    public static let environmentKey = "FT_PARENT_PID"

    /// 子へ渡す環境。既存の環境(base 省略時は現在の環境)に `FT_PARENT_PID` = 自分の pid を足す
    public static func childEnvironment(base: [String: String]? = nil) -> [String: String] {
        var env = base ?? ProcessInfo.processInfo.environment
        env[environmentKey] = String(getpid())
        return env
    }

    /// `FT_PARENT_PID` があれば武装する。無ければ何もしない(既存挙動を変えない)。
    ///
    /// 親が死んだら**自分に SIGTERM を送るだけ**で、時限の `_exit` はしない —— 自前の後始末
    /// (終了スクリプト・dispatch.lock の解放・向きの復元)を持つ fleetest のプロセスは、
    /// `InterruptRelay` の fleetest の子と同じく「待つ側」に倒す(所要は利用者のスクリプト次第で
    /// 上限を置けない。2 秒で `_exit` していた版は外側から後始末を打ち切っていた = Codex 指摘
    /// 2026-09-06)。SIGTERM の既定動作は終了なので、ハンドラの無いプロセスは即座に終わる。
    /// 後始末が刺さって残ったものは `FT_PARENT_PID` の印を持つ孤児として拡張の掃除
    /// (`orphanSweep.ts`)が次回 activate で落とす
    public static func armIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let raw = environment[environmentKey], let parentPID = pid_t(raw) else { return }
        arm(parentPID: parentPID) {
            FileHandle.standardError.write(
                Data("⚠️ parent process \(parentPID) exited — stopping (FT_PARENT_PID)\n".utf8))
            kill(getpid(), SIGTERM)
        }
    }

    /// parentPID の終了を kqueue(EVFILT_PROC / NOTE_EXIT)で待ち、終了したら onExit を呼ぶ。
    /// 既に居なければ(kevent 登録が ESRCH)即座に onExit(実測: 存在しない pid・回収済みの
    /// 子いずれも登録が -1/ESRCH で返り、生きている pid は 0 で返る)。
    /// **スレッドは detach**(プロセス終了を待たず抜ける = このスレッドが生存を妨げない)
    public static func arm(parentPID: pid_t, onExit: @escaping @Sendable () -> Void) {
        let kq = kqueue()
        guard kq >= 0 else { onExit(); return }

        var event = kevent()
        event.ident = UInt(parentPID)
        event.filter = Int16(EVFILT_PROC)
        event.flags = UInt16(EV_ADD | EV_ONESHOT)
        event.fflags = UInt32(NOTE_EXIT)
        event.data = 0
        event.udata = nil

        let registered = kevent(kq, &event, 1, nil, 0, nil)
        if registered != 0 {
            // ESRCH 等: 登録できない = 対象は既に居ない
            close(kq)
            onExit()
            return
        }

        let thread = Thread {
            var triggered = kevent()
            let n = kevent(kq, nil, 0, &triggered, 1, nil)
            close(kq)
            guard n > 0 else { return }
            onExit()
        }
        thread.name = "fleetest-parent-death-watch"
        thread.start()
    }
}
