import XCTest
@testable import fleetest

/// Docker の管理口(2375 / 2376)の非ループバック公開の検知。lsof は差し替え口で受ける。
final class DockerTCPExposureTests: XCTestCase {
    private let header = "COMMAND     PID     USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME\n"

    func testOnlyNonLoopbackListenersOfThatPortAreReported() {
        let output = header
            + "dockerd   4242 wave1008   7u  IPv4 0x1234      0t0  TCP *:2375 (LISTEN)\n"
            + "dockerd   4242 wave1008   8u  IPv4 0x1235      0t0  TCP 127.0.0.1:2375 (LISTEN)\n"
            + "socat     4300 wave1008   5u  IPv6 0x1236      0t0  TCP [::1]:2375 (LISTEN)\n"
            + "proxy     4301 wave1008   5u  IPv4 0x1237      0t0  TCP 192.168.1.5:2375 (LISTEN)\n"
            + "other     4302 wave1008   5u  IPv4 0x1238      0t0  TCP *:12375 (LISTEN)\n"
        XCTAssertEqual(DockerTCPExposure.nonLoopbackListeners(lsofOutput: output, port: 2375), [
            .init(port: 2375, address: "*", command: "dockerd"),
            .init(port: 2375, address: "192.168.1.5", command: "proxy"),
        ])
        XCTAssertEqual(DockerTCPExposure.nonLoopbackListeners(lsofOutput: output, port: 2376), [])
    }

    func testLoopbackJudgement() {
        for address in ["127.0.0.1", "127.0.0.2", "[::1]", "localhost"] { XCTAssertTrue(DockerTCPExposure.isLoopback(address), address) }
        for address in ["*", "0.0.0.0", "[::]", "192.168.1.5", "10.0.0.4"] { XCTAssertFalse(DockerTCPExposure.isLoopback(address), address) }
    }

    func testScanDistinguishesClearExposedAndUnknown() {
        XCTAssertEqual(DockerTCPExposure.scan(run: { _ in (1, "") }), .clear)
        let exposed = DockerTCPExposure.scan(run: { argv in
            argv.contains("-iTCP:2376") ? (0, self.header + "dockerd 1 u 7u IPv4 0x1 0t0 TCP 0.0.0.0:2376 (LISTEN)\n") : (1, "")
        })
        XCTAssertEqual(exposed, .exposed([.init(port: 2376, address: "0.0.0.0", command: "dockerd")]))
        XCTAssertEqual(DockerTCPExposure.scan(run: { _ in (2, "lsof: unsupported") }), .unknown(detail: "lsof exit 2"))
        // 片方の検査が失敗しても、確認できた公開口は捨てない(exposed > unknown)
        let mixed = DockerTCPExposure.scan(run: { argv in
            argv.contains("-iTCP:2375") ? (0, self.header + "dockerd 1 u 7u IPv4 0x1 0t0 TCP *:2375 (LISTEN)\n") : (2, "lsof: unsupported")
        })
        XCTAssertEqual(mixed, .exposed([.init(port: 2375, address: "*", command: "dockerd")]))
        XCTAssertEqual(DockerTCPExposure.scan(run: { _ in nil }), .unknown(detail: "lsof could not be started"))
        XCTAssertEqual(DockerTCPExposure.lsofArguments(port: 2375), ["/usr/sbin/lsof", "-nP", "-iTCP:2375", "-sTCP:LISTEN"])
        XCTAssertEqual(DockerTCPExposure.describe([.init(port: 2375, address: "*", command: "dockerd")]), "*:2375 (dockerd)")
    }
}

/// サービスの起動の門(`ServicesSession.refuseIfDockerAPIIsExposed`)。公開されていれば断り、見られなければ言って進む。
final class ServicesDockerExposureGateTests: XCTestCase {
    func testExposedRefusesWithTheListenerNamed() {
        XCTAssertThrowsError(try ServicesSession.refuseIfDockerAPIIsExposed(
            scan: { .exposed([.init(port: 2375, address: "*", command: "dockerd")]) }, log: { _ in })) { error in
            let detail = (error as? ServicesError)?.detail ?? ""
            XCTAssertTrue(detail.contains("Docker's API is published on TCP at *:2375 (dockerd)"), detail)
            XCTAssertTrue(detail.contains("the services are not started"), detail)
        }
    }

    func testClearAndUnknownDoNotRefuse() throws {
        var logs: [String] = []
        try ServicesSession.refuseIfDockerAPIIsExposed(scan: { .clear }, log: { logs.append($0) })
        XCTAssertEqual(logs, [])
        try ServicesSession.refuseIfDockerAPIIsExposed(scan: { .unknown(detail: "lsof exit 2") }, log: { logs.append($0) })
        XCTAssertEqual(logs, ["→ services: could not check whether Docker's API is published on TCP (lsof exit 2)"])
    }
}
