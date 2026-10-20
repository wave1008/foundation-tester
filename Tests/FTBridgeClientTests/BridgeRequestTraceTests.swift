import Foundation
import XCTest
@testable import FTBridgeClient

/// FT_BRIDGE_TRACE の1行(調査用。既定は出さない)。指定した id の枠だけを抜き、本文は先頭だけ
final class BridgeRequestTraceTests: XCTestCase {
    func testParseNeedsAtLeastOneIdentifier() {
        XCTAssertNil(BridgeRequestTrace.parse(nil))
        XCTAssertNil(BridgeRequestTrace.parse(""))
        XCTAssertNil(BridgeRequestTrace.parse(" , "))
        XCTAssertEqual(BridgeRequestTrace.parse("row_i_57, txt_infinite_count"), ["row_i_57", "txt_infinite_count"])
    }

    func testSnapshotLineCarriesOnlyTheWatchedFrames() throws {
        let response = Data("""
        {"elements":[
          {"ref":1,"type":"button","identifier":"row_i_57","frame":{"x":0,"y":332,"width":402,"height":56}},
          {"ref":2,"type":"button","identifier":"row_i_58","frame":{"x":0,"y":388,"width":402,"height":56}}]}
        """.utf8)
        let started = Date(timeIntervalSince1970: 1_792_488_000)
        let text = BridgeRequestTrace.line(method: "GET", path: "/snapshot", query: nil, body: nil, status: 200,
                                           started: started, finished: started.addingTimeInterval(0.125),
                                           response: response, watched: ["row_i_57"])
        let trace = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["bridgeTrace"]
                                    as? [String: Any])
        XCTAssertEqual(trace["req"] as? String, "GET /snapshot")
        XCTAssertEqual(trace["ms"] as? Int, 125)
        XCTAssertEqual(trace["status"] as? Int, 200)
        XCTAssertEqual(trace["frames"] as? [String: [Double]], ["row_i_57": [0, 332, 402, 56]])
    }

    func testGestureLineCarriesTheBodyPrefix() throws {
        let body = Data(("{\"x\":201,\"y\":359.7" + String(repeating: " ", count: 400) + "}").utf8)
        let started = Date()
        let text = BridgeRequestTrace.line(method: "POST", path: "/tap", query: nil, body: body, status: nil,
                                           started: started, finished: started, response: nil, watched: ["row_i_57"])
        let trace = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["bridgeTrace"]
                                    as? [String: Any])
        XCTAssertEqual(trace["req"] as? String, "POST /tap")
        XCTAssertNil(trace["status"], "応答が無い(送れなかった)回は status を載せない")
        let recorded = try XCTUnwrap(trace["body"] as? String)
        XCTAssertTrue(recorded.hasPrefix("{\"x\":201,\"y\":359.7"))
        XCTAssertEqual(recorded.count, BridgeRequestTrace.bodyPrefixLength)
        XCTAssertNil(trace["frames"], "木以外の要求には枠を載せない")
    }
}
