// PollBackoff.swift
// ポーリング待機の指数バックオフ(高速化計画 Phase 3)。
// ロケータ再試行(StepExecutor.executeAction)・exists/valueEquals/textEquals の
// ポーリング間隔(StepExecutor.executeAssert)をこのヘルパに統一する(コピペ禁止)。
// 乱数を使わない決定的な列: 100, 200, 400, 800, 1000, 1000, …(既定で上限 1000ms)

import Foundation

/// 決定的な指数バックオフの遅延列を生成する(乱数なし)。
/// nextDelay() を呼ぶたびに列が 1 つ進み、以後は capMs でクランプされる
public struct PollBackoff: Sendable {
    private var nextMs: Int
    private let capMs: Int

    public init(initialMs: Int = 100, capMs: Int = 1000) {
        self.nextMs = initialMs
        self.capMs = capMs
    }

    /// 次の待機時間を返し、内部状態を次の値(2倍、capMs でクランプ)へ進める
    public mutating func nextDelay() -> Duration {
        let delayMs = min(nextMs, capMs)
        nextMs = min(nextMs * 2, capMs)
        return .milliseconds(delayMs)
    }
}
