import XCTest
import FTCore
@testable import FTServices

final class ServicePolicyTests: XCTestCase {
    private let published = [
        ServicePublication(service: "db", containerPort: 5432, proto: .tcp, hostIP: "127.0.0.1", hostPort: 15432),
        ServicePublication(service: "api", containerPort: 9090, proto: .udp, hostIP: "127.0.0.1", hostPort: 19090),
    ]

    private func policy(_ runtime: ServiceRuntime) -> ServicePolicy {
        let docker = runtime == .docker
        return ServicePolicy(inputs: ServiceGatewayInputs(
            runtime: runtime,
            executable: docker ? "/usr/local/bin/docker" : "/opt/homebrew/bin/container",
            controlEnvironment: docker ? ["DOCKER_HOST=unix:///tmp/d.sock"] : [],
            containers: ["db": "fleetest-abc-db", "api": "fleetest-abc-api"],
            published: published))
    }

    private func refusal(_ d: ServiceGatewayDecision) -> String? {
        if case .refused(let m) = d { return m }
        return nil
    }

    private let usage = "usage: fleetest-services exec <service> -- <command…> | logs <service> [--tail N] | status | port <service> <containerPort>[/udp]"

    func testExecBuildsArgvForBothRuntimes() {
        for request in [["exec", "db", "--", "psql", "-c", "select 1"], ["exec", "db", "psql", "-c", "select 1"]] {
            XCTAssertEqual(policy(.docker).decide(request), .run(
                argv: ["DOCKER_HOST=unix:///tmp/d.sock", "/usr/local/bin/docker", "exec", "-i", "fleetest-abc-db", "psql", "-c", "select 1"],
                stdin: true))
            XCTAssertEqual(policy(.apple).decide(request), .run(
                argv: ["/opt/homebrew/bin/container", "exec", "-i", "fleetest-abc-db", "psql", "-c", "select 1"],
                stdin: true))
        }
    }

    /// `--` は1つだけ落とす(2つ目はコマンド自身の引数)
    func testExecDropsOnlyOneDoubleDash() {
        XCTAssertEqual(policy(.apple).decide(["exec", "db", "--", "--", "x"]), .run(
            argv: ["/opt/homebrew/bin/container", "exec", "-i", "fleetest-abc-db", "--", "x"], stdin: true))
    }

    func testExecRefusals() {
        XCTAssertEqual(refusal(policy(.docker).decide(["exec", "--env-file=/etc/passwd", "db", "ls"])),
                       "exec takes no options; write: fleetest-services exec <service> -- <command…>")
        XCTAssertEqual(refusal(policy(.docker).decide(["exec", "-it", "db", "sh"])),
                       "exec takes no options; write: fleetest-services exec <service> -- <command…>")
        XCTAssertEqual(refusal(policy(.docker).decide(["exec", "relay", "ls"])),
                       "service relay is not declared in compose.yaml (declared: api, db)")
        XCTAssertEqual(refusal(policy(.apple).decide(["exec", "db"])), "exec needs a command to run inside db")
        XCTAssertEqual(refusal(policy(.apple).decide(["exec", "db", "--"])), "exec needs a command to run inside db")
        XCTAssertEqual(refusal(policy(.apple).decide(["exec"])), usage)
    }

    func testLogsDefaultAndBounds() {
        XCTAssertEqual(policy(.docker).decide(["logs", "db"]), .run(
            argv: ["DOCKER_HOST=unix:///tmp/d.sock", "/usr/local/bin/docker", "logs", "--tail", "100", "fleetest-abc-db"], stdin: false))
        XCTAssertEqual(policy(.apple).decide(["logs", "api", "--tail", "1"]), .run(
            argv: ["/opt/homebrew/bin/container", "logs", "-n", "1", "fleetest-abc-api"], stdin: false))
        XCTAssertEqual(policy(.apple).decide(["logs", "api", "--tail", "10000"]), .run(
            argv: ["/opt/homebrew/bin/container", "logs", "-n", "10000", "fleetest-abc-api"], stdin: false))
        let message = "--tail takes an integer from 1 to 10000"
        for bad in [["0"], ["10001"], ["x"], ["-5"], ["+5"], ["1.5"], ["99999999999999999999"], []] {
            XCTAssertEqual(refusal(policy(.docker).decide(["logs", "db", "--tail"] + bad)), message, "\(bad)")
        }
    }

    func testLogsRefusals() {
        XCTAssertEqual(refusal(policy(.docker).decide(["logs", "db", "-f"])), "logs takes only --tail N")
        XCTAssertEqual(refusal(policy(.docker).decide(["logs", "db", "--tail", "5", "--follow"])), "logs takes only --tail N")
        XCTAssertEqual(refusal(policy(.docker).decide(["logs", "nope"])),
                       "service nope is not declared in compose.yaml (declared: api, db)")
        XCTAssertEqual(refusal(policy(.docker).decide(["logs"])), usage)
    }

    func testStatusTextIsSortedAndTabSeparated() {
        XCTAssertEqual(policy(.docker).decide(["status"]), .text("api\tfleetest-abc-api\ndb\tfleetest-abc-db"))
        XCTAssertEqual(refusal(policy(.docker).decide(["status", "db"])), "status takes no arguments")
    }

    func testPort() {
        XCTAssertEqual(policy(.docker).decide(["port", "db", "5432"]), .text("127.0.0.1:15432"))
        XCTAssertEqual(policy(.apple).decide(["port", "api", "9090/udp"]), .text("127.0.0.1:19090"))
        XCTAssertEqual(refusal(policy(.docker).decide(["port", "db", "5432/udp"])), "service db publishes no port 5432/udp")
        XCTAssertEqual(refusal(policy(.docker).decide(["port", "api", "9090"])), "service api publishes no port 9090/tcp")
        XCTAssertEqual(refusal(policy(.docker).decide(["port", "db", "6000"])), "service db publishes no port 6000/tcp")
        XCTAssertEqual(refusal(policy(.docker).decide(["port", "nope", "5432"])),
                       "service nope is not declared in compose.yaml (declared: api, db)")
        let message = "port takes a container port such as 5432 or 5432/udp"
        for bad in ["0", "65536", "x", "-1", "5432/sctp", "5432/", "/udp", "5432/udp/x", ""] {
            XCTAssertEqual(refusal(policy(.docker).decide(["port", "db", bad])), message, bad)
        }
        XCTAssertEqual(refusal(policy(.docker).decide(["port", "db"])), usage)
    }

    func testUnknownVerbAndEmptyRequestShowUsage() {
        for request in [[], ["run", "db"], ["cp", "db", "/a", "/b"], ["start", "db"], ["rm", "db"], [""]] {
            XCTAssertEqual(refusal(policy(.docker).decide(request)), usage, "\(request)")
        }
    }
}
