// PollBackoff.swift
// ポーリング待機の指数バックオフ。StepExecutor.executeAction/executeAssert の再試行間隔は
// これに統一する(コピペ禁止)。決定的な列(乱数なし): 100, 200, 400, 800, 1000, 1000, …(既定上限 1000ms)

import Foundation

public struct PollBackoff: Sendable {
    private var nextMs: Int
    private let capMs: Int

    public init(initialMs: Int = 100, capMs: Int = 1000) {
        self.nextMs = initialMs
        self.capMs = capMs
    }

    public mutating func nextDelay() -> Duration {
        let delayMs = min(nextMs, capMs)
        nextMs = min(nextMs * 2, capMs)
        return .milliseconds(delayMs)
    }
}
