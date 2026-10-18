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
            body: #"{"downTimeMs":null,"firstFrameDelayMs":null,"reason":"noInjectedInput"}"#)
        defer { stub.stop() }

        let result = try await client(stub).responseCollect()

        XCTAssertEqual(result, ResponseCollectResult(downTimeMs: nil, firstFrameDelayMs: nil,
                                                     reason: "noInjectedInput"))
        XCTAssertEqual(stub.paths, ["POST /responseCollect"])
    }

    func testCollectDecodesMeasuredValues() async throws {
        let stub = try RecordingStubServer(
            body: #"{"downTimeMs":123456,"firstFrameDelayMs":42,"reason":null}"#)
        defer { stub.stop() }

        let result = try await client(stub).responseCollect()

        XCTAssertEqual(result, ResponseCollectResult(downTimeMs: 123456, firstFrameDelayMs: 42))
    }

    func testPreparePostsBothFieldsAndDecodes() async throws {
        let stub = try RecordingStubServer(body: #"{"quiet":true,"waitedMs":310,"reason":null}"#)
        defer { stub.stop() }

        let result = try await client(stub).responsePrepare(quietMs: 300, timeoutMs: 4000)

        XCTAssertEqual(result, ResponsePrepareResult(quiet: true, waitedMs: 310))
        XCTAssertEqual(stub.paths, ["POST /responsePrepare"])
        let raw = try XCTUnwrap(stub.body(for: "POST /responsePrepare"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(json["quietMs"] as? Int, 300)
        XCTAssertEqual(json["timeoutMs"] as? Int, 4000)
    }
}
