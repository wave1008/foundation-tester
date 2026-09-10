// RunOrchestrator が持つ lease(run-lease / 録画中 lease)のキー集合と、その書き込み・削除。
// 書き手の実体(RunLease/RecordingLease の write/remove)は FTBridgeClient にあり FTCore から
// 呼べないので、fleetest ターゲットが注入する(nil = テストハーネス等。キーの記帳だけ行う)。

/// **書き込みと削除は必ずアクターの中で行う**。外で行うと、ハートビートがキー一覧を取った直後に
/// release が割り込み、消したばかりのファイルを書き戻す —— 担当を終えた台が lease の失効
/// (RunLease.stalenessSeconds)まで run 中に見え、モニターの配信が張られては畳まれる。
actor RunLeaseLedger {
    private var keys: Set<String> = []
    private let write: (@Sendable (String) -> Void)?
    private let remove: (@Sendable (String) -> Void)?

    init(write: (@Sendable (String) -> Void)?, remove: (@Sendable (String) -> Void)?) {
        self.write = write
        self.remove = remove
    }

    func acquire(_ key: String) {
        keys.insert(key)
        write?(key)
    }

    /// **持っていないキーのファイルは消さない**。同じファイルを供給フェーズの lease
    /// (SupplyLeaseHolder)が保持していることがあり、消すとそちらの次のハートビートまで穴が空いて
    /// 書き戻される(= 最初の症状と同じ明滅)。戻り値: 持っていて消したら true
    @discardableResult
    func release(_ key: String) -> Bool {
        guard keys.remove(key) != nil else { return false }
        remove?(key)
        return true
    }

    /// mtime を鮮度内に保つための打ち直し。持っているキーだけを書く
    func heartbeat() {
        for key in keys { write?(key) }
    }

    func releaseAll() {
        for key in keys { remove?(key) }
        keys.removeAll()
    }

    func holds(_ key: String) -> Bool { keys.contains(key) }
}
