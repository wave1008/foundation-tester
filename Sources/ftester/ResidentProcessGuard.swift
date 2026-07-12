// 常駐 api コマンド(live serve / host-metrics / monitor)共通の終了保証。コマンドループが
// 1件の処理(応答しないブリッジへの HTTP 待ち等)でブロックしていると stdin EOF も
// SIGTERM/SIGINT も効かず、親(拡張ホスト)が Reload Window 等で消えると孤児として残り続ける。
// この2つの安全弁はメインループの状態と無関係に専用キューのタイマーで動くため、
// ブロック中でも確実に終了できる。

import Foundation

enum ResidentProcessGuard {
    private static let lock = NSLock()
    private static var watchdogTimer: DispatchSourceTimer?
    private static var forcedExitScheduled = false

    /// 起動時の親PIDを記録し、5秒間隔で監視して親が変わったら(reparent=親死亡による孤児化)
    /// stderr に1行ログして exit(0) する。起動時点で親が既に pid 1(意図的なデーモン化)なら
    /// 何もしない(inert)。
    static func startOrphanWatchdog(logLabel: String) {
        let initialParentPID = getppid()
        guard initialParentPID != 1 else { return }

        lock.lock()
        defer { lock.unlock() }
        guard watchdogTimer == nil else { return }

        let queue = DispatchQueue(label: "ftester-resident-process-guard-watchdog")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler {
            guard getppid() != initialParentPID else { return }
            logStderr(logLabel, "親プロセスの終了を検知したため終了します(watchdog)")
            exit(0)
        }
        timer.resume()
        watchdogTimer = timer
    }

    /// EOF/シグナル検知後、afterSeconds(既定2秒。拡張側の SIGTERM→SIGKILL の猶予と同じ意図)
    /// 後に stderr に1行ログして exit(0) する安全弁。通常はコマンドループが先に自然終了するため
    /// 発火しない。EOF・シグナルの両経路から呼ばれうるので多重呼び出しは1回に潰す。
    static func scheduleForcedExit(afterSeconds: Double = 2.0, logLabel: String) {
        lock.lock()
        guard !forcedExitScheduled else { lock.unlock(); return }
        forcedExitScheduled = true
        lock.unlock()

        let queue = DispatchQueue(label: "ftester-resident-process-guard-forced-exit")
        queue.asyncAfter(deadline: .now() + afterSeconds) {
            logStderr(logLabel, "終了指示から\(Int(afterSeconds))秒経過しても停止しないため強制終了します")
            exit(0)
        }
    }

    private static func logStderr(_ label: String, _ message: String) {
        FileHandle.standardError.write(Data(("[\(label)] " + message + "\n").utf8))
    }
}
