// プロキシの宛先検め。断る側(穴)と通す側(使えなくなる)の両方向を固定する。

import XCTest
@testable import FTCore

final class ProxyDestinationPolicyTests: XCTestCase {

    private let standard = ProxyDestinationPolicy.standard(
        ownAddresses: ["192.168.1.20", "2001:db8:aaaa::20"], deniedNetworks: ["192.168.64.0/24", "fd00::/8"])

    private func refused(_ policy: ProxyDestinationPolicy, _ address: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let picked) = policy.pick(resolved: [address]) {
            XCTFail("\(address) was accepted as \(picked)", file: file, line: line)
        }
    }

    private func accepted(_ policy: ProxyDestinationPolicy, _ address: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try? policy.pick(resolved: [address]).get(), address, file: file, line: line)
    }

    func testSpecialAddressesAreRefused() {
        for address in ["127.0.0.1", "127.255.255.254", "::1", "0.0.0.0", "0.1.2.3", "::",
                        "169.254.169.254", "fe80::1", "febf::1", "224.0.0.1", "239.255.255.255", "ff02::1",
                        "::ffff:127.0.0.1", "::ffff:169.254.1.1"] {
            refused(standard, address)
        }
    }

    func testOwnAddressesAndDeniedNetworksAreRefused() {
        for address in ["192.168.1.20", "2001:db8:aaaa::20", "::ffff:192.168.1.20",
                        "192.168.64.1", "192.168.64.255", "fd00::1", "fdff:1::2"] {
            refused(standard, address)
        }
    }

    func testPublicAddressesPass() {
        for address in ["93.184.216.34", "2606:4700::1", "192.168.65.1", "192.168.1.21", "fc00::1", "223.255.255.255"] {
            accepted(standard, address)
        }
    }

    func testFirstAcceptableAddressInResolverOrderIsPicked() throws {
        XCTAssertEqual(try standard.pick(resolved: ["::1", "127.0.0.1", "93.184.216.34", "2606:4700::1"]).get(),
                       "93.184.216.34")
        XCTAssertEqual(try standard.pick(resolved: ["2606:4700::1", "93.184.216.34"]).get(), "2606:4700::1")
    }

    func testRefusalNamesTheReasons() {
        guard case .failure(let refusal) = standard.pick(resolved: ["127.0.0.1", "192.168.64.5"]) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(refusal.reason, "127.0.0.1 is a loopback address; 192.168.64.5 is in a denied network")
        guard case .failure(let empty) = standard.pick(resolved: []) else { return XCTFail("expected a refusal") }
        XCTAssertEqual(empty.reason, "the name resolved to no address")
    }

    func testPermissivePassesLoopbackButStandardFlagIsTheOnlySwitchForSpecials() {
        accepted(.permissive, "127.0.0.1")
        accepted(.permissive, "::1")
        let lenient = ProxyDestinationPolicy(ownAddresses: [], deniedNetworks: ["10.0.0.0/8"], refuseSpecialAddresses: false)
        accepted(lenient, "127.0.0.1")
        refused(lenient, "10.1.2.3")
    }

    func testMalformedCIDRRefusesEverything() {
        for bad in ["10.0.0.0", "10.0.0.0/33", "fd00::/129", "abc/8", "10.0.0.0/", "10.0.0.0/-1", "10.0.0.0/8/8", "/8"] {
            let policy = ProxyDestinationPolicy(ownAddresses: [], deniedNetworks: [bad], refuseSpecialAddresses: true)
            refused(policy, "93.184.216.34")
        }
    }

    func testCIDRPrefixBoundaries() {
        let policy = ProxyDestinationPolicy(ownAddresses: [], deniedNetworks: ["10.0.0.0/9", "2001:db8::/33"],
                                            refuseSpecialAddresses: true)
        refused(policy, "10.127.255.255")
        accepted(policy, "10.128.0.0")
        refused(policy, "2001:db8:7fff::1")
        accepted(policy, "2001:db8:8000::1")
    }

    func testNonNumericAddressIsRefused() {
        refused(standard, "example.com")
    }

    func testCurrentInterfaceAddressesIncludeLoopbackWithoutScope() {
        let addresses = ProxyDestinationPolicy.currentInterfaceAddresses()
        XCTAssertTrue(addresses.contains("127.0.0.1"), "\(addresses)")
        XCTAssertFalse(addresses.contains { $0.contains("%") }, "\(addresses)")
    }

    /// 許されたアドレスは解決順のまま全部返し(呼び手が順に試す)、断ったものだけ落ちる
    func testAllowedKeepsTheResolutionOrderAndDropsOnlyTheRefused() throws {
        let standard = ProxyDestinationPolicy.standard(ownAddresses: ["10.0.0.9"], deniedNetworks: ["192.168.64.0/24"])
        XCTAssertEqual(try standard.allowed(resolved: ["::1", "2606:4700::1", "10.0.0.9", "93.184.216.34", "192.168.64.5"]).get(),
                       ["2606:4700::1", "93.184.216.34"])
        guard case .failure = standard.allowed(resolved: ["127.0.0.1", "10.0.0.9"]) else { return XCTFail("all refused") }
    }
}
