import Foundation
import XCTest
@testable import FTCore

final class FMRetryEligibilityTests: XCTestCase {
    private func inference(_ code: Int) -> NSError {
        NSError(domain: "ModelManagerServices.InferenceError", code: code)
    }

    func testFindsCandidateBeyondDisplayDepthAcrossBothUnderlyingKeys() {
        var error = inference(2008)
        for index in 0..<12 {
            let info: [String: Any] = index.isMultiple(of: 2)
                ? [NSUnderlyingErrorKey: error] : [NSMultipleUnderlyingErrorsKey: [error]]
            error = NSError(domain: "wrapper", code: index, userInfo: info)
        }
        XCTAssertEqual(FMRetryEligibility.classify(error), .candidate)
    }

    func testKnownLoadFailuresInAnyBranchOverrideCandidate() {
        for excluded in [inference(2007), NSError(domain: "com.apple.SensitiveContentAnalysisML", code: 15)] {
            for children in [[inference(2008), excluded], [excluded, inference(2008)]] {
                let error = NSError(domain: "wrapper", code: -1,
                                    userInfo: [NSMultipleUnderlyingErrorsKey: children])
                XCTAssertEqual(FMRetryEligibility.classify(error), .ineligible)
            }
        }
    }

    func testOtherDomainsCodesAndDescriptionsDoNotQualify() {
        for error in [NSError(domain: "other", code: 2008), inference(2007), inference(2009),
                      NSError(domain: "other", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "ModelManagerServices.InferenceError 2008"])] {
            XCTAssertEqual(FMRetryEligibility.classify(error), .ineligible)
        }
    }

    func testCancellationAndTimeoutOverrideNestedCandidate() {
        for cancelled in [NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
                          NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
                          NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)] {
            let error = NSError(domain: "wrapper", code: 0,
                                userInfo: [NSMultipleUnderlyingErrorsKey: [inference(2008), cancelled]])
            XCTAssertEqual(FMRetryEligibility.classify(error), .ineligible)
        }
        let timed = NSError(domain: "timeout", code: 1, userInfo: [NSUnderlyingErrorKey: inference(2008)])
        XCTAssertEqual(FMRetryEligibility.classify(timed, isTimeout: { ($0 as NSError).domain == "timeout" }),
                       .ineligible)
        XCTAssertEqual(FMRetryEligibility.classify(CancellationError()), .ineligible)
    }

    func testTypedRefusalOverridesCandidateInSiblingBranch() {
        enum Refusal: Error { case rejected }
        let error = NSError(domain: "wrapper", code: 0,
                            userInfo: [NSMultipleUnderlyingErrorsKey: [inference(2008), Refusal.rejected] as [any Error]])
        XCTAssertEqual(FMRetryEligibility.classify(error, isRefusal: { $0 is Refusal }), .refused)
    }

    func testCycleDoesNotHideCandidateOrLoop() {
        // userInfo は計算で返し、自己参照を格納してテスト自身がリークする形にはしない。
        final class Cycle: NSError, @unchecked Sendable {
            let leaf: NSError
            init(leaf: NSError) {
                self.leaf = leaf
                super.init(domain: "cycle", code: 1)
            }
            required init?(coder: NSCoder) { fatalError("unused") }
            override var userInfo: [String: Any] { [NSMultipleUnderlyingErrorsKey: [self, leaf]] }
        }
        XCTAssertEqual(FMRetryEligibility.classify(Cycle(leaf: inference(2008))), .candidate)
        XCTAssertEqual(FMRetryEligibility.classify(Cycle(leaf: inference(2007))), .ineligible)
    }
}
