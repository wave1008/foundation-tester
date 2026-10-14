// `ServiceGatewayServer` / `ServiceGatewayClient` の往復。方針は偽物で、判定の中身(FTServices の `ServicePolicy`)は見ない。

import XCTest
@testable import FTCore

final class FakeGatewayPolicy: ServiceGatewayPolicy {
    let requests = LockedValue<[[String]]>([])

    func decide(_ request: [String]) -> ServiceGatewayDecision {
        requests.withLock { $0.append(request) }
        switch request.first {
        case "cat": return .run(argv: ["/bin/cat"], stdin: true)
        case "both": return .run(argv: ["/bin/sh", "-c", "echo out; echo err 1>&2; exit 3"], stdin: false)
        case "text": return .text("db\tfleetest-x-db")
        case "refuse": return .refused("no such service")
        case "sleep": return .run(argv: ["/bin/sh", "-c", "sleep 30"], stdin: true)
        case "env": return .run(argv: ["FOO=bar", "/bin/sh", "-c", "echo $FOO"], stdin: false)
        default: return .refused("unknown")
        }
    }
}

final class ServiceGatewayTests: XCTestCase {
    private var server: ServiceGatewayServer!
    private let policy = FakeGatewayPolicy()
    private let logs = LockedValue<[String]>([])
    private var tempFiles: [URL] = []

    override func setUpWithError() throws {
        server = try ServiceGatewayServer(policy: policy, directory: NSTemporaryDirectory(),
                                          log: { [logs] line in logs.withLock { $0.append(line) } })
    }

    override func tearDown() {
        server.stop()
        for file in tempFiles { try? FileManager.default.removeItem(at: file) }
    }

    private struct Outcome { var status: Int32; var out: Data; var err: Data }

    private func call(_ arguments: [String], stdin: Data = Data()) throws -> Outcome {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ftg-stdin-\(UUID().uuidString)")
        try stdin.write(to: file)
        tempFiles.append(file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var out = Data()
        var err = Data()
        let status = ServiceGatewayClient.run(
            arguments: arguments, environment: [ServiceGatewayWire.environmentKey: server.socketPath],
            stdin: handle, stdinIsTerminal: false, out: { out.append($0) }, err: { err.append($0) })
        return Outcome(status: status, out: out, err: err)
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    func testThreeMiBOfStdinStreamsThroughCat() throws {
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<(3 << 20)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let result = try call(["cat"], stdin: payload)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.out.count, 3 << 20)
        XCTAssertTrue(result.out == payload)
        XCTAssertEqual(result.err.count, 0)
    }

    func testStdoutStderrAndStatusAreSeparate() throws {
        let result = try call(["both"])
        XCTAssertEqual(String(decoding: result.out, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: result.err, as: UTF8.self), "err\n")
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(logs.value, [], "実行した要求は拒否のログを出さない")
    }

    func testTextAnswerIsReturnedWithoutRunningAnything() throws {
        let result = try call(["text"])
        XCTAssertEqual(String(decoding: result.out, as: UTF8.self), "db\tfleetest-x-db\n")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(server.activeChildCount, 0)
    }

    func testRefusalIs126WithTheReasonAndIsLogged() throws {
        let result = try call(["refuse", "x"])
        XCTAssertEqual(result.status, 126)
        XCTAssertEqual(String(decoding: result.err, as: UTF8.self), "fleetest-services: refused — no such service\n")
        XCTAssertEqual(result.out.count, 0)
        XCTAssertEqual(server.activeChildCount, 0)
        XCTAssertEqual(policy.requests.value, [["refuse", "x"]])
        XCTAssertEqual(logs.value, ["services gateway: refused refuse x — no such service"])
    }

    func testChildIsStoppedWhenTheClientVanishes() throws {
        let fd = try UnixSocket.connect(path: server.socketPath)
        UnixSocket.writeLine(fd, ["v": 1, "argv": ["sleep"]])
        let answer = UnixSocket.readLine(fd, limit: 4096)
        XCTAssertEqual(answer.flatMap { String(data: $0, encoding: .utf8) }, "{\"ok\":true}")
        XCTAssertTrue(waitUntil(3) { server.activeChildCount == 1 }, "子が起動していること")
        close(fd)
        XCTAssertTrue(waitUntil(3) { server.activeChildCount == 0 }, "client が切れたら子が止まる")
    }

    func testLeadingEnvironmentAssignmentsReachTheChild() throws {
        let result = try call(["env"])
        XCTAssertEqual(String(decoding: result.out, as: UTF8.self), "bar\n")
        XCTAssertEqual(result.status, 0)
    }

    func testClientWithoutTheEnvironmentVariableIs126() {
        for environment in [[String: String](), [ServiceGatewayWire.environmentKey: ""]] {
            var err = Data()
            let status = ServiceGatewayClient.run(
                arguments: ["exec", "db"], environment: environment, stdin: .nullDevice, stdinIsTerminal: true,
                out: { _ in XCTFail("no output expected") }, err: { err.append($0) })
            XCTAssertEqual(status, 126)
            XCTAssertEqual(String(decoding: err, as: UTF8.self),
                           "fleetest-services: no services gateway is available — either this run declares no services"
                           + " (scripts/compose.yaml is absent) or the command is running outside a fleetest setup/teardown script\n")
        }
    }

    func testUnsupportedVersionAndMalformedRequestsAreRefusedWithoutAskingThePolicy() throws {
        for (request, expected) in [
            (["v": 2, "argv": ["cat"]] as [String: Any], "{\"refused\":\"protocol version 2 is not supported\"}"),
            (["v": 1] as [String: Any], "{\"refused\":\"malformed request\"}"),
        ] {
            let fd = try UnixSocket.connect(path: server.socketPath)
            defer { close(fd) }
            UnixSocket.writeLine(fd, request)
            let answer = UnixSocket.readLine(fd, limit: 4096)
            XCTAssertEqual(answer.flatMap { String(data: $0, encoding: .utf8) }, expected)
        }
        XCTAssertEqual(policy.requests.value, [])
        XCTAssertEqual(server.activeChildCount, 0)
    }
}
