import Foundation

public enum FMRetryEligibility {
    public enum Classification: String, Sendable {
        case candidate
        case refused
        case ineligible
    }

    /// 2008 は回復を保証しない。既知の除外が別枝にあっても優先し、表示用の深さ制限は使わない。
    /// FoundationModels の型への依存は呼び手の型判定へ渡す。
    public static func classify(
        _ error: any Error,
        isRefusal: (any Error) -> Bool = { _ in false },
        isTimeout: (any Error) -> Bool = { _ in false }
    ) -> Classification {
        var queue: [any Error] = [error]
        var visited: Set<ObjectIdentifier> = []
        var retained: [NSError] = []
        var hasCandidate = false
        var excluded = false
        var refused = false
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            let next = current as NSError
            guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
            retained.append(next)
            refused = isRefusal(current) || refused
            excluded = current is CancellationError || isTimeout(current) || excluded
            switch (next.domain, next.code) {
            case ("ModelManagerServices.InferenceError", 2008):
                hasCandidate = true
            case ("ModelManagerServices.InferenceError", 2007),
                 ("com.apple.SensitiveContentAnalysisML", 15),
                 (NSCocoaErrorDomain, NSUserCancelledError),
                 (NSURLErrorDomain, NSURLErrorCancelled),
                 (NSURLErrorDomain, NSURLErrorTimedOut):
                excluded = true
            default:
                break
            }
            if let single = next.userInfo[NSUnderlyingErrorKey] as? any Error { queue.append(single) }
            if let multiple = next.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
                queue.append(contentsOf: multiple)
            }
        }
        withExtendedLifetime(retained) {}
        if refused { return .refused }
        return hasCandidate && !excluded ? .candidate : .ineligible
    }
}
