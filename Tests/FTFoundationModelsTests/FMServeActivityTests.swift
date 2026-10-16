import Foundation
import XCTest
import FTCore
@testable import FTFoundationModels

final class FMServeActivityTests: XCTestCase {
    private actor Barrier {
        private var released = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            released = true
            let held = waiting
            waiting.removeAll()
            held.forEach { $0.resume() }
        }
    }

    private func response(_ data: Data?) throws -> FMServeWire.Response {
        try JSONDecoder().decode(FMServeWire.Response.self, from: XCTUnwrap(data))
    }

    func testAllInferenceKindsBlockWarmWhileRealRequestsRemainParallel() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let started = expectation(description: "all real requests started")
        started.expectedFulfillmentCount = 3
        let tasks = try [FMServeWire.Kind.transcribe, .screen, .probe].map { kind in
            let payload = try JSONEncoder().encode(FMServeWire.Request(kind: kind))
            return Task {
                await FMServeServer.handle(payload, executable: "test", stamp: "test", activity: activity,
                                           deadlineSeconds: 5, operation: { request in
                    started.fulfill()
                    await release.wait()
                    return .answered(text: request.kind.rawValue, pass: nil, reason: nil)
                })
            }
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 3, waitingRequests: 0, warming: false))
        XCTAssertNil(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}))
        await release.release()
        for task in tasks {
            let result = try response(await task.value)
            XCTAssertEqual(result.status, .ok)
        }
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 0, warming: false))
    }

    func testWarmHandsOwnershipToWaitingRealRequestsBeforeAnotherWarm() async throws {
        let activity = FMServeActivity()
        let warmRelease = Barrier()
        let realRelease = Barrier()
        let warmStarted = expectation(description: "warm started")
        let waiting = expectation(description: "real request queued")
        let realStarted = expectation(description: "real started after warm")
        let warm = try XCTUnwrap(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }) {
            warmStarted.fulfill()
            await warmRelease.wait()
        })
        await fulfillment(of: [warmStarted], timeout: 1)
        let payload = try JSONEncoder().encode(FMServeWire.Request(kind: .probe))
        let real = Task {
            await FMServeServer.handle(payload, executable: "test", stamp: "test", activity: activity,
                                       deadlineSeconds: 5, log: { line in
                if line.hasPrefix("request waiting") { waiting.fulfill() }
            }, operation: { _ in
                XCTAssertFalse(activity.snapshot.warming)
                realStarted.fulfill()
                await realRelease.wait()
                return .answered(text: nil, pass: nil, reason: nil)
            })
        }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 1, warming: true))
        await warmRelease.release()
        await warm.value
        // finishWarm が実要求を resume する前に所有権を渡していなければ、ここで次の暖機が入れる。
        XCTAssertNil(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}))
        await fulfillment(of: [realStarted], timeout: 1)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 1, waitingRequests: 0, warming: false))
        await realRelease.release()
        let result = try response(await real.value)
        XCTAssertEqual(result.status, .ok)
    }

    func testRequestTimeoutRetainsOwnershipUntilNoncooperativeInferenceCompletes() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let started = expectation(description: "inference started")
        let ended = expectation(description: "actual inference completed")
        let logs = LockedValue<[String]>([])
        let began = Date()
        let task = Task {
            await activity.request(deadlineSeconds: 0.05, log: { line in logs.withLock { $0.append(line) } },
                                   onCompletion: { ended.fulfill() }) {
                started.fulfill()
                await release.wait()
                return 7
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "応答の期限が非協調な推論の終了を待っている")
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 1, waitingRequests: 0, warming: false, overdueRequests: 1))
        XCTAssertNil(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}))
        XCTAssertTrue(logs.value.contains { $0.contains("request timed out") && $0.contains("activeRequests=1") })
        await release.release()
        await fulfillment(of: [ended], timeout: 1)
    }

    func testWarmTimeoutRetainsOwnershipAndRealRequestWaitsForActualCompletion() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let started = expectation(description: "warm inference started")
        let waiting = expectation(description: "real request queued after warm timeout")
        let logs = LockedValue<[String]>([])
        let warm = try XCTUnwrap(activity.startWarm(deadlineSeconds: 0.05,
                                                  log: { line in logs.withLock { $0.append(line) } },
                                                  onCompletion: { _ in }) {
            started.fulfill()
            await release.wait()
        })
        await fulfillment(of: [started], timeout: 1)
        await warm.value
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 0, warming: true))
        XCTAssertNil(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}))
        XCTAssertTrue(logs.value.contains { $0.contains("keep-warm timed out") && $0.contains("warming=true") })
        let real = Task {
            await activity.request(deadlineSeconds: 5, log: { line in
                if line.hasPrefix("request waiting") { waiting.fulfill() }
            }, onCompletion: {}) {
                XCTAssertFalse(activity.snapshot.warming)
                return 9
            }
        }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 1, warming: true))
        await release.release()
        let result = await real.value
        XCTAssertEqual(result, 9)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 0, warming: false))
    }

    func testNewRealRequestWaitsUntilTimedOutInferenceActuallyFinishes() async throws {
        let activity = FMServeActivity()
        let firstRelease = Barrier()
        let secondRelease = Barrier()
        let firstStarted = expectation(description: "first inference started")
        let secondWaiting = expectation(description: "second request queued behind overdue inference")
        let secondStarted = expectation(description: "second inference started after actual first completion")
        let firstPayload = try JSONEncoder().encode(FMServeWire.Request(kind: .probe))
        let first = Task {
            await FMServeServer.handle(firstPayload, executable: "test", stamp: "test", activity: activity,
                                       deadlineSeconds: 0.05, operation: { _ in
                firstStarted.fulfill()
                await firstRelease.wait()
                return .answered(text: nil, pass: nil, reason: nil)
            })
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        let firstResult = try response(await first.value)
        XCTAssertEqual(firstResult.status, .failed)
        let secondPayload = try JSONEncoder().encode(FMServeWire.Request(kind: .screen))
        let second = Task {
            await FMServeServer.handle(secondPayload, executable: "test", stamp: "test", activity: activity,
                                       deadlineSeconds: 5, log: { line in
                if line.hasPrefix("request waiting for unfinished timed-out inference;") { secondWaiting.fulfill() }
            }, operation: { _ in
                XCTAssertEqual(activity.snapshot.overdueRequests, 0)
                secondStarted.fulfill()
                await secondRelease.wait()
                return .answered(text: nil, pass: true, reason: "matched")
            })
        }
        await fulfillment(of: [secondWaiting], timeout: 1)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 1, waitingRequests: 1, warming: false, overdueRequests: 1))
        XCTAssertNil(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}))
        await firstRelease.release()
        await fulfillment(of: [secondStarted], timeout: 1)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 1, waitingRequests: 0, warming: false))
        XCTAssertNil(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}))
        await secondRelease.release()
        let secondResult = try response(await second.value)
        XCTAssertEqual(secondResult.status, .ok)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 0, warming: false))
    }

    func testQueuedTimeoutRemovesWaiterAndNeverStartsStaleInference() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let warmStarted = expectation(description: "warm started")
        let waiting = expectation(description: "real request queued")
        let calls = LockedValue(0)
        let warm = try XCTUnwrap(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }) {
            warmStarted.fulfill()
            await release.wait()
        })
        await fulfillment(of: [warmStarted], timeout: 1)
        let payload = try JSONEncoder().encode(FMServeWire.Request(kind: .transcribe))
        let real = Task {
            await FMServeServer.handle(payload, executable: "test", stamp: "test", activity: activity,
                                       deadlineSeconds: 0.05, log: { line in
                if line.hasPrefix("request waiting") { waiting.fulfill() }
            }, operation: { _ in
                calls.withLock { $0 += 1 }
                return .answered(text: "unexpected", pass: nil, reason: nil)
            })
        }
        await fulfillment(of: [waiting], timeout: 1)
        let result = try response(await real.value)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 0, warming: true),
                       "期限切れの待機継続が暖機の実際の完了まで残っている")
        await release.release()
        await warm.value
        XCTAssertEqual(calls.value, 0)
        let nextWarm = try XCTUnwrap(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}))
        await nextWarm.value
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 0, warming: false))
    }

    func testAcceptedRequestBlocksWarmBeforeAdmissionRuns() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let scheduled = expectation(description: "request accepted before admission runs")
        let calls = LockedValue(0)
        let real = Task {
            await activity.request(deadlineSeconds: 5, log: { _ in }, onCompletion: {},
                                   beforeAdmission: {
                scheduled.fulfill()
                await release.wait()
            }, operation: {
                calls.withLock { $0 += 1 }
                return 1
            })
        }
        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertNil(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}),
                     "実要求の op Task が門へ届く前に暖機が割り込んだ")
        await release.release()
        let result = await real.value
        XCTAssertEqual(result, 1)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 0, warming: false))
    }

    func testTimeoutBeforeAdmissionRunsRemovesIntent() async throws {
        let activity = FMServeActivity()
        let release = Barrier()
        let scheduled = expectation(description: "request accepted before admission runs")
        let resumed = expectation(description: "cancelled admission resumes")
        let calls = LockedValue(0)
        let real = Task {
            await activity.request(deadlineSeconds: 0.05, log: { _ in }, onCompletion: {},
                                   beforeAdmission: {
                scheduled.fulfill()
                await release.wait()
                resumed.fulfill()
            }, operation: {
                calls.withLock { $0 += 1 }
                return 1
            })
        }
        await fulfillment(of: [scheduled], timeout: 1)
        let result = await real.value
        XCTAssertNil(result)
        let nextWarm = try XCTUnwrap(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }, operation: {}),
                                    "実行前に期限切れになった要求の予約が残っている")
        await nextWarm.value
        await release.release()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 0, warming: false))
    }

    func testWarmFailureLogsUnderlyingErrorAndActivityCounts() async throws {
        let activity = FMServeActivity()
        let logs = LockedValue<[String]>([])
        let warm = try XCTUnwrap(activity.startWarm(deadlineSeconds: 5,
                                                  log: { line in logs.withLock { $0.append(line) } },
                                                  onCompletion: { _ in }) {
            throw NSError(domain: "FMWrapper", code: -1, userInfo: [NSUnderlyingErrorKey:
                NSError(domain: "ANE", code: 53, userInfo: [NSLocalizedDescriptionKey: "no memory"])])
        })
        await warm.value
        XCTAssertEqual(logs.value.count, 1)
        let message = try XCTUnwrap(logs.value.first)
        XCTAssertTrue(message.contains("keep-warm failed:"))
        XCTAssertTrue(message.contains("ANE(53): no memory"), "実際の入れ子のエラーが捨てられた")
        XCTAssertTrue(message.contains("activeRequests=0, waitingRequests=0, warming=true"))
        XCTAssertEqual(activity.snapshot, .init(activeRequests: 0, waitingRequests: 0, warming: false))
    }
}
