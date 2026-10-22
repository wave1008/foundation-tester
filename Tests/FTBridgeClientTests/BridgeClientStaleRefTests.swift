// ブリッジの「古い ref を撃たずに断る」応答(422 + reason)が型付きの DriverError.staleRef に写ることを固定する。
// 本文の文言ではなく構造化された reason で分岐する。

import XCTest
import FTCore
@testable import FTBridgeClient

final class BridgeClientStaleRefTests: XCTestCase {

    private func response(_ status: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "http://127.0.0.1:8123/tap")!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    func testReasonMapsToStaleRef() throws {
        let body = try JSONEncoder().encode(ErrorResponse(error: "moved", reason: BridgeAPI.staleRefReason))
        XCTAssertThrowsError(try BridgeClient.check(response: response(422), data: body)) { error in
            guard case DriverError.staleRef(let detail)? = error as? DriverError else {
                return XCTFail("staleRef になっていない: \(error)")
            }
            XCTAssertEqual(detail, "moved")
        }
    }

    /// アプリへの ref の撃ち(/tap /type /clear /press)は控えた期待を添え、システム UI の /systemui/tap は添えない
    /// (システム UI の ref はアプリの ref と別の番号の振り方)
    func testAppRefRequestsCarryTheExpectationAndSystemUITapDoesNot() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTBridgeClient/BridgeClient.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#"post("/tap", body: TapRequest(ref: ref, expect: refExpectations[ref],"#))
        XCTAssertTrue(text.contains(#"post("/press", body: PressRequest(ref: ref, duration: duration, expect: refExpectations[ref])"#))
        XCTAssertTrue(text.contains(#"post("/systemui/tap", body: TapRequest(ref: ref),"#))
    }

    /// 測定用のプローブは `FT_STALE_TAP_PROBE=1` のときだけ(既定は送らない = ランナーは撮り直さない)。
    /// 欄は省略時に JSON から消える(旧ブリッジにも新ブリッジにも既定のまま届く)
    func testStaleTapProbeIsOnlyForTheExplicitSwitch() throws {
        XCTAssertTrue(BridgeClient.staleTapProbeEnabled([BridgeClient.staleTapProbeKey: "1"]))
        for value in [nil, "0", "true", ""] as [String?] {
            let env = value.map { [BridgeClient.staleTapProbeKey: $0] } ?? [:]
            XCTAssertFalse(BridgeClient.staleTapProbeEnabled(env), "\(String(describing: value))")
        }
        let omitted = String(decoding: try JSONEncoder().encode(TapRequest(ref: 3)), as: UTF8.self)
        XCTAssertFalse(omitted.contains("probeStaleRef"), omitted)
        let sent = try JSONDecoder().decode(TapRequest.self,
                                            from: JSONEncoder().encode(TapRequest(ref: 3, probeStaleRef: true)))
        XCTAssertEqual(sent.probeStaleRef, true)
    }

    /// 理由の無い 422 は従来どおり badResponse(本文に stale-ref と書いてあっても写さない)
    func testPlain422StaysBadResponse() throws {
        let body = try JSONEncoder().encode(ErrorResponse(error: "stale-ref in the text only"))
        XCTAssertThrowsError(try BridgeClient.check(response: response(422), data: body)) { error in
            guard case DriverError.badResponse(let status, _)? = error as? DriverError else {
                return XCTFail("badResponse になっていない: \(error)")
            }
            XCTAssertEqual(status, 422)
        }
    }
}
