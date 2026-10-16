import Foundation
import XCTest
@testable import FTCore

final class FMServeIdentityTests: XCTestCase {
    private func path() -> String { "/tmp/ftfmid-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock" }

    private func serve(path: String, handler: @escaping @Sendable (FMServeWire.Request) -> Data) -> () -> Int32 {
        let stop = LockedValue(false)
        let exit = LockedValue<Int32>(-1)
        let done = DispatchSemaphore(value: 0)
        Thread {
            let code = FramedUnixSocket.serve(socketPath: path, requestDeadlineSeconds: 3, tickMilliseconds: 20,
                                              shouldStop: { stop.value }, onTick: {}, handle: { payload in
                guard let request = try? JSONDecoder().decode(FMServeWire.Request.self, from: payload) else { return nil }
                return handler(request)
            }, log: { _ in })
            exit.withLock { $0 = code }
            done.signal()
        }.start()
        let deadline = Date().addingTimeInterval(3)
        while !FramedUnixSocket.isServed(path: path), Date() < deadline { usleep(10_000) }
        XCTAssertTrue(FramedUnixSocket.isServed(path: path))
        return {
            stop.withLock { $0 = true }
            done.wait()
            return exit.value
        }
    }

    func testLegacyIdentityIsReadableButSamePayloadCannotBecomeInferenceResponse() async throws {
        let socket = path()
        let payload = Data("""
        {"status":"versionMismatch","serverVersion":2,"executable":"/a/fleetest","buildStamp":"old","error":"version mismatch"}
        """.utf8)
        let stop = serve(path: socket) { _ in payload }
        defer { XCTAssertEqual(stop(), 0) }
        let client = FMServeClient(socketPath: socket, deadlineSeconds: 3)
        let identity = try await client.status()
        XCTAssertEqual(identity.status, .versionMismatch)
        XCTAssertEqual(identity.serverVersion, 2)
        XCTAssertEqual(identity.executable, "/a/fleetest")
        XCTAssertEqual(identity.buildStamp, "old")
        XCTAssertThrowsError(try JSONDecoder().decode(FMServeWire.Response.self, from: payload))
        do {
            _ = try await client.send(FMServeWire.Request(kind: .transcribe))
            XCTFail("a control response was accepted as an inference result")
        } catch let error as FMServeError {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        }
    }

    func testEveryIdentityFieldIsRequired() throws {
        let complete: [String: Any] = ["status": "ok", "serverVersion": 2,
                                       "executable": "/a/fleetest", "buildStamp": "old"]
        for key in complete.keys {
            var missing = complete
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(FMServeWire.Identity.self,
                                                         from: JSONSerialization.data(withJSONObject: missing)), key)
        }
    }

    func testLegacyServerIsLeftRunningEvenAfterItsExecutableWasRebuilt() async throws {
        let socket = path()
        let requests = LockedValue<[FMServeWire.Request]>([])
        let acknowledged = LockedValue(false)
        let stop = serve(path: socket) { request in
            requests.withLock { $0.append(request) }
            if request.kind == .shutdown, request.version == 2 { acknowledged.withLock { $0 = true } }
            let status: FMServeWire.Status = request.version == 2 ? .ok : .versionMismatch
            return try! JSONEncoder().encode(FMServeWire.Identity(status: status, serverVersion: 2,
                                                                 executable: "/a/fleetest", buildStamp: "old"))
        }
        defer { XCTAssertEqual(stop(), 0) }
        let client = FMServeClient(socketPath: socket, deadlineSeconds: 3)
        let identity = try await client.status()
        let decision = await FMServeHost.prepareExistingServer(identity, client: client, executable: "/a/fleetest",
                                                               buildStamp: "new", serverExecutableStamp: "new")
        XCTAssertEqual(decision, .leave(.unsupportedRetirement))
        XCTAssertFalse(acknowledged.value, "a server without safe retirement was stopped")
        XCTAssertEqual(requests.value.map(\.kind), [.status])
    }

    func testOldClientLeavesNewServerRunningWithoutSendingShutdown() async throws {
        let socket = path()
        let requests = LockedValue<[FMServeWire.Request]>([])
        let stop = serve(path: socket) { request in
            requests.withLock { $0.append(request) }
            return try! JSONEncoder().encode(FMServeWire.Identity(status: .versionMismatch,
                                                                 serverVersion: FMServeWire.protocolVersion + 1,
                                                                 executable: "/a/fleetest", buildStamp: "new"))
        }
        defer { XCTAssertEqual(stop(), 0) }
        let client = FMServeClient(socketPath: socket, deadlineSeconds: 3)
        let identity = try await client.status()
        let decision = await FMServeHost.prepareExistingServer(identity, client: client, executable: "/a/fleetest",
                                                               buildStamp: "new", serverExecutableStamp: "new")
        XCTAssertEqual(decision, .leave(.versionMismatch))
        XCTAssertEqual(requests.value.map(\.kind), [.status])
        XCTAssertTrue(FramedUnixSocket.isServed(path: socket))
    }
}
