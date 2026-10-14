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
