import FTServices
import Foundation
import XCTest
@testable import fleetest

/// 計画が置いた `<gateway>` と NO_PROXY の内部サブネットは、ネットワークを作ってから分かる値で埋める
final class ServicesSessionProxyEntryTests: XCTestCase {
    private let addresses = RuntimeListing.NetworkAddresses(gateway: "192.168.64.1", subnet: "192.168.64.0/24")

    func testGatewayPlaceholderIsReplacedAndTheSubnetIsAddedToNoProxy() {
        XCTAssertEqual(ServicesSession.resolveProxyEntry(EnvEntry(key: "HTTP_PROXY", value: "http://<gateway>:8899"), addresses: addresses),
                       "http://192.168.64.1:8899")
        XCTAssertEqual(ServicesSession.resolveProxyEntry(EnvEntry(key: "NO_PROXY", value: "db,localhost"), addresses: addresses),
                       "db,localhost,192.168.64.0/24")
        XCTAssertEqual(ServicesSession.resolveProxyEntry(EnvEntry(key: "no_proxy", value: "db,192.168.64.0/24"), addresses: addresses),
                       "db,192.168.64.0/24", "既にあるサブネットは重ねない")
    }

    func testWithoutAddressesTheEntryIsLeftAsIs() {
        XCTAssertEqual(ServicesSession.resolveProxyEntry(EnvEntry(key: "HTTP_PROXY", value: "http://fleetest-x-relay:8899"), addresses: nil),
                       "http://fleetest-x-relay:8899")
        XCTAssertEqual(ServicesSession.resolveProxyEntry(EnvEntry(key: "NO_PROXY", value: "db"), addresses: nil), "db")
        XCTAssertNil(ServicesSession.resolveProxyEntry(EnvEntry(key: "X", value: nil), addresses: addresses))
    }
}

/// healthcheck が尽きたときの失敗文に、最後に失敗した検査の事実を添える(捨てるとコンテナのログしか残らず、
/// 検査のコマンド自体が実行できない = イメージに bash が無い、が「サーバーは 200 なのに失敗」に見えた)
extension ServicesSessionProxyEntryTests {
    func testLastHealthcheckFactCarriesExitCodeAndOutputTail() {
        let result = RuntimeCLIResult(status: 127, output: "line1\nline2\nline3\nexec: \"bash\": executable file not found in $PATH\n",
                                      timedOut: false)
        XCTAssertEqual(ServicesSession.lastHealthcheckFact(result),
                       "last healthcheck: exit 127: line2 | line3 | exec: \"bash\": executable file not found in $PATH")
    }

    func testLastHealthcheckFactWithoutOutputIsTheExitCodeOnly() {
        XCTAssertEqual(ServicesSession.lastHealthcheckFact(RuntimeCLIResult(status: 1, output: "\n", timedOut: false)),
                       "last healthcheck: exit 1")
    }

    func testLastHealthcheckFactForATimeoutSaysSo() {
        XCTAssertEqual(ServicesSession.lastHealthcheckFact(RuntimeCLIResult(status: -1, output: "timed out after 5s", timedOut: true)),
                       "last healthcheck: timed out after 5s")
    }

    /// 失敗の throw が事実を添えていること(配線の走査。waitReady は CLI を要するので単体で通せない)
    func testHealthcheckFailureThrowCarriesTheLastProbe() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ServicesSession.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let failed = try XCTUnwrap(text.range(of: "case .failed(let reason):"))
        let body = text[failed.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("Self.lastHealthcheckFact("), "healthcheck の失敗文に最後の検査の事実が無い")
        XCTAssertTrue(text.contains("if !result.succeeded { lastFailedProbe = result }"), "失敗した検査を控えていない")
    }
}
