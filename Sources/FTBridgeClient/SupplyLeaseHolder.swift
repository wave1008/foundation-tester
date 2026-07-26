// 供給フェーズ(ワーカー構築〜シナリオ開始)の間、run がデバイスを使用中であることを示し続ける
// run-lease のハートビート保持者。
//
// RunOrchestrator が書く lease は「シナリオ実行中」だけなので、その手前の install・凍結triage の
// 間は lease が無く、モニターの watchdog からは「誰も走っていない」に見える(inRun=false)。
// そこへ device-up が割り込むと、同じデバイスのブリッジを起動し直して run を巻き添えにする。
// 書く先は RunLease と同一ファイルなので、読み手(ApiMonitorCommand の inRun 判定)は変更不要。

import Foundation

public final class SupplyLeaseHolder: @unchecked Sendable {
    private let stateDir: URL
    private let pid: Int32
    private let lock = NSLock()
    private var keys: Set<String> = []
    private var heartbeat: Task<Void, Never>?

    /// RunLease.stalenessSeconds(15s)より十分短い間隔で打ち直す
    private static let heartbeatSeconds: UInt64 = 5

    public init(stateDir: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.stateDir = stateDir
        self.pid = pid
    }

    /// キーを追加して保持を始める(既出キーは無視)。iOS=シミュレータ UDID / Android=adb serial。
    /// 初回追加でハートビートを起動する
    public func hold(keys newKeys: [String]) {
        lock.lock()
        let added = newKeys.filter { !$0.isEmpty && keys.insert($0).inserted }
        let shouldStart = heartbeat == nil && !keys.isEmpty
        lock.unlock()
        for key in added { RunLease.write(stateDir: stateDir, key: key, pid: pid) }
        guard shouldStart else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatSeconds * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                for key in self.snapshot() {
                    RunLease.write(stateDir: self.stateDir, key: key, pid: self.pid)
                }
            }
        }
    }

    private func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }

    /// ハートビートを止めて lease を消す。**RunOrchestrator が自前の lease を書き始めた後に呼ぶ**
    /// (消しても orchestrator 側が即書き直すので、監視から見た穴は生じない)。
    /// 呼び忘れても RunLease は mtime 15s で失効するので実害は「最大 15s の保持延長」だけ
    public func release() {
        heartbeat?.cancel()
        heartbeat = nil
        for key in snapshot() { RunLease.remove(stateDir: stateDir, key: key) }
        lock.lock()
        keys.removeAll()
        lock.unlock()
    }
}
