import XCTest
@testable import FTServices

final class ServicesLeaseTests: XCTestCase {
    private func lease(pid: Int32 = 4242) -> ServicesLease {
        ServicesLease(
            pid: pid, pidStartedAt: "2026-10-14T01:02:03Z", runtime: "docker", endpoint: "/var/run/docker.sock",
            prefix: "fleetest-0123456789ab", generation: "g1", workspace: "/ws", project: "demo", profile: "run1",
            approvedServices: ["db", "api"], containers: ["fleetest-0123456789ab-db": "c1"],
            networks: ["fleetest-0123456789ab": "n1"], relay: "fleetest-0123456789ab-relay", udpCheck: nil,
            publishedPorts: [.init(hostIP: "127.0.0.1", hostPort: 15432, proto: "tcp", service: "db")],
            adbReverse: [.init(serial: "emulator-5554", hostPort: 15432)], secretNames: ["TOKEN"],
            childProcesses: [.init(pid: 99, startedAt: "2026-10-14T01:02:04Z")], phase: .running)
    }

    func testRoundTrip() throws {
        let original = lease()
        let raw = try XCTUnwrap(ServicesLeaseFile.encode(original))
        XCTAssertEqual(ServicesLeaseFile.decode(raw), original)
        XCTAssertEqual(original.schemaVersion, 1)
        XCTAssertNil(ServicesLeaseFile.decode("{}"))
    }

    func testFileNameBuildAndParse() {
        let name = ServicesLeaseFile.fileName(pid: 4242, prefix: "fleetest-0123456789ab")
        XCTAssertEqual(name, "4242~fleetest-0123456789ab.json")
        let parsed = ServicesLeaseFile.parse(fileName: name)
        XCTAssertEqual(parsed?.pid, 4242)
        XCTAssertEqual(parsed?.prefix, "fleetest-0123456789ab")
        XCTAssertNil(ServicesLeaseFile.parse(fileName: "4242.json"))
        XCTAssertNil(ServicesLeaseFile.parse(fileName: "4242~.json"))
        XCTAssertNil(ServicesLeaseFile.parse(fileName: "x~p.json"))
        XCTAssertNil(ServicesLeaseFile.parse(fileName: "4242~p.txt"))
    }

    func testOrphanJudgementUsesPidAndStartTime() {
        let l = lease()
        XCTAssertFalse(ServicesLeaseFile.isOrphan(l) { pid, started in pid == 4242 && started == "2026-10-14T01:02:03Z" })
        XCTAssertTrue(ServicesLeaseFile.isOrphan(l) { _, _ in false })
        // pid は生きているが開始時刻が違う(再利用) = 呼び手の closure が false を返す
        XCTAssertTrue(ServicesLeaseFile.isOrphan(l) { _, started in started == "other" })
        XCTAssertTrue(ServicesLeaseFile.isOrphan(lease(pid: 0)) { _, _ in true })
    }
}
