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

    func testUnexpectedShapeIsNil() throws {
        XCTAssertNil(RuntimeListing.containerState(json: try json("[]"), isDocker: true))
        XCTAssertNil(RuntimeListing.containerState(json: try json(#"[{"State":{"Status":"exited"}}]"#), isDocker: false))
        XCTAssertNil(RuntimeListing.containerState(json: try json(#"[{"status":{"state":"stopped"}}]"#), isDocker: true))
    }
}
