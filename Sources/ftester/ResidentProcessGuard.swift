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
    private static var commandStartedAt: DispatchTime?
    private static var commandWatchdogTimer: DispatchSourceTimer?

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

    /// live serve のようなコマンド駆動の常駐コマンド向けの安全弁。1コマンドの処理が maxSeconds を
    /// 超えて停止(協調スレッドプールが CPU spin で埋まる等)したら exit(0) する。専用キューの
    /// タイマーで動くため、メインループ/協調プールがブロックしても確実に発火する(startOrphanWatchdog
    /// と同じ思想)。コマンド境界は noteCommandStart()/noteCommandEnd() で知らせること。
    /// maxSeconds は拡張側の1リクエストタイムアウト(monitorLiveController.ts の
    /// SERVE_REQUEST_TIMEOUT_MS=20秒)より大きくする: 通常は拡張が先に kill→respawn し、これは
    /// 拡張が kill しない場合(パネル閉等)の最終安全弁。
    static func startCommandWatchdog(maxSeconds: Double, logLabel: String) {
        lock.lock()
        defer { lock.unlock() }
        guard commandWatchdogTimer == nil else { return }

        let queue = DispatchQueue(label: "ftester-resident-process-guard-command-watchdog")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            lock.lock()
            let started = commandStartedAt
            lock.unlock()
            guard let started else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds)
                / 1_000_000_000
            if elapsed > maxSeconds {
                logStderr(logLabel,
                    "1コマンドの処理が\(Int(maxSeconds))秒を超えて停止したため強制終了します(command watchdog)")
                exit(0)
            }
        }
        timer.resume()
        commandWatchdogTimer = timer
    }

    /// 1コマンドの処理開始を記録する(startCommandWatchdog の監視対象)。
    static func noteCommandStart() {
        lock.lock()
        commandStartedAt = .now()
        lock.unlock()
    }

    /// 1コマンドの処理完了を記録する(アイドル=監視対象外に戻す)。
    static func noteCommandEnd() {
        lock.lock()
        commandStartedAt = nil
        lock.unlock()
    }

    private static func logStderr(_ label: String, _ message: String) {
        FileHandle.standardError.write(Data(("[\(label)] " + message + "\n").utf8))
    }
}
