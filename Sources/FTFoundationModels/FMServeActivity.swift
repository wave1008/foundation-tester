import Foundation
import FTCore
import Synchronization

// 呼び手は FMCallSlots を保持しているため、サーバー内の調停で同じ枠を取り直さない。
final class FMServeActivity: Sendable {
    struct Snapshot: Equatable, Sendable, CustomStringConvertible {
        let activeRequests: Int
        let waitingRequests: Int
        let warming: Bool
        let overdueRequests: Int

        init(activeRequests: Int, waitingRequests: Int, warming: Bool, overdueRequests: Int = 0) {
            self.activeRequests = activeRequests
            self.waitingRequests = waitingRequests
            self.warming = warming
            self.overdueRequests = overdueRequests
        }

        var description: String {
            "activeRequests=\(activeRequests), waitingRequests=\(waitingRequests), warming=\(warming), overdueRequests=\(overdueRequests)"
        }
    }

    private struct State: Sendable {
        enum Admission: Sendable {
            case registering
            case waiting(CheckedContinuation<Void, any Error>)
            case granted
            case cancelled
        }
        var active: Set<UUID> = []
        var overdue: Set<UUID> = []
        var admissions: [UUID: Admission] = [:]
        var warming = false

        var waitingRequests: Int {
            admissions.values.filter { if case .waiting = $0 { return true }; return false }.count
        }
    }

    private let state = Mutex(State())

    var snapshot: Snapshot {
        state.withLock { Snapshot(activeRequests: $0.active.count, waitingRequests: $0.waitingRequests,
                                  warming: $0.warming, overdueRequests: $0.overdue.count) }
    }

    func request<Value: Sendable>(
        deadlineSeconds: Double,
        log: @escaping @Sendable (String) -> Void,
        onCompletion: @escaping @Sendable () -> Void,
        beforeAdmission: @escaping @Sendable () async -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        let id = UUID()
        state.withLock { $0.admissions[id] = .registering }
        let result = await DeadlineRace.first(seconds: deadlineSeconds) {
            await beforeAdmission()
            try await self.beginRequest(id: id, log: log)
            defer {
                onCompletion()
                self.finishRequest(id: id)
            }
            // 期限が暖機待ちの間に過ぎた要求は、解放後に推論を始めない。
            try Task.checkCancellation()
            return try await operation()
        }
        if result == nil {
            state.withLock { state in
                if state.active.contains(id) { state.overdue.insert(id) }
            }
            // op Task がまだ始まっていない場合も、期限切れの予約を残さない。
            cancelAdmission(id: id)
            log("request timed out after \(deadlineSeconds)s; \(snapshot)")
        }
        return result
    }

    private func beginRequest(id: UUID, log: @escaping @Sendable (String) -> Void) async throws {
        defer { state.withLock { _ = $0.admissions.removeValue(forKey: id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (decision, reason) = state.withLock { state -> (State.Admission, String) in
                    guard state.admissions[id] != nil else { return (.cancelled, "") }
                    if state.warming || !state.overdue.isEmpty {
                        state.admissions[id] = .waiting(continuation)
                        return (.waiting(continuation), state.warming ? "keep-warm" : "unfinished timed-out inference")
                    }
                    state.active.insert(id)
                    state.admissions[id] = .granted
                    return (.granted, "")
                }
                switch decision {
                case .waiting:
                    log("request waiting for \(reason); \(snapshot)")
                case .granted:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .registering:
                    preconditionFailure("request admission was not decided")
                }
            }
        } onCancel: {
            self.cancelAdmission(id: id)
        }
    }

    private func cancelAdmission(id: UUID) {
        let waiting = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            switch state.admissions[id] {
            case .waiting(let continuation):
                state.admissions.removeValue(forKey: id)
                return continuation
            case .registering:
                state.admissions.removeValue(forKey: id)
            case .granted, .cancelled, nil:
                break
            }
            return nil
        }
        waiting?.resume(throwing: CancellationError())
    }

    @discardableResult
    func startWarm(
        deadlineSeconds: Double,
        log: @escaping @Sendable (String) -> Void,
        onCompletion: @escaping @Sendable (Double) -> Void,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never>? {
        let admitted = state.withLock { state -> Bool in
            guard !state.warming, state.active.isEmpty, state.admissions.isEmpty else { return false }
            state.warming = true
            return true
        }
        guard admitted else { return nil }
        return Task.detached {
            let startedAt = Date()
            let result = await DeadlineRace.first(seconds: deadlineSeconds) {
                // DeadlineRace は期限で戻っても推論を待たない。所有権は実際の完了までここで保持する。
                defer {
                    onCompletion(Date().timeIntervalSince(startedAt))
                    self.finishWarm()
                }
                do {
                    try await operation()
                    return true
                } catch {
                    log("keep-warm failed: \(FMHealth.describe(error)); \(self.snapshot)")
                    return false
                }
            }
            if result == nil {
                log("keep-warm timed out after \(deadlineSeconds)s; \(self.snapshot)")
            }
        }
    }

    private func finishWarm() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.warming = false
            return Self.admitWaiting(&state)
        }
        waiting.forEach { $0.resume() }
    }

    private func finishRequest(id: UUID) {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.active.remove(id)
            state.overdue.remove(id)
            return Self.admitWaiting(&state)
        }
        waiting.forEach { $0.resume() }
    }

    private static func admitWaiting(_ state: inout State) -> [CheckedContinuation<Void, any Error>] {
        guard !state.warming, state.overdue.isEmpty else { return [] }
        let waiting = state.admissions.compactMap { id, admission -> (UUID, CheckedContinuation<Void, any Error>)? in
            guard case .waiting(let continuation) = admission else { return nil }
            return (id, continuation)
        }
        // resume の前に実要求へ所有権を渡す。次の tick が暖機を割り込ませる隙間を作らない。
        for (id, _) in waiting {
            state.admissions[id] = .granted
            state.active.insert(id)
        }
        return waiting.map { $0.1 }
    }
}
