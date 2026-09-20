import FTCore
import Foundation

/// シミュレータを止めるときの**手順と定数の唯一の定義元**。`DeviceBooter.shutdownOne`(一括停止・
/// 凍結台の回復)と `BridgeProvisioner` の「遅いランナーの台ごと再起動」が同じ土台を使う ——
/// 別々に持つと、片方だけ retry 回数や時限を直したときに同じ台で挙動が食い違う。
/// **文言とエラー型は呼び手ごと**(共有するのは判定と手順だけ)。
public enum SimulatorShutdownRetry {
    /// 実状態で止まったと確かめるまでの試行回数
    public static let attempts = 3
    /// simctl が稀に応答不能になるため時限化する(秒)。締切ループが無効化するのを防ぐ
    public static let shutdownTimeoutSeconds: TimeInterval = 30
    /// 試行の間隔(ナノ秒)
    public static let retryIntervalNanoseconds: UInt64 = 2_000_000_000

    public struct Outcome: Sendable {
        public let observation: SimulatorShutdownObservation
        /// 最後の simctl の結果(呼び手が失敗の文言に載せる。**成否の判定には使わない**)
        public let lastResult: Shell.Result?
    }

    /// **exit code で成否を決めない** —— macOS 27 beta 3 の simctl は「Unable to shutdown…」(405)を
    /// 返しつつ実際には Booted のまま残るレースがあるので、カタログの実状態だけで判定する。
    /// `onRetry` は再試行の直前に (試行番号, 総数) で呼ぶ(呼び手のログ用。既定は何もしない)
    public static func shutdown(
        udid: String, onRetry: (Int, Int) -> Void = { _, _ in }
    ) async -> Outcome {
        var lastResult: Shell.Result?
        var observation = SimulatorShutdownObservation.stillBooted
        for attempt in 1...attempts {
            lastResult = try? Shell.run(["xcrun", "simctl", "shutdown", udid],
                                        timeout: shutdownTimeoutSeconds)
            observation = SimulatorCatalog.shutdownObservation(udid: udid)
            if observation == .stopped { break }
            if attempt < attempts {
                onRetry(attempt, attempts)
                try? await Task.sleep(nanoseconds: retryIntervalNanoseconds)
            }
        }
        return Outcome(observation: observation, lastResult: lastResult)
    }
}
