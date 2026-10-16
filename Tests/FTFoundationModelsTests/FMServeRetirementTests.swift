import Foundation
import XCTest
import FTCore
@testable import FTFoundationModels

final class FMServeRetirementTests: XCTestCase {
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

    private func identity(version: Int = FMServeWire.protocolVersion,
                          executable: String = "/runner/fleetest", stamp: String = "7-8",
                          status: FMServeWire.Status = .ok) -> FMServeWire.Identity {
        .init(status: status, serverVersion: version, executable: executable, buildStamp: stamp)
    }

    private func retire(_ activity: FMServeActivity, stops: LockedValue<Int>,
                        target: FMServeWire.Identity? = nil,
                        replacementVersion: Int = FMServeWire.protocolVersion,
                        controlVersion: Int = FMServeWire.retirementProtocolVersion) async throws -> FMServeWire.RetirementResponse {
        let request = FMServeWire.RetirementRequest(target: target ?? identity(), replacementVersion: replacementVersion,
                                                     controlVersion: controlVersion)
        let raw = await FMServeServer.handle(try JSONEncoder().encode(request), executable: "/runner/fleetest", stamp: "7-8",
                                            activity: activity, requestStop: { stops.withLock { $0 += 1 } },
                                            operation: { _ in
            XCTFail("retirement called an inference operation")
            return .answered(text: nil, pass: nil, reason: nil)
        })
        return try JSONDecoder().decode(FMServeWire.RetirementResponse.self, from: XCTUnwrap(raw))
    }

    func testIdleRetirementClosesInferenceAndWarmAdmissionBeforeStopping() async throws {
        let activity = FMServeActivity()
        let stops = LockedValue(0)
        let calls = LockedValue(0)
        let response = try await retire(activity, stops: stops, target: identity(status: .versionMismatch))
        XCTAssertEqual(response.outcome, .retiring)
        XCTAssertEqual(response.controlVersion, FMServeWire.retirementProtocolVersion)
        XCTAssertEqual(response.identity.serverVersion, FMServeWire.protocolVersion)
        XCTAssertEqual(response.identity.executable, "/runner/fleetest")
        XCTAssertEqual(response.identity.buildStamp, "7-8")
        XCTAssertEqual(stops.value, 1)
        let rejected = FMServeActivity.RequestContext(deadlineSeconds: 5)
        let requestResult = await activity.request(context: rejected, log: { _ in }, onCompletion: {}) { _ in
            calls.withLock { $0 += 1 }
            return 12
        }
        XCTAssertNil(requestResult)
        XCTAssertTrue(rejected.wasRejectedForRetirement)
        for kind in [FMServeWire.Kind.transcribe, .screen, .probe] {
            let payload = try JSONEncoder().encode(FMServeWire.Request(kind: kind))
            let answer = await FMServeServer.handle(payload, executable: "/runner/fleetest", stamp: "7-8",
                                                   activity: activity, operation: { _ in
                calls.withLock { $0 += 1 }
                return .answered(text: "unexpected", pass: true, reason: nil)
            })
            XCTAssertNil(answer, "retirement rejection was encoded as an FM failure instead of closing the connection")
        }
        let warm = activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }) {
            calls.withLock { $0 += 1 }
        }
        if let warm { await warm.value }
        XCTAssertNil(warm)
        XCTAssertEqual(calls.value, 0, "retirement left an inference or warm admission open")
    }

    func testActiveAndOverdueInferenceKeepTheServerRunningUntilActualCompletion() async throws {
        let activity = FMServeActivity()
        let stops = LockedValue(0)
        let release = Barrier()
        let started = expectation(description: "inference started")
        let finished = expectation(description: "noncooperative inference finished")
        let acceptedContext = LockedValue<FMServeActivity.RequestContext?>(nil)
        let request = Task {
            let context = FMServeActivity.RequestContext(deadlineSeconds: 0.05)
            acceptedContext.withLock { $0 = context }
            return await activity.request(context: context, log: { _ in }, onCompletion: { finished.fulfill() }) { _ in
                started.fulfill()
                await release.wait()
                return 12
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let context = try XCTUnwrap(acceptedContext.value)
        let active = try await retire(activity, stops: stops)
        XCTAssertEqual(active.outcome, .busy)
        XCTAssertEqual(stops.value, 0)
        let timedOut = await request.value
        XCTAssertNil(timedOut)
        XCTAssertFalse(context.wasRejectedForRetirement)
        XCTAssertEqual(activity.snapshot.overdueRequests, 1)
        let overdue = try await retire(activity, stops: stops)
        XCTAssertEqual(overdue.outcome, .busy)
        XCTAssertEqual(stops.value, 0)
        await release.release()
        await fulfillment(of: [finished], timeout: 1)
        // onCompletionより後にfinishRequestが所有権を返すため、後続要求を通して解放の境界まで待つ。
        let next = await activity.request(deadlineSeconds: 5, log: { _ in }, onCompletion: {}, operation: { 13 })
        XCTAssertEqual(next, 13, "busy response changed admission state")
        let idle = try await retire(activity, stops: stops)
        XCTAssertEqual(idle.outcome, .retiring)
        XCTAssertEqual(stops.value, 1)
        XCTAssertFalse(context.wasRejectedForRetirement, "later retirement changed the earlier timeout's cause")
    }

    func testRetirementRejectionClosesTheSocketAsClientUnavailable() async throws {
        let activity = FMServeActivity()
        XCTAssertTrue(activity.tryRetireIfIdle())
        let socket = "/tmp/ftfmret-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let stop = LockedValue(false)
        let exit = LockedValue<Int32>(-1)
        let calls = LockedValue(0)
        let done = DispatchSemaphore(value: 0)
        Thread {
            let code = FramedUnixSocket.serve(socketPath: socket, requestDeadlineSeconds: 1, tickMilliseconds: 10,
                                              shouldStop: { stop.value }, onTick: {}, handle: { payload in
                await FMServeServer.handle(payload, executable: "/runner/fleetest", stamp: "7-8", activity: activity,
                                           requestStop: {}, operation: { _ in
                    calls.withLock { $0 += 1 }
                    return .answered(text: "unexpected", pass: nil, reason: nil)
                })
            }, log: { _ in })
            exit.withLock { $0 = code }
            done.signal()
        }.start()
        defer {
            stop.withLock { $0 = true }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(exit.value, 0)
            try? FileManager.default.removeItem(atPath: socket + ".lock")
        }
        let client = FMServeClient(socketPath: socket, deadlineSeconds: 1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var listening = false
        while ContinuousClock.now < deadline {
            if let status = try? await client.status(), status.status == .ok {
                listening = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(listening)
        do {
            _ = try await client.send(FMServeWire.Request(kind: .transcribe))
            XCTFail("retirement rejection was received as an FM inference result")
        } catch let error as FMServeError {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(calls.value, 0)
    }

    func testWarmAndItsWaitingRequestPreventRetirement() async throws {
        let activity = FMServeActivity()
        let stops = LockedValue(0)
        let release = Barrier()
        let started = expectation(description: "warm started")
        let queued = expectation(description: "request waiting behind warm")
        let warm = try XCTUnwrap(activity.startWarm(deadlineSeconds: 5, log: { _ in }, onCompletion: { _ in }) {
            started.fulfill()
            await release.wait()
        })
        await fulfillment(of: [started], timeout: 1)
        let warming = try await retire(activity, stops: stops)
        XCTAssertEqual(warming.outcome, .busy)
        let request = Task {
            await activity.request(deadlineSeconds: 5, log: { line in
                if line.hasPrefix("request waiting") { queued.fulfill() }
            }, onCompletion: {}, operation: { 14 })
        }
        await fulfillment(of: [queued], timeout: 1)
        let waiting = try await retire(activity, stops: stops)
        XCTAssertEqual(waiting.outcome, .busy)
        XCTAssertEqual(stops.value, 0)
        await release.release()
        await warm.value
        let result = await request.value
        XCTAssertEqual(result, 14, "busy response cancelled a waiting request")
        let idle = try await retire(activity, stops: stops)
        XCTAssertEqual(idle.outcome, .retiring)
        XCTAssertEqual(stops.value, 1)
    }

    func testRegisteringRequestPreventsRetirementBeforeAdmissionTaskRuns() async throws {
        let activity = FMServeActivity()
        let stops = LockedValue(0)
        let release = Barrier()
        let registering = expectation(description: "request reserved before admission")
        let request = Task {
            await activity.request(deadlineSeconds: 5, log: { _ in }, onCompletion: {}, beforeAdmission: {
                registering.fulfill()
                await release.wait()
            }, operation: { 15 })
        }
        await fulfillment(of: [registering], timeout: 1)
        XCTAssertEqual(activity.snapshot.activeRequests, 0)
        XCTAssertEqual(activity.snapshot.waitingRequests, 0)
        let busy = try await retire(activity, stops: stops)
        XCTAssertEqual(busy.outcome, .busy, "retirement ignored the request reservation")
        XCTAssertEqual(stops.value, 0)
        await release.release()
        let result = await request.value
        XCTAssertEqual(result, 15)
        let idle = try await retire(activity, stops: stops)
        XCTAssertEqual(idle.outcome, .retiring)
        XCTAssertEqual(stops.value, 1)
    }

    func testIdentityMismatchAndOlderReplacementCannotCloseAdmission() async throws {
        let mismatches: [(FMServeWire.Identity, Int, FMServeWire.RetirementResponse.Outcome)] = [
            (identity(version: FMServeWire.protocolVersion - 1), FMServeWire.protocolVersion, .identityMismatch),
            (identity(executable: "/dev/fleetest"), FMServeWire.protocolVersion, .identityMismatch),
            (identity(stamp: "old"), FMServeWire.protocolVersion, .identityMismatch),
            (identity(), FMServeWire.protocolVersion - 1, .newerServer),
        ]
        for (target, replacement, expected) in mismatches {
            let activity = FMServeActivity()
            let stops = LockedValue(0)
            let response = try await retire(activity, stops: stops, target: target, replacementVersion: replacement)
            XCTAssertEqual(response.outcome, expected)
            XCTAssertEqual(stops.value, 0)
            let result = await activity.request(deadlineSeconds: 5, log: { _ in }, onCompletion: {}, operation: { 16 })
            XCTAssertEqual(result, 16, "rejected retirement closed admission")
            let idle = try await retire(activity, stops: stops)
            XCTAssertEqual(idle.outcome, .retiring)
            XCTAssertEqual(stops.value, 1)
        }
    }

    func testUnknownControlVersionDoesNotStopOrCloseAdmission() async throws {
        let activity = FMServeActivity()
        let stops = LockedValue(0)
        let rejected = try await retire(activity, stops: stops, controlVersion: FMServeWire.retirementProtocolVersion + 1)
        XCTAssertEqual(rejected.outcome, .unsupported)
        XCTAssertEqual(stops.value, 0)
        let result = await activity.request(deadlineSeconds: 5, log: { _ in }, onCompletion: {}, operation: { 17 })
        XCTAssertEqual(result, 17)
        let idle = try await retire(activity, stops: stops, replacementVersion: FMServeWire.protocolVersion + 1)
        XCTAssertEqual(idle.outcome, .retiring)
        XCTAssertEqual(stops.value, 1)
    }

    func testLegacyShutdownCannotStopNewServerWhileActiveOrIdle() async throws {
        let activity = FMServeActivity()
        let stops = LockedValue(0)
        let release = Barrier()
        let started = expectation(description: "inference started before shutdown")
        let request = Task {
            await activity.request(deadlineSeconds: 5, log: { _ in }, onCompletion: {}) {
                started.fulfill()
                await release.wait()
                return 18
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let payload = try JSONEncoder().encode(FMServeWire.Request(kind: .shutdown))
        let busyData = await FMServeServer.handle(payload, executable: "/runner/fleetest", stamp: "7-8",
                                                activity: activity, requestStop: { stops.withLock { $0 += 1 } })
        let busy = try JSONDecoder().decode(FMServeWire.Identity.self, from: XCTUnwrap(busyData))
        XCTAssertEqual(busy.status, .failed)
        XCTAssertEqual(stops.value, 0)
        await release.release()
        let result = await request.value
        XCTAssertEqual(result, 18, "shutdown changed active admission state")
        let idleData = await FMServeServer.handle(payload, executable: "/runner/fleetest", stamp: "7-8",
                                                activity: activity, requestStop: { stops.withLock { $0 += 1 } })
        let idle = try JSONDecoder().decode(FMServeWire.Identity.self, from: XCTUnwrap(idleData))
        XCTAssertEqual(idle.status, .failed)
        XCTAssertEqual(stops.value, 0, "a legacy caller stopped the new server using its peer's protocol version")
        let after = await activity.request(deadlineSeconds: 5, log: { _ in }, onCompletion: {}, operation: { 19 })
        XCTAssertEqual(after, 19, "rejected legacy shutdown closed admission")
    }
}
