import Foundation
import FoundationModels
import FTCore

extension FMServeServer {
    static func requestWithRetry(
        _ request: FMServeWire.Request,
        context: FMServeActivity.RequestContext,
        activity: FMServeActivity,
        log: @escaping @Sendable (String) -> Void,
        operation: @escaping @Sendable (FMServeWire.Request) async throws -> Outcome
    ) async -> Outcome {
        let started = ContinuousClock.now
        do {
            return try await operation(request)
        } catch {
            let classification = retryClassification(error)
            let elapsed = FMServeActivity.RequestContext.seconds(started.duration(to: ContinuousClock.now))
            let failure = error as NSError
            // NSError の文言には入力が含まれうるため、診断ログは識別子・型・コード・所要だけにする。
            log("request=\(context.id) kind=\(request.kind.rawValue) attempt=1 failed"
                + " domain=\(failure.domain) code=\(failure.code) classification=\(classification.rawValue)"
                + " elapsed=\(elapsed)s remaining=\(context.remainingSeconds)s")
            guard classification == .candidate,
                  request.kind == .transcribe || request.kind == .screen,
                  activity.startRetry(context: context, minimumRemainingSeconds: elapsed) else {
                return errorOutcome(error, classification: classification)
            }
        }
        // 初回の実測所要を残り予算の下限に使う。これは開始判断であり、2回目の完了を保証しない。
        // perform はセッションを使い切るので、同じ入力の追加試行も新しいセッションになる。
        let retryStarted = ContinuousClock.now
        log("request=\(context.id) kind=\(request.kind.rawValue) retry=1 started remaining=\(context.remainingSeconds)s")
        let outcome: Outcome
        do {
            outcome = try await operation(request)
        } catch {
            outcome = errorOutcome(error, classification: retryClassification(error))
        }
        let status: String
        switch outcome {
        case .answered: status = "answered"
        case .failed: status = "failed"
        case .refused: status = "refused"
        }
        log("request=\(context.id) kind=\(request.kind.rawValue) retry=1 ended status=\(status)"
            + " elapsed=\(FMServeActivity.RequestContext.seconds(retryStarted.duration(to: ContinuousClock.now)))s"
            + " remaining=\(context.remainingSeconds)s")
        return outcome
    }

    static func retryClassification(_ error: any Error) -> FMRetryEligibility.Classification {
        FMRetryEligibility.classify(error, isRefusal: { error in
            if let error = error as? LanguageModelSession.GenerationError {
                if case .guardrailViolation = error { return true }
                if case .refusal = error { return true }
            }
            if #available(macOS 27, *), let error = error as? LanguageModelError {
                switch error {
                case .guardrailViolation, .refusal: return true
                default: break
                }
            }
            return false
        }, isTimeout: { error in
            if #available(macOS 27, *), let error = error as? LanguageModelError,
               case .timeout = error { return true }
            return false
        })
    }

    private static func errorOutcome(_ error: any Error,
                                     classification: FMRetryEligibility.Classification) -> Outcome {
        classification == .refused ? .refused(FMHealth.describe(error)) : .failed(FMHealth.describe(error))
    }
}
