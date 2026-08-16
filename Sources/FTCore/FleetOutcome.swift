// デバイス群(N台)を供給・解決するときの部分失敗の扱いを1箇所に固定する。
// 呼び手(iOS ブリッジ供給・Android ワーカー構築)はここへ転送するだけにすること。

import Foundation

public enum FleetOutcome {
    /// 規則は1つ: **1台でも用意できたら残りで走る**。全滅のときだけ最初のエラーを投げる。
    ///
    /// この規則が守っている実害2件:
    /// - 2026-08-11: iOS ブリッジ供給(`BridgeProvisioner.provision`)が10台中8台readyでも
    ///   残り2台の期限切れで丸ごと throw し、Flutter/RN の51本が1本も走らなかった。
    /// - 2026-08-16: Android ワーカー構築(`ProfileWorkerFactory.buildAndroidWorkers`)が
    ///   `try ... map` で1台の serial 解決失敗を全体 throw にし、後続3プロファイル74本が
    ///   開始前に全滅した(健全な6台は使われなかった)。
    ///
    /// devices/failures は入力順を保つ。空入力は失敗ではない(供給対象が無いだけ)。
    public static func resolve<T>(
        _ outcomes: [(name: String, result: Result<T, Error>)]
    ) throws -> (devices: [T], failures: [(name: String, error: Error)]) {
        var devices: [T] = []
        var failures: [(name: String, error: Error)] = []
        for outcome in outcomes {
            switch outcome.result {
            case .success(let device): devices.append(device)
            case .failure(let error): failures.append((outcome.name, error))
            }
        }
        if devices.isEmpty, let first = failures.first { throw first.error }
        return (devices, failures)
    }
}
