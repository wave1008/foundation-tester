// プロセス内で1回だけ: BridgeClient.acknowledgeOpenURLConsent が (device, bundleID) ごとに
// SpringBoard の初回確認アラートを試したかを覚える。同意は端末+アプリの組で永続する(実測)ため、
// 一度成功に到達したら二度と試さない。並行呼び出し(hybrid で in-app/xcuitest 両接続から
// 呼ばれ得る)があるため NSLock で直列化する(FMHealth.swift と同じ作法)。
import Foundation

final class OpenURLConsentAttemptCache: @unchecked Sendable {
    static let shared = OpenURLConsentAttemptCache()

    private let lock = NSLock()
    private var attempted: Set<String> = []

    func hasAttempted(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return attempted.contains(key)
    }

    func markAttempted(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        attempted.insert(key)
    }
}
