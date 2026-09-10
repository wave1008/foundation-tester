// 供給フェーズ(ワーカー構築〜シナリオ開始)の間、run がデバイスを使用中であることを示し続ける
// run-lease のハートビート保持者。
//
// RunOrchestrator が書く lease は「シナリオ実行中」だけなので、その手前の install・凍結triage の
// 間は lease が無く、モニターの watchdog からは「誰も走っていない」に見える(inRun=false)。
// そこへ start-device が割り込むと、同じデバイスのブリッジを起動し直して run を巻き添えにする。
// 書く先は RunLease と同一ファイルなので、読み手(ApiMonitorCommand の inRun 判定)は変更不要。
//
// **orchestrator が書き始めたキーは handOff で手放す**(呼び出し側 = 注入する writeRunLease)。
// 手放さないと、担当を終えたワーカーが消した lease をこちらのハートビートが書き戻し、その台は
// run の最後まで run 中に見える(消えている数秒の間にモニターが配信を張り、書き戻しで畳む明滅になる)。

import Foundation

public final class SupplyLeaseHolder: @unchecked Sendable {
    /// RunLease.stalenessSeconds(15s)より十分短い間隔で打ち直す
    public static let defaultHeartbeatSeconds: Double = 5

    private let stateDir: URL
    private let pid: Int32
    private let heartbeatSeconds: Double
    /// keys の読み書きと**ファイルへの書き込み・削除をまとめて**直列化する。書き込みをロックの外で
    /// 行うと、一覧を取った直後の handOff / release の後に書き戻せてしまう
    private let lock = NSLock()
    private var keys: Set<String> = []
    private var heartbeat: Task<Void, Never>?

    /// heartbeatSeconds はテストの差し替え口
    public init(stateDir: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                heartbeatSeconds: Double = SupplyLeaseHolder.defaultHeartbeatSeconds) {
        self.stateDir = stateDir
        self.pid = pid
        self.heartbeatSeconds = heartbeatSeconds
    }

    /// キーを追加して保持を始める(既出キーは無視)。iOS=シミュレータ UDID / Android=adb serial。
    /// 初回追加でハートビートを起動する
    public func hold(keys newKeys: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let added = newKeys.filter { !$0.isEmpty && keys.insert($0).inserted }
        for key in added { RunLease.write(stateDir: stateDir, key: key, pid: pid) }
        guard heartbeat == nil, !keys.isEmpty else { return }
        let interval = UInt64(heartbeatSeconds * 1_000_000_000)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, !Task.isCancelled else { return }
                self.rewriteHeld()
            }
        }
    }

    /// orchestrator がこのキーの lease を書き始めたら呼ぶ。**ファイルは消さない**(持ち主が
    /// orchestrator へ移っただけ)—— 以後こちらは打ち直さないので、orchestrator が消せば消えたまま
    public func handOff(key: String) {
        lock.lock()
        keys.remove(key)
        lock.unlock()
    }

    private func rewriteHeld() {
        lock.lock()
        defer { lock.unlock() }
        for key in keys { RunLease.write(stateDir: stateDir, key: key, pid: pid) }
    }

    /// ハートビートを止めて、まだ持っている(手放していない)キーの lease を消す。
    /// 呼び忘れても RunLease は mtime 15s で失効するので実害は「最大 15s の保持延長」だけ
    public func release() {
        lock.lock()
        heartbeat?.cancel()
        heartbeat = nil
        for key in keys { RunLease.remove(stateDir: stateDir, key: key) }
        keys.removeAll()
        lock.unlock()
    }
}
