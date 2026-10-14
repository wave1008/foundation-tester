import Foundation
import XCTest
@testable import fleetest

/// ランタイムの `inspect` の JSON の読み方。fixture は実データの形(Docker の `State` / Apple Container 1.1.0 の `status`)。
final class RuntimeListingTests: XCTestCase {
    private func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }

    func testAppleStoppedContainerIsExitedWithoutExitCode() throws {
        let j = try json(#"[{"configuration":{"id":"ft-probe-exit"},"id":"ft-probe-exit","status":{"networks":[],"startedDate":"2026-10-14T10:18:32Z","state":"stopped"}}]"#)
        XCTAssertEqual(RuntimeListing.containerState(json: j, isDocker: false), .init(exited: true, exitCode: nil))
    }

    func testAppleRunningContainerIsNotExitedAndHasAddress() throws {
        let j = try json(#"[{"id":"x","status":{"networks":[{"hostname":"x","ipv4Address":"192.168.64.4/24","ipv4Gateway":"192.168.64.1","network":"default"}],"startedDate":"2026-10-14T10:19:14Z","state":"running"}}]"#)
        XCTAssertEqual(RuntimeListing.containerState(json: j, isDocker: false), .init(exited: false, exitCode: nil))
        XCTAssertEqual(RuntimeListing.appleAddress(json: j), "192.168.64.4")
    }

    func testAppleAddressIsNilUntilAssigned() throws {
        XCTAssertNil(RuntimeListing.appleAddress(json: try json(#"[{"id":"x","status":{"networks":[],"state":"running"}}]"#)))
    }

    func testDockerStateAndExitCode() throws {
        XCTAssertEqual(RuntimeListing.containerState(json: try json(#"[{"State":{"Status":"exited","ExitCode":3}}]"#), isDocker: true),
                       .init(exited: true, exitCode: 3))
        XCTAssertEqual(RuntimeListing.containerState(json: try json(#"[{"State":{"Status":"dead","ExitCode":137}}]"#), isDocker: true),
                       .init(exited: true, exitCode: 137))
        XCTAssertEqual(RuntimeListing.containerState(json: try json(#"[{"State":{"Status":"running","ExitCode":0}}]"#), isDocker: true),
                       .init(exited: false, exitCode: nil))
    }

    /// `network inspect`: Docker は IPAM.Config、Apple は status(1.1.0 の `network list --format json` と同じ形)
    func testNetworkAddressesForBothRuntimes() throws {
        let docker = try json(#"[{"Name":"fleetest-x","IPAM":{"Driver":"default","Config":[{"Subnet":"172.18.0.0/16","Gateway":"172.18.0.1"}]}}]"#)
        XCTAssertEqual(RuntimeListing.networkAddresses(json: docker, isDocker: true),
                       .init(gateway: "172.18.0.1", subnet: "172.18.0.0/16"))
        let apple = try json(#"[{"configuration":{"name":"fleetest-x","mode":"nat"},"id":"fleetest-x","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24","ipv6Subnet":"fd9e::/64"}}]"#)
        XCTAssertEqual(RuntimeListing.networkAddresses(json: apple, isDocker: false),
                       .init(gateway: "192.168.64.1", subnet: "192.168.64.0/24"))
        XCTAssertNil(RuntimeListing.networkAddresses(json: try json(#"[{"IPAM":{"Config":[]}}]"#), isDocker: true))
        XCTAssertNil(RuntimeListing.networkAddresses(json: try json(#"[{"status":{"state":"running"}}]"#), isDocker: true))
    }

    func testUnexpectedShapeIsNil() throws {
        XCTAssertNil(RuntimeListing.containerState(json: try json("[]"), isDocker: true))
        XCTAssertNil(RuntimeListing.containerState(json: try json(#"[{"State":{"Status":"exited"}}]"#), isDocker: false))
        XCTAssertNil(RuntimeListing.containerState(json: try json(#"[{"status":{"state":"stopped"}}]"#), isDocker: true))
    }
}
