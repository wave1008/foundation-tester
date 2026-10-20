import Foundation
import XCTest
@testable import FTCore

final class FMServeAlignmentTests: XCTestCase {
    private func path() -> String { "/tmp/ftfma-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock" }
    private let executable = URL(fileURLWithPath: "/runner/fleetest")

    private func temporaryExecutable() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ftfma-\(UUID().uuidString)")
        // 属性が読めないパスは既存のdecideが保守的にreuseするため、実ファイルで更新済みを表す。
        try Data("rebuilt executable".utf8).write(to: file)
        return file
    }

    private func identity(version: Int = FMServeWire.protocolVersion,
                          executable: String = "/dev/fleetest", stamp: String = "old") -> FMServeWire.Identity {
        .init(status: version == FMServeWire.protocolVersion ? .ok : .versionMismatch,
              serverVersion: version, executable: executable, buildStamp: stamp)
    }

    private func serve(path: String, stop: LockedValue<Bool> = LockedValue(false),
                       handler: @escaping @Sendable (Data) async -> Data?) -> () -> Void {
        let done = DispatchGroup()
        done.enter()
        Thread {
            let code = FramedUnixSocket.serve(socketPath: path, requestDeadlineSeconds: 3, tickMilliseconds: 20,
                                              shouldStop: { stop.value }, onTick: {}, handle: handler, log: { _ in })
            XCTAssertEqual(code, 0)
            done.leave()
        }.start()
        let until = Date().addingTimeInterval(3)
        while !FramedUnixSocket.isServed(path: path), Date() < until { usleep(1_000) }
        XCTAssertTrue(FramedUnixSocket.isServed(path: path))
        return {
            stop.withLock { $0 = true }
            XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        }
    }

    /// 枠を呼び手が握っている間は待って取り直し、空けば押さえる。待ち切ったら理由を言って断る(プロセスは止めない)
    func testHeldSlotIsRetriedWithinTheWaitAndThenRefusedWithAReason() async throws {
        let attempts = LockedValue(0)
        let lease = try await FMServeAlignment.holdMaintenance(within: 3) {
            attempts.withLock { $0 += 1 }
            if attempts.value < 3 { throw FMCallSlots.MaintenanceError(description: "held", slotHeld: true) }
            return 7
        }
        XCTAssertEqual(lease as? Int, 7)
        XCTAssertEqual(attempts.value, 3)
        let start = ContinuousClock.now
        do {
            _ = try await FMServeAlignment.holdMaintenance(within: 0.3) {
                throw FMCallSlots.MaintenanceError(description: "held", slotHeld: true)
            }
            XCTFail("握られたままなのに押さえられた")
        } catch let failure as FMServeAlignment.Failure {
            XCTAssertTrue(failure.description.contains("kept holding an FM slot"), failure.description)
            XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(300))
        }
    }

    /// 待っても直らない失敗(開けない・通常ファイルでない)は待たずにそのまま返す
    func testNonContentionMaintenanceErrorIsNotRetried() async {
        let attempts = LockedValue(0)
        do {
            _ = try await FMServeAlignment.holdMaintenance(within: 3) {
                attempts.withLock { $0 += 1 }
                throw FMCallSlots.MaintenanceError(description: "not a regular file")
            }
            XCTFail("投げるはず")
        } catch {
            XCTAssertTrue(error is FMCallSlots.MaintenanceError, "\(error)")
        }
        XCTAssertEqual(attempts.value, 1)
    }

    func testNoServerDoesNotAcquireSlotsOrLoadAModel() async throws {
        let result = try await FMServeAlignment.align(socketPath: path(), executable: executable, stamp: "new",
                                                      holdMaintenance: { XCTFail("slots acquired"); return 0 },
                                                      spawn: { _, _ in XCTFail("model loaded"); return false })
        XCTAssertEqual(result, .notRunning)
    }

    func testMatchingServerIsReusedWithoutRetirementOrSpawn() async throws {
        let peer = identity(executable: executable.path, stamp: "new")
        let kinds = LockedValue<[String]>([])
        let socket = path()
        let stop = serve(path: socket) { data in
            let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            kinds.withLock { $0.append(object["kind"] as! String) }
            return try! JSONEncoder().encode(peer)
        }
        defer { stop() }
        let result = try await FMServeAlignment.align(socketPath: socket, executable: executable, stamp: "new",
                                                      holdMaintenance: { XCTFail("slots acquired"); return 0 },
                                                      spawn: { _, _ in XCTFail("server restarted"); return false })
        XCTAssertEqual(result, .reused)
        XCTAssertEqual(kinds.value, ["status"])
    }

    func testLegacyAndNewerServersAreNeverSentAStopRequest() async throws {
        for version in [2, 3, FMServeWire.protocolVersion + 1] {
            let peer = identity(version: version)
            let kinds = LockedValue<[String]>([])
            let socket = path()
            let stop = serve(path: socket) { data in
                let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                kinds.withLock { $0.append(object["kind"] as! String) }
                return try! JSONEncoder().encode(peer)
            }
            do {
                _ = try await FMServeAlignment.align(socketPath: socket, executable: executable, stamp: "new",
                                                     holdMaintenance: { XCTFail("slots acquired"); return 0 },
                                                     spawn: { _, _ in XCTFail("server restarted"); return false })
                XCTFail("unsafe server accepted")
            } catch let error as FMServeAlignment.Failure {
                XCTAssertTrue(error.description.contains("no process was stopped"))
            }
            XCTAssertEqual(kinds.value, ["status"])
            stop()
        }
    }

    func testBusyServerIsNotStoppedOrReplaced() async throws {
        let peer = identity()
        let attempts = LockedValue(0)
        let socket = path()
        let stop = serve(path: socket) { data in
            if let request = try? JSONDecoder().decode(FMServeWire.RetirementRequest.self, from: data) {
                XCTAssertEqual(request.target, peer)
                attempts.withLock { $0 += 1 }
                return try! JSONEncoder().encode(FMServeWire.RetirementResponse(identity: peer, outcome: .busy))
            }
            return try! JSONEncoder().encode(peer)
        }
        defer { stop() }
        do {
            _ = try await FMServeAlignment.align(socketPath: socket, executable: executable, stamp: "new", waitSeconds: 0.05,
                                                 holdMaintenance: { 0 },
                                                 spawn: { _, _ in XCTFail("busy server replaced"); return false })
            XCTFail("busy server accepted")
        } catch let error as FMServeAlignment.Failure {
            XCTAssertTrue(error.description.contains("still busy"))
        }
        XCTAssertEqual(attempts.value, 1)
        XCTAssertTrue(FramedUnixSocket.isServed(path: socket))
    }

    func testOtherCloneIsRetiredAndReplacementIdentityIsVerified() async throws {
        try await handover(replacementPath: executable.path, replacementStamp: "new", expectSuccess: true)
    }

    func testBuildWaitsForRetirementAndHoldsSocketOwnership() async throws {
        try await handover(replacementPath: executable.path, replacementStamp: "new", expectSuccess: true,
                           buildFirst: true, matchingBeforeBuild: true)
    }

    func testBuildWithoutRunningServerHoldsOwnershipAndDoesNotStartFM() async throws {
        let socket = path()
        let built = LockedValue(false)
        let result = try await FMServeAlignment.align(socketPath: socket, executable: executable, stamp: "before",
                                                      holdMaintenance: { 0 },
                                                      spawn: { _, _ in XCTFail("FM was not running before the build"); return false },
                                                      build: {
            XCTAssertNil(FramedUnixSocket.acquireOwnership(path: socket), "another FM daemon could start during the build")
            built.withLock { $0 = true }
            return FMServeAlignment.Artifact(executable: self.executable, stamp: "after")
        })
        XCTAssertEqual(result, .notRunning)
        XCTAssertTrue(built.value)
        XCTAssertTrue(FramedUnixSocket.isReleased(path: socket))
    }

    func testBuildFailureDoesNotSpawnFMAndReleasesSocketOwnership() async throws {
        let socket = path()
        do {
            _ = try await FMServeAlignment.align(socketPath: socket, executable: executable, stamp: "before",
                                                 holdMaintenance: { 0 },
                                                 spawn: { _, _ in XCTFail("failed build started FM"); return false },
                                                 build: { throw NSError(domain: "BuildFailure", code: 23) })
            XCTFail("build failure was ignored")
        } catch {
            XCTAssertEqual((error as NSError).domain, "BuildFailure")
            XCTAssertEqual((error as NSError).code, 23)
        }
        XCTAssertTrue(FramedUnixSocket.isReleased(path: socket))
    }

    /// install.sh の形: 保守の親はビルド前の版なので、起こし直さずに返す(新版の照合で誤って失敗しない)
    func testBuildWithoutRestartRetiresThenBuildsAndDoesNotStartFM() async throws {
        let peer = identity()
        let stopOld = LockedValue(false)
        let requests = LockedValue<[String]>([])
        let socket = path()
        let cleanupOld = serve(path: socket, stop: stopOld) { data in
            if (try? JSONDecoder().decode(FMServeWire.RetirementRequest.self, from: data)) != nil {
                requests.withLock { $0.append("retire") }
                stopOld.withLock { $0 = true }
                return try! JSONEncoder().encode(FMServeWire.RetirementResponse(identity: peer, outcome: .retiring))
            }
            requests.withLock { $0.append("status") }
            return try! JSONEncoder().encode(peer)
        }
        defer { cleanupOld() }
        let built = LockedValue(false)
        let result = try await FMServeAlignment.align(
            socketPath: socket, executable: executable, stamp: "before", holdMaintenance: { 0 },
            spawn: { _, _ in XCTFail("FM was started again after the build"); return false },
            build: {
                XCTAssertEqual(requests.value, ["status", "retire"], "the build started before FM retirement")
                built.withLock { $0 = true }
                return FMServeAlignment.Artifact(executable: self.executable, stamp: "new")
            },
            restartAfterBuild: false)
        XCTAssertEqual(result, .retiredForBuild)
        XCTAssertTrue(built.value)
        XCTAssertTrue(FramedUnixSocket.isReleased(path: socket))
    }

    func testBusyIsRetriedOnlyUntilTheServerReportsIdle() async throws {
        try await handover(replacementPath: executable.path, replacementStamp: "new", expectSuccess: true, busyFirst: true)
    }

    func testSocketReleaseHasItsOwnBudgetAfterRetirementIsAccepted() async throws {
        // busyの再照会まで100ms、受諾後の解放まで600ms。退役待ち300msの残りを流用すると失敗する。
        try await handover(replacementPath: executable.path, replacementStamp: "new", expectSuccess: true,
                           busyFirst: true, retirementWaitSeconds: 0.3, releaseDelayMilliseconds: 600)
    }

    func testDifferentProcessWinningTheSocketIsNotReportedAsAligned() async throws {
        try await handover(replacementPath: "/other/fleetest", replacementStamp: "new", expectSuccess: false)
    }

    func testWrongReplacementBuildIsNotReportedAsAligned() async throws {
        try await handover(replacementPath: executable.path, replacementStamp: "unexpected", expectSuccess: false)
    }

    private func handover(replacementPath: String, replacementStamp: String, expectSuccess: Bool,
                          busyFirst: Bool = false, buildFirst: Bool = false, matchingBeforeBuild: Bool = false,
                          retirementWaitSeconds: Double = FMServeHost.retirementWaitSeconds,
                          releaseDelayMilliseconds: Int = 0) async throws {
        let peer = matchingBeforeBuild ? identity(executable: executable.path, stamp: "before") : identity()
        let replacement = identity(executable: replacementPath, stamp: replacementStamp)
        let stopOld = LockedValue(false)
        let held = LockedValue(false)
        let requests = LockedValue<[String]>([])
        let socket = path()
        let cleanupOld = serve(path: socket, stop: stopOld) { data in
            if let request = try? JSONDecoder().decode(FMServeWire.RetirementRequest.self, from: data) {
                XCTAssertTrue(held.value, "the maintenance slots were not held during retirement")
                XCTAssertEqual(request.target, peer)
                XCTAssertEqual(request.replacementVersion, FMServeWire.protocolVersion)
                requests.withLock { $0.append("retire") }
                if busyFirst, requests.value.filter({ $0 == "retire" }).count == 1 {
                    return try! JSONEncoder().encode(FMServeWire.RetirementResponse(identity: peer, outcome: .busy))
                }
                if releaseDelayMilliseconds > 0 {
                    Task {
                        try? await Task.sleep(for: .milliseconds(releaseDelayMilliseconds))
                        stopOld.withLock { $0 = true }
                    }
                } else {
                    stopOld.withLock { $0 = true }
                }
                return try! JSONEncoder().encode(FMServeWire.RetirementResponse(identity: peer, outcome: .retiring))
            }
            requests.withLock { $0.append("status") }
            return try! JSONEncoder().encode(peer)
        }
        var cleanupNew: (() -> Void)?
        defer { cleanupOld(); cleanupNew?() }
        let built = LockedValue(false)
        let buildOperation: (() async throws -> FMServeAlignment.Artifact)? = buildFirst ? {
            XCTAssertTrue(held.value)
            XCTAssertEqual(requests.value, ["status", "retire"], "the build started before FM retirement")
            XCTAssertNil(FramedUnixSocket.acquireOwnership(path: socket), "the build did not reserve the FM socket")
            built.withLock { $0 = true }
            return FMServeAlignment.Artifact(executable: self.executable, stamp: "new")
        } : nil
        do {
            let result = try await FMServeAlignment.align(socketPath: socket, executable: executable,
                                                          stamp: buildFirst ? "before" : "new",
                                                          waitSeconds: retirementWaitSeconds,
                                                          holdMaintenance: { held.withLock { $0 = true }; return 0 },
                                                          spawn: { binary, target in
                XCTAssertTrue(held.value)
                XCTAssertEqual(built.value, buildFirst, "FM was started before its executable was built")
                XCTAssertEqual(binary, self.executable)
                XCTAssertEqual(target, socket)
                cleanupOld()
                cleanupNew = self.serve(path: socket) { _ in try! JSONEncoder().encode(replacement) }
                return true
            }, build: buildOperation)
            XCTAssertTrue(expectSuccess, "a different replacement was reported as aligned")
            XCTAssertEqual(result, .replaced)
        } catch let error as FMServeAlignment.Failure {
            XCTAssertFalse(expectSuccess, error.description)
            XCTAssertTrue(error.description.contains("another FM process owns"))
        }
        XCTAssertEqual(requests.value, busyFirst ? ["status", "retire", "retire"] : ["status", "retire"])
    }

    func testNewerServerIsPreservedEvenWhenItsExecutableWasRebuilt() async {
        XCTAssertEqual(FMServeHost.decide(identity(version: FMServeWire.protocolVersion + 1, stamp: "old"),
                                         executable: executable.path, buildStamp: "new", serverExecutableStamp: "new"), .leave(.versionMismatch))
        var lines: [String] = []
        let result = await FMServeHost.ensureRunning(client: FMServeClient(socketPath: path()), executable: executable,
                                                     stamp: "new", initialStatus: identity(version: FMServeWire.protocolVersion + 1),
                                                     spawn: { _, _ in XCTFail("newer server replaced"); return false },
                                                     log: { lines.append($0) })
        XCTAssertNil(result)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("speaks protocol 5, this process 4") == true)
        XCTAssertFalse(lines.first?.contains("stayed busy") == true)
    }

    func testCancellationNeverSendsRetirement() async throws {
        let peer = identity()
        let kinds = LockedValue<[String]>([])
        let socket = path()
        let stop = serve(path: socket) { data in
            let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            kinds.withLock { $0.append(object["kind"] as! String) }
            if object["kind"] as? String == "retire" {
                return try! JSONEncoder().encode(FMServeWire.RetirementResponse(identity: peer, outcome: .retiring))
            }
            return try! JSONEncoder().encode(peer)
        }
        defer { stop() }
        let replacementExecutable = executable
        let operation = Task {
            try await FMServeAlignment.align(socketPath: socket, executable: replacementExecutable, stamp: "new",
                                             holdMaintenance: { 0 },
                                             spawn: { _, _ in XCTFail("cancelled operation spawned a server"); return false })
        }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("cancellation was ignored") }
        catch is CancellationError {}
        XCTAssertEqual(kinds.value, ["status"])
    }

    func testNormalStartupRequiresSafeRetirementAcknowledgement() async throws {
        let executable = try temporaryExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }
        let cases: [([FMServeWire.RetirementResponse.Outcome], FMServeHost.LiveServerDecision)] = [
            ([.busy], .leave(.busy)), ([.retiring], .replace), ([.busy, .retiring], .replace)
        ]
        for (outcomes, expectedDecision) in cases {
            let peer = identity(executable: executable.path)
            let requests = LockedValue<[String]>([])
            let socket = path()
            let stop = serve(path: socket) { data in
                if let request = try? JSONDecoder().decode(FMServeWire.RetirementRequest.self, from: data) {
                    XCTAssertEqual(request.target, peer)
                    requests.withLock { $0.append("retire") }
                    let outcome = outcomes[min(requests.value.count - 1, outcomes.count - 1)]
                    return try! JSONEncoder().encode(FMServeWire.RetirementResponse(identity: peer, outcome: outcome))
                }
                requests.withLock { $0.append("status") }
                return try! JSONEncoder().encode(peer)
            }
            let decision = await FMServeHost.prepareExistingServer(peer, client: FMServeClient(socketPath: socket),
                                                                   executable: executable.path, buildStamp: "new",
                                                                   serverExecutableStamp: "new",
                                                                   waitSeconds: outcomes.count > 1 ? 1 : 0.05)
            XCTAssertEqual(decision, expectedDecision)
            XCTAssertEqual(requests.value, Array(repeating: "retire", count: outcomes.count))
            if expectedDecision == .leave(.busy) {
                var lines: [String] = []
                let result = await FMServeHost.ensureRunning(client: FMServeClient(socketPath: socket), executable: executable,
                                                             stamp: "new", initialStatus: peer, waitSeconds: 0.05,
                                                             spawn: { _, _ in XCTFail("busy server replaced"); return false },
                                                             log: { lines.append($0) })
                XCTAssertNil(result)
                XCTAssertEqual(lines, ["⚠️ The FM process stayed busy for 0 s; it was left running; FM checks are skipped here"])
                XCTAssertEqual(requests.value, ["retire", "retire"], "busy was reclassified as a failed query and status was retried")
            }
            stop()
        }
        let missing = await FMServeHost.prepareExistingServer(identity(executable: executable.path),
                                                               client: FMServeClient(socketPath: path()),
                                                               executable: executable.path, buildStamp: "new", serverExecutableStamp: "new")
        XCTAssertEqual(missing, .leave(.retirementQueryFailed))
    }

    func testNormalStartupSpawnsAfterAnotherCallerRetiredTheServer() async throws {
        let executable = try temporaryExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }
        let stamp = FMServeWire.buildStamp(executable: executable.path)
        let socket = path()
        let peer = identity(executable: executable.path)
        let replacement = identity(executable: executable.path, stamp: stamp)
        let stopOldFlag = LockedValue(false)
        let cleanupOld = serve(path: socket, stop: stopOldFlag) { payload in
            if let request = try? JSONDecoder().decode(FMServeWire.RetirementRequest.self, from: payload) {
                XCTAssertEqual(request.target, peer)
                stopOldFlag.withLock { $0 = true }
                return try! JSONEncoder().encode(FMServeWire.RetirementResponse(identity: peer, outcome: .retiring))
            }
            return try! JSONEncoder().encode(peer)
        }
        var cleanupNew: (() -> Void)?
        defer { cleanupOld(); cleanupNew?() }
        let client = FMServeClient(socketPath: socket, deadlineSeconds: 1)
        let observed = try await client.status()
        // runの最初のstatusと退役照会の間に、別の呼び手が退役を完了させる。
        let acknowledgement = try await client.retire(FMServeWire.RetirementRequest(target: observed))
        XCTAssertEqual(acknowledgement.outcome, .retiring)
        cleanupOld()
        XCTAssertTrue(FramedUnixSocket.isReleased(path: socket))
        var spawns = 0
        var lines: [String] = []
        let result = await FMServeHost.ensureRunning(client: client, executable: executable, stamp: stamp, initialStatus: observed,
                                                     spawn: { binary, target in
            spawns += 1
            XCTAssertEqual(binary, executable)
            XCTAssertEqual(target, socket)
            cleanupNew = self.serve(path: target) { _ in try! JSONEncoder().encode(replacement) }
            return true
        }, log: { lines.append($0) })
        XCTAssertEqual(result, socket)
        XCTAssertEqual(spawns, 1)
        XCTAssertTrue(lines.isEmpty, "a released socket left the run without FM: \(lines)")
    }

    func testNormalStartupRechecksIdentityBeforeReusingOrStartingAReplacement() async throws {
        let executable = try temporaryExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }
        let stamp = FMServeWire.buildStamp(executable: executable.path)
        let peer = identity(executable: executable.path)
        let cases: [(FMServeWire.Identity?, Bool)] = [
            (identity(executable: executable.path, stamp: stamp), true),
            (identity(version: FMServeWire.protocolVersion + 1, executable: executable.path, stamp: stamp), false),
            (peer, false), (nil, false),
            (.init(status: .failed, executable: executable.path, buildStamp: stamp), false)
        ]
        for (current, reusable) in cases {
            let socket = path()
            let requests = LockedValue<[String]>([])
            let cleanup = serve(path: socket) { payload in
                if (try? JSONDecoder().decode(FMServeWire.RetirementRequest.self, from: payload)) != nil {
                    requests.withLock { $0.append("retire") }
                    return nil
                }
                requests.withLock { $0.append("status") }
                return current.map { try! JSONEncoder().encode($0) }
            }
            var lines: [String] = []
            let result = await FMServeHost.ensureRunning(client: FMServeClient(socketPath: socket, deadlineSeconds: 1),
                                                         executable: executable, stamp: stamp, initialStatus: peer,
                                                         spawn: { _, _ in XCTFail("an owned socket was replaced"); return false },
                                                         log: { lines.append($0) })
            XCTAssertEqual(result, reusable ? socket : nil)
            XCTAssertEqual(requests.value, ["retire", "status"], "retirement failure did not refresh the current identity")
            XCTAssertEqual(lines.isEmpty, reusable)
            if current == nil {
                XCTAssertEqual(lines, ["⚠️ The retiring FM process has not released its socket; FM checks are skipped here"])
            } else if !reusable {
                XCTAssertTrue(lines.first?.contains("retirement query failed") == true)
            }
            XCTAssertFalse(FramedUnixSocket.isReleased(path: socket), "a failed status query lost the live owner's lock")
            cleanup()
        }
    }

    func testNormalStartupWaitsForOwnershipReleaseAfterRetirementQueryFails() async throws {
        let executable = try temporaryExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }
        let stamp = FMServeWire.buildStamp(executable: executable.path)
        let socket = path()
        // acceptは閉じたが、応答の片付け中で所有ロックは残っている状態を再現する。
        let ownership = LockedValue(FramedUnixSocket.acquireOwnership(path: socket))
        XCTAssertNotNil(ownership.value)
        let release = Task {
            try? await Task.sleep(for: .milliseconds(250))
            ownership.withLock { $0 = nil }
        }
        var cleanup: (() -> Void)?
        defer { ownership.withLock { $0 = nil }; cleanup?() }
        var spawns = 0
        var lines: [String] = []
        let replacement = identity(executable: executable.path, stamp: stamp)
        let result = await FMServeHost.ensureRunning(client: FMServeClient(socketPath: socket, deadlineSeconds: 1),
                                                     executable: executable, stamp: stamp,
                                                     initialStatus: identity(executable: executable.path),
                                                     spawn: { _, target in
            spawns += 1
            XCTAssertNil(ownership.value, "a replacement was started before ownership was released")
            cleanup = self.serve(path: target) { _ in try! JSONEncoder().encode(replacement) }
            return true
        }, log: { lines.append($0) })
        await release.value
        XCTAssertEqual(result, socket)
        XCTAssertEqual(spawns, 1)
        XCTAssertTrue(lines.isEmpty, "the run lost FM during delayed ownership release: \(lines)")
    }

    func testSocketOwnershipIsHeldUntilTheLastHandlerWritesItsResponse() async throws {
        let socket = path()
        let stop = LockedValue(false)
        let exited = LockedValue(false)
        let release = LockedValue<CheckedContinuation<Void, Never>?>(nil)
        let started = expectation(description: "handler entered")
        let stopObserved = expectation(description: "accept loop observed stop")
        let done = expectation(description: "server returned")
        Thread {
            let code = FramedUnixSocket.serve(socketPath: socket, requestDeadlineSeconds: 3, tickMilliseconds: 20,
                                              shouldStop: {
                if stop.value { stopObserved.fulfill(); return true }
                return false
            }, onTick: {}, handle: { data in
                await withCheckedContinuation { continuation in
                    release.withLock { $0 = continuation }
                    started.fulfill()
                }
                return data
            }, log: { _ in })
            XCTAssertEqual(code, 0)
            exited.withLock { $0 = true }
            done.fulfill()
        }.start()
        let until = Date().addingTimeInterval(3)
        while !FramedUnixSocket.isServed(path: socket), Date() < until { usleep(1_000) }
        let request = Task {
            try await FramedUnixSocket.exchangeAsync(path: socket, frame: FramedUnixSocket.encode("answer"), seconds: 3)
        }
        await fulfillment(of: [started], timeout: 3)
        stop.withLock { $0 = true }
        await fulfillment(of: [stopObserved], timeout: 3)
        XCTAssertFalse(FramedUnixSocket.isReleased(path: socket))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(exited.value, "the server released socket ownership before its response was written")
        release.withLock { $0?.resume(); $0 = nil }
        let answer = try await request.value
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: answer), "answer")
        await fulfillment(of: [done], timeout: 3)
        XCTAssertFalse(FramedUnixSocket.isServed(path: socket))
    }
}
