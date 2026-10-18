// 応答時間計測(`POST /responsePrepare` / `/responseCollect`)のワイヤ。ブリッジは null を明示で返す(Android v102〜)。

import XCTest
@testable import FTBridgeClient
import FTCore

final class ResponseMeasurementWireTests: XCTestCase {

    private func client(_ stub: RecordingStubServer) -> BridgeClient {
        BridgeClient(port: stub.port, interactionTimeout: 5, sessionTimeout: 5)
    }

    func testCollectDecodesExplicitNulls() async throws {
        let stub = try RecordingStubServer(
            body: #"{"downTimeMs":null,"firstFrameDelayMs":null,"reason":"noInjectedInput","lastDownTimeMs":null,"injections":0}"#)
        defer { stub.stop() }

        let result = try await client(stub).responseCollect()

        XCTAssertEqual(result, ResponseCollectResult(downTimeMs: nil, firstFrameDelayMs: nil,
                                                     reason: "noInjectedInput"))
        XCTAssertEqual(stub.paths, ["POST /responseCollect"])
    }

    func testCollectDecodesMeasuredValues() async throws {
        let stub = try RecordingStubServer(
            body: #"{"downTimeMs":123456,"firstFrameDelayMs":42,"reason":null,"lastDownTimeMs":123456,"injections":1}"#)
        defer { stub.stop() }

        let result = try await client(stub).responseCollect()

        XCTAssertEqual(result, ResponseCollectResult(downTimeMs: 123456, firstFrameDelayMs: 42,
                                                       lastDownTimeMs: 123456, injections: 1))
    }

    func testPreparePostsBothFieldsAndDecodes() async throws {
        let stub = try RecordingStubServer(body: #"{"quiet":true,"waitedMs":310,"reason":null}"#)
        defer { stub.stop() }

        let result = try await client(stub).responsePrepare(quietMs: 300, timeoutMs: 4000, observeMs: 5000)

        XCTAssertEqual(result, ResponsePrepareResult(quiet: true, waitedMs: 310))
        XCTAssertEqual(stub.paths, ["POST /responsePrepare"])
        let raw = try XCTUnwrap(stub.body(for: "POST /responsePrepare"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(json["quietMs"] as? Int, 300)
        XCTAssertEqual(json["timeoutMs"] as? Int, 4000)
        XCTAssertEqual(json["observeMs"] as? Int, 5000)
    }

    func testCollectDecodesLastDownAndInjections() async throws {
        let stub = try RecordingStubServer(
            body: #"{"downTimeMs":100,"firstFrameDelayMs":8,"reason":null,"lastDownTimeMs":250,"injections":3}"#)
        defer { stub.stop() }

        let result = try await client(stub).responseCollect()

        XCTAssertEqual(result, ResponseCollectResult(downTimeMs: 100, firstFrameDelayMs: 8,
                                                     lastDownTimeMs: 250, injections: 3))
    }

    func testObservationNotFoundDecodesNulls() async throws {
        let stub = try RecordingStubServer(
            body: #"{"found":false,"firstDownTimeMs":null,"lastDownTimeMs":null,"injections":null,"endedAtMs":null,"endReason":null,"reads":null,"trees":null,"truncated":null}"#)
        defer { stub.stop() }

        let result = try await client(stub).responseObservation(firstDownTimeMs: 777)

        XCTAssertFalse(result.found)
        XCTAssertNil(result.reads)
        XCTAssertNil(result.trees)
        XCTAssertNil(result.endReason)
        let raw = try XCTUnwrap(stub.body(for: "POST /responseObservation"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(json["firstDownTimeMs"] as? Int, 777)
    }

    func testObservationDecodesReadsAndTree() async throws {
        let snapshot = #"{"screen":{"x":0,"y":0,"width":1080,"height":2400},"elements":[],"truncatedCount":0}"#
        let body = #"{"found":true,"firstDownTimeMs":100,"lastDownTimeMs":100,"injections":1,"endedAtMs":900,"endReason":"nextInjection","reads":[{"startMs":110,"endMs":150,"ok":true},{"startMs":150,"endMs":400,"ok":false}],"trees":[{"readIndex":0,"snapshot":"# + snapshot + #"}],"truncated":false}"#
        let stub = try RecordingStubServer(body: body)
        defer { stub.stop() }

        let result = try await client(stub).responseObservation(firstDownTimeMs: 100)

        XCTAssertTrue(result.found)
        XCTAssertEqual(result.endReason, "nextInjection")
        XCTAssertEqual(result.endedAtMs, 900)
        XCTAssertEqual(result.reads, [.init(startMs: 110, endMs: 150, ok: true),
                                      .init(startMs: 150, endMs: 400, ok: false)])
        XCTAssertEqual(result.trees?.count, 1)
        XCTAssertEqual(result.trees?.first?.readIndex, 0)
        XCTAssertEqual(result.truncated, false)
    }

    func testObservationStopPostsAndDecodes() async throws {
        let stub = try RecordingStubServer(body: #"{"stopped":true}"#)
        defer { stub.stop() }

        try await client(stub).responseObservationStop()

        XCTAssertEqual(stub.paths, ["POST /responseObservationStop"])
    }
}
