// SpringBoard の照会(/systemalert・/systemui/covering)は目印を1問聞くだけなので、上限は interaction。
// session(45s)にすると、ランナーが死んでいる・塞がっているときに tap の前の照会が 45s を払い、
// 1手で 96s(シナリオ 117s)になった

import XCTest

final class SystemAlertProbeTimeoutTests: XCTestCase {

    func testSpringBoardProbesUseTheInteractionTimeout() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTBridgeClient/BridgeClient.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for path in ["\"/systemalert\"", "\"/systemui/covering\""] {
            let start = try XCTUnwrap(source.range(of: path), "\(path) の呼び出しが見つからない")
            let call = source[start.lowerBound...].prefix(120)
            XCTAssertTrue(call.contains("timeout: interactionTimeout"), "\(path) の上限が interaction でない: \(call)")
        }
    }
}
