import XCTest
@testable import FTServices

final class UDPReachabilityTests: XCTestCase {
    func testConstantsArePinned() {
        XCTAssertEqual(UDPReachability.attempts, 3)
        XCTAssertEqual(UDPReachability.attemptTimeoutSeconds, 1)
    }

    func testMatches() {
        XCTAssertTrue(UDPReachability.matches(sent: "abc123", received: Data("abc123".utf8)))
        XCTAssertFalse(UDPReachability.matches(sent: "abc123", received: Data()))
        XCTAssertFalse(UDPReachability.matches(sent: "abc123", received: Data("zzz999".utf8)))
        XCTAssertFalse(UDPReachability.matches(sent: "abc123", received: Data("abc".utf8)))
        XCTAssertFalse(UDPReachability.matches(sent: "abc123", received: Data("abc123\n".utf8)))
        XCTAssertFalse(UDPReachability.matches(sent: "abc123", received: Data("abc123extra".utf8)))
        XCTAssertFalse(UDPReachability.matches(sent: "", received: Data()))
    }

    func testWarningTCPClauseVariants() {
        XCTAssertEqual(
            UDPReachability.warning(hostPort: 15001, runtime: .docker, attempts: 3, timeoutSeconds: 1, tcpReached: nil, cause: nil),
            "⚠️ services: 127.0.0.1:15001/udp (published by docker) did not answer 3 probes of 1s each")
        XCTAssertEqual(
            UDPReachability.warning(hostPort: 15001, runtime: .docker, attempts: 3, timeoutSeconds: 1, tcpReached: true, cause: nil),
            "⚠️ services: 127.0.0.1:15001/udp (published by docker) did not answer 3 probes of 1s each; TCP on the same path did answer")
        XCTAssertEqual(
            UDPReachability.warning(hostPort: 15001, runtime: .apple, attempts: 3, timeoutSeconds: 1, tcpReached: false, cause: nil),
            "⚠️ services: 127.0.0.1:15001/udp (published by apple) did not answer 3 probes of 1s each; TCP on the same path did not answer either")
    }

    func testWarningWithCauseAndFractionalTimeout() {
        XCTAssertEqual(
            UDPReachability.warning(hostPort: 15001, runtime: .docker, attempts: 3, timeoutSeconds: 1, tcpReached: true, cause: "because"),
            "⚠️ services: 127.0.0.1:15001/udp (published by docker) did not answer 3 probes of 1s each; TCP on the same path did answer — because")
        XCTAssertEqual(
            UDPReachability.warning(hostPort: 20, runtime: .docker, attempts: 2, timeoutSeconds: 0.5, tcpReached: nil, cause: "c"),
            "⚠️ services: 127.0.0.1:20/udp (published by docker) did not answer 2 probes of 0.5s each — c")
    }

    func testReachedLine() {
        XCTAssertEqual(UDPReachability.reachedLine(hostPort: 15001, attempt: 1),
                       "→ services: UDP path 127.0.0.1:15001/udp answered on probe 1")
    }

    func testUsesSSHForwarder() {
        func read(_ s: String) -> Bool? { RancherPortForwarding.usesSSHForwarder(settingsJSON: Data(s.utf8)) }
        XCTAssertEqual(read(#"{"experimental":{"virtualMachine":{"sshPortForwarder":true}}}"#), true)
        XCTAssertEqual(read(#"{"experimental":{"virtualMachine":{"sshPortForwarder":false}}}"#), false)
        XCTAssertNil(read(#"{"experimental":{"virtualMachine":{}}}"#))
        XCTAssertNil(read(#"{"version":1}"#))
        XCTAssertNil(read("{not json"))
        XCTAssertNil(read(#"{"experimental":{"virtualMachine":{"sshPortForwarder":"true"}}}"#))
        XCTAssertNil(read(#"{"experimental":{"virtualMachine":{"sshPortForwarder":1}}}"#))
    }

    func testSettingsSubpathIsPinned() {
        XCTAssertEqual(RancherPortForwarding.settingsSubpath, "Library/Preferences/rancher-desktop/settings.json")
    }
}
