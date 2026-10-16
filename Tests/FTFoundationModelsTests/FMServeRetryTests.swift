import Foundation
import FoundationModels
import XCTest
import FTCore
@testable import FTFoundationModels

final class FMServeRetryTests: XCTestCase {
    private actor Barrier {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            let held = waiters
            waiters.removeAll()
            held.forEach { $0.resume() }
        }
    }

    private func aborted() -> NSError {
        NSError(domain: "ModelManagerServices.InferenceError", code: 2008)
    }

    private func decode(_ data: Data?) throws -> FMServeWire.Response {
        try JSONDecoder().decode(FMServeWire.Response.self, from: XCTUnwrap(data))
    }

    private func idle(_ activity: FMServeActivity) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while activity.snapshot.activeRequests != 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(activity.snapshot.activeRequests, 0)
    }

    func testTranscribeAndScreenRetryOnceWithSameInputWhileHoldingOwnership() async throws {
        for kind in [FMServeWire.Kind.transcribe, .screen] {
            let activity = FMServeActivity()
            let request = FMServeWire.Request(kind: kind, png: Data([1, 2, 3]), expected: "private expected state")
            let calls = LockedValue(0)
            let logs = LockedValue<[String]>([])
            let failure = aborted()
            let result = await FMServeServer.handle(try JSONEncoder().encode(request), executable: "test", stamp: "test",
                                                   activity: activity, log: { line in logs.withLock { $0.append(line) } },
                                                   operation: { received in
                XCTAssertEqual(received, request)
                XCTAssertEqual(activity.snapshot.activeRequests, 1)
                XCTAssertNil(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}))
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 1 { throw failure }
                return .answered(text: "recovered", pass: false, reason: "answered")
            })
            let response = try decode(result)
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.retryCount, 1)
            XCTAssertEqual(response.text, "recovered")
            XCTAssertEqual(response.pass, false)
            XCTAssertEqual(calls.value, 2)
            XCTAssertTrue(logs.value.contains { $0.contains("attempt=1 failed") && $0.contains("code=2008") })
            XCTAssertTrue(logs.value.contains { $0.contains("retry=1 started") })
            XCTAssertTrue(logs.value.contains { $0.contains("retry=1 ended status=answered") })
            XCTAssertFalse(logs.value.joined().contains("private expected state"))
        }
    }

    func testRetryFailureReturnsOneFailedResponseAndNeverStartsThirdAttempt() async throws {
        let calls = LockedValue(0)
        let failure = aborted()
        let raw = await FMServeServer.handle(try JSONEncoder().encode(FMServeWire.Request(kind: .transcribe)),
                                            executable: "test", stamp: "test", activity: FMServeActivity(), operation: { _ in
            calls.withLock { $0 += 1 }
            throw failure
        })
        let response = try decode(raw)
        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.retryCount, 1)
        XCTAssertEqual(calls.value, 2)
    }

    func testProbeDoesNotRetryCandidateFailure() async throws {
        let calls = LockedValue(0)
        let failure = aborted()
        let raw = await FMServeServer.handle(try JSONEncoder().encode(FMServeWire.Request(kind: .probe)),
                                            executable: "test", stamp: "test", activity: FMServeActivity(), operation: { _ in
            calls.withLock { $0 += 1 }
            throw failure
        })
        XCTAssertEqual(try decode(raw).retryCount, 0)
        XCTAssertEqual(calls.value, 1)
    }

    func testLoadFailureAndCancellationOverrideCandidateAtServerBoundary() async throws {
        let excluded: [any Error] = [NSError(domain: "ModelManagerServices.InferenceError", code: 2007),
                                    NSError(domain: "com.apple.SensitiveContentAnalysisML", code: 15),
                                    CancellationError()]
        for excluded in excluded {
            let calls = LockedValue(0)
            let failure = NSError(domain: "wrapper", code: 1,
                                  userInfo: [NSMultipleUnderlyingErrorsKey: [aborted(), excluded] as [any Error]])
            let raw = await FMServeServer.handle(try JSONEncoder().encode(FMServeWire.Request(kind: .transcribe)),
                                                executable: "test", stamp: "test", activity: FMServeActivity(), operation: { _ in
                calls.withLock { $0 += 1 }
                throw failure
            })
            XCTAssertEqual(try decode(raw).status, .failed)
            XCTAssertEqual(try decode(raw).retryCount, 0)
            XCTAssertEqual(calls.value, 1)
        }
    }

    func testLegacyAndCurrentRefusalsOverrideCandidateAndReturnRefused() async throws {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "blocked")
        var refusals: [any Error] = [LanguageModelSession.GenerationError.guardrailViolation(context),
                                    LanguageModelSession.GenerationError.refusal(.init(transcriptEntries: []), context)]
        if #available(macOS 27, *) {
            refusals.append(LanguageModelError.guardrailViolation(.init(debugDescription: "blocked")))
            refusals.append(LanguageModelError.refusal(.init(explanation: "blocked", debugDescription: "blocked")))
        }
        for refusal in refusals {
            let calls = LockedValue(0)
            let failure = NSError(domain: "wrapper", code: 1,
                                  userInfo: [NSMultipleUnderlyingErrorsKey: [aborted(), refusal] as [any Error]])
            let raw = await FMServeServer.handle(try JSONEncoder().encode(FMServeWire.Request(kind: .screen)),
                                                executable: "test", stamp: "test", activity: FMServeActivity(), operation: { _ in
                calls.withLock { $0 += 1 }
                throw failure
            })
            XCTAssertEqual(try decode(raw).status, .refused)
            XCTAssertEqual(try decode(raw).retryCount, 0)
            XCTAssertEqual(calls.value, 1)
        }
    }

    func testCurrentTimeoutOverridesCandidate() async throws {
        guard #available(macOS 27, *) else { return }
        let calls = LockedValue(0)
        let failure = NSError(domain: "wrapper", code: 1, userInfo: [NSMultipleUnderlyingErrorsKey:
            [aborted(), LanguageModelError.timeout(.init(debugDescription: "expired"))] as [any Error]])
        let raw = await FMServeServer.handle(try JSONEncoder().encode(FMServeWire.Request(kind: .screen)),
                                            executable: "test", stamp: "test", activity: FMServeActivity(), operation: { _ in
            calls.withLock { $0 += 1 }
            throw failure
        })
        XCTAssertEqual(try decode(raw).retryCount, 0)
        XCTAssertEqual(calls.value, 1)
    }

    func testRefusalOnRetryRetainsRetryCount() async throws {
        let calls = LockedValue(0)
        let failure = aborted()
        let refusal = LanguageModelSession.GenerationError.guardrailViolation(.init(debugDescription: "blocked"))
        let raw = await FMServeServer.handle(try JSONEncoder().encode(FMServeWire.Request(kind: .screen)),
                                            executable: "test", stamp: "test", activity: FMServeActivity(), operation: { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { throw failure }
            throw refusal
        })
        XCTAssertEqual(try decode(raw).status, .refused)
        XCTAssertEqual(try decode(raw).retryCount, 1)
        XCTAssertEqual(calls.value, 2)
    }

    func testDoesNotRetryWhenRemainingBudgetIsShorterThanFirstAttempt() async throws {
        let calls = LockedValue(0)
        let failure = aborted()
        let raw = await FMServeServer.handle(try JSONEncoder().encode(FMServeWire.Request(kind: .transcribe)),
                                            executable: "test", stamp: "test", activity: FMServeActivity(),
                                            deadlineSeconds: 0.5, operation: { _ in
            calls.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(300))
            throw failure
        })
        XCTAssertEqual(try decode(raw).retryCount, 0)
        XCTAssertEqual(calls.value, 1)
    }

    func testCancelledParentDoesNotRetryNoncooperativeFirstAttempt() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let started = expectation(description: "initial inference started")
        let calls = LockedValue(0)
        let failure = aborted()
        let payload = try JSONEncoder().encode(FMServeWire.Request(kind: .transcribe))
        let task = Task {
            await FMServeServer.handle(payload, executable: "test", stamp: "test", activity: activity, operation: { _ in
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 1 { started.fulfill() }
                await release.wait()
                throw failure
            })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await release.release()
        let response = try decode(await task.value)
        XCTAssertEqual(response.retryCount, 0)
        XCTAssertEqual(calls.value, 1)
    }

    func testAdmissionWaitConsumesOriginalBudgetBeforeFirstAttempt() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let waiting = expectation(description: "request queued behind warm")
        let warm = try XCTUnwrap(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }) {
            await release.wait()
        })
        let calls = LockedValue(0)
        let failure = aborted()
        let payload = try JSONEncoder().encode(FMServeWire.Request(kind: .transcribe))
        let task = Task {
            await FMServeServer.handle(payload, executable: "test", stamp: "test", activity: activity,
                                       deadlineSeconds: 0.5, log: { line in
                if line.hasPrefix("request waiting") { waiting.fulfill() }
            }, operation: { _ in
                calls.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(150))
                throw failure
            })
        }
        await fulfillment(of: [waiting], timeout: 1)
        try await Task.sleep(for: .milliseconds(250))
        await release.release()
        await warm.value
        let response = try decode(await task.value)
        XCTAssertEqual(response.retryCount, 0)
        XCTAssertEqual(calls.value, 1)
    }

    func testLateCandidateAfterTimeoutNeverStartsRetry() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let started = expectation(description: "initial inference started")
        let calls = LockedValue(0)
        let failure = aborted()
        let payload = try JSONEncoder().encode(FMServeWire.Request(kind: .transcribe))
        let task = Task {
            await FMServeServer.handle(payload, executable: "test", stamp: "test", activity: activity,
                                       deadlineSeconds: 0.05, operation: { _ in
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 1 { started.fulfill() }
                await release.wait()
                throw failure
            })
        }
        await fulfillment(of: [started], timeout: 1)
        let response = try decode(await task.value)
        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.retryCount, 0)
        XCTAssertEqual(activity.snapshot.overdueRequests, 1)
        await release.release()
        await idle(activity)
        XCTAssertEqual(calls.value, 1)
    }

    func testRetryTimeoutRetainsCountAndOwnershipUntilActualCompletion() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let started = expectation(description: "retry started")
        let calls = LockedValue(0)
        let failure = aborted()
        let payload = try JSONEncoder().encode(FMServeWire.Request(kind: .transcribe))
        let task = Task {
            await FMServeServer.handle(payload, executable: "test", stamp: "test", activity: activity,
                                       deadlineSeconds: 0.05, operation: { _ in
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 1 { throw failure }
                started.fulfill()
                await release.wait()
                return .answered(text: "late", pass: nil, reason: nil)
            })
        }
        await fulfillment(of: [started], timeout: 1)
        let response = try decode(await task.value)
        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.retryCount, 1)
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(activity.snapshot.overdueRequests, 1)
        XCTAssertNil(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}))
        await release.release()
        await idle(activity)
    }

    func testAnotherOverdueRequestPreventsRetryOfAlreadyRunningRequest() async throws {
        let activity = FMServeActivity()
        let firstRelease = Barrier()
        let secondRelease = Barrier()
        let firstStarted = expectation(description: "first request started")
        let secondStarted = expectation(description: "second request started before timeout")
        let first = Task {
            await activity.request(deadlineSeconds: 0.5, log: { _ in }, onCompletion: {}) {
                firstStarted.fulfill()
                await firstRelease.wait()
                return 1
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        let calls = LockedValue(0)
        let failure = aborted()
        let payload = try JSONEncoder().encode(FMServeWire.Request(kind: .screen))
        let second = Task {
            await FMServeServer.handle(payload, executable: "test", stamp: "test", activity: activity, operation: { _ in
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 1 { secondStarted.fulfill() }
                await secondRelease.wait()
                throw failure
            })
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        _ = await first.value
        XCTAssertEqual(activity.snapshot.overdueRequests, 1)
        await secondRelease.release()
        let response = try decode(await second.value)
        XCTAssertEqual(response.retryCount, 0)
        XCTAssertEqual(calls.value, 1)
        await firstRelease.release()
        await idle(activity)
    }

    func testWireRequiresRetryCountAndPinsVersion() throws {
        XCTAssertEqual(FMServeWire.protocolVersion, 4)
        let encoded = try JSONEncoder().encode(FMServeWire.Response(status: .failed, retryCount: 1,
                                                                  executable: "test", buildStamp: "test"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["retryCount"] as? Int, 1)
        object.removeValue(forKey: "retryCount")
        XCTAssertThrowsError(try JSONDecoder().decode(FMServeWire.Response.self,
                                                     from: JSONSerialization.data(withJSONObject: object)))
    }
}
