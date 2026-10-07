// account() / data() / httpRequest() の DSL 側。伏せ字化が recordStep の2つの出口(レコード・NDJSON)と
// レポートに効くこと、値が無いときの失敗、dry-run、同期 HTTP の成功・失敗・時間切れ。

import XCTest
@testable import FTDSL
import FTCore

final class DatasetAndHTTPCommandTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var events: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class NullDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private var project: URL!
    private let sink = Sink()

    override func setUpWithError() throws {
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-dsl-dataset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("dataset"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        SecretRedactor.shared.removeAll()
        try? FileManager.default.removeItem(at: project)
    }

    private func writeDataset(_ name: String, _ json: String) throws {
        try json.write(to: project.appendingPathComponent("dataset/\(name).json"), atomically: true, encoding: .utf8)
    }

    private func makeCore(dryRun: Bool = false, tunables: RunTunables = RunTunables()) -> FTDriveCore {
        FTDriveCore(driver: NullDriver(), platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, tunables: tunables,
                    visionClassifierProjectRoot: project, dryRun: dryRun,
                    fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-dataset-test.json"),
                    emit: { [sink] in sink.add($0) })
    }

    private func steps(_ core: FTDriveCore) -> [DSLStepRecord] { core.finalRecord.scenes.flatMap(\.steps) }

    // MARK: - account / data

    func testAccountReturnsValueRecordsNoStepAndMasksEveryAttributeEverywhere() throws {
        try writeDataset("accounts", #"{"[account1]": {"id": "alice-login", "password": "p@ss\"word"}}"#)
        let core = makeCore()
        core.redactAccountValues = true
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let password = account("[account1].password")
        XCTAssertEqual(password, "p@ss\"word")
        XCTAssertEqual(account("[account1]", "id"), "alice-login", "2引数形は longKey 形と同じ")
        XCTAssertEqual(steps(core).count, 0, "成功では記録しない")
        XCTAssertEqual(sink.events.filter { $0.kind == "step" }.count, 0)

        // 値を引数に持つコマンド(説明に値が入る)→ レコードにもイベントにも値が残らない
        writeMemo("pw", password)
        writeMemo("who", "login as alice-login")
        core.recordStep(description: "boom \(password)", status: .failed("rejected \(password)"),
                        file: "x.swift", line: 1, command: "type")
        let record = steps(core)
        XCTAssertEqual(record.count, 3)
        for step in record {
            XCTAssertFalse(step.description.contains(password), step.description)
            XCTAssertFalse(step.description.contains("alice-login"), "同じデータセットの別の属性も伏せる")
            if case .failed(let reason) = step.status { XCTAssertFalse(reason.contains(password), reason) }
        }
        XCTAssertEqual(record[0].description, "writeMemo \"pw\" = \"***\"")
        // memoWrite イベントは値そのものを親へ運ぶ(ここでは伏せない。出口の ConsoleOut が伏せる = docs に注記)ので step だけ見る
        for event in sink.events where event.kind == "step" {
            let line = event.encodedLine()
            XCTAssertFalse(line.contains(password), line)
            XCTAssertEqual(SecretRedactor.shared.redact(line), line, "イベントの時点で既に伏せてある")
        }

        // 報告書
        let dir = project.appendingPathComponent("report")
        let url = try ScenarioReportWriter.write(record: core.finalRecord, to: dir)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("writeMemo \"pw\" = \"***\""), markdown)
        XCTAssertFalse(markdown.contains(password), markdown)
        XCTAssertFalse(markdown.contains("alice-login"), markdown)
    }

    /// 伏せ字化はマシン側で立てたときだけ。既定(false)では値をそのまま記録する
    func testAccountValuesAreNotMaskedUnlessTheMachineTurnsItOn() throws {
        try writeDataset("accounts", #"{"[account1]": {"password": "plain-pass"}}"#)
        let core = makeCore()
        XCTAssertFalse(core.redactAccountValues, "既定は伏せない")
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let password = account("[account1].password")
        core.recordStep(description: "type \(password)", status: .passed,
                        file: "x.swift", line: 1, command: "type")
        XCTAssertEqual(steps(core).last?.description, "type plain-pass")
        XCTAssertEqual(SecretRedactor.shared.redact("plain-pass"), "plain-pass", "登録しない")
    }

    /// recordStep を通らない経路(レコードに残った生の値・失敗時の要素一覧)も、報告書の書き出しで伏せる
    func testReportWriterMasksRawValuesInStepsAndFailureElements() throws {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        writeMemo("raw", "zz-raw-secret")      // 登録の前 = 生のままレコードへ入る
        SecretRedactor.shared.register("zz-raw-secret")
        var record = core.finalRecord
        record.scenes[0].failureElements = "textField value=zz-raw-secret"
        let dir = project.appendingPathComponent("report2")
        let url = try ScenarioReportWriter.write(record: record, to: dir)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("writeMemo \"raw\" = \"***\""), markdown)
        XCTAssertTrue(markdown.contains("textField value=***"), markdown)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where !name.hasSuffix(".png") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("zz-raw-secret"), "\(name) に生の値が残っている")
        }
    }

    func testShortAccountValueIsNotMasked() throws {
        try writeDataset("accounts", #"{"[a]": {"pin": "123"}}"#)
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        let pin = account("[a].pin")
        XCTAssertEqual(pin, "123")
        writeMemo("pin", pin)
        XCTAssertEqual(steps(core).first?.description, "writeMemo \"pin\" = \"123\"")
    }

    func testDataValueIsReturnedAndNotMasked() throws {
        try writeDataset("data", #"{"[order1]": {"item": "red-widget"}}"#)
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        let item = data("[order1].item")
        XCTAssertEqual(item, "red-widget")
        XCTAssertEqual(data("[order1]", "item"), "red-widget")
        writeMemo("item", item)
        XCTAssertEqual(steps(core).first?.description, "writeMemo \"item\" = \"red-widget\"")
    }

    func testDryRunReturnsTheLongKeyWithoutReadingFiles() {
        let core = makeCore(dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(account("[nope].password"), "[nope].password")
        XCTAssertEqual(data("[nope]", "x"), "[nope].x")
        XCTAssertEqual(steps(core).count, 0)
    }

    func testMissingValueFailsTheStepAndAbortsWithEveryPathAndNoValue() throws {
        try writeDataset("accounts", #"{"[account1]": {"password": "hunter2-hunter2"}}"#)
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(account("[account1].missing"), "")
        XCTAssertTrue(core.scenarioAborted)
        let failed = try XCTUnwrap(steps(core).first)
        XCTAssertEqual(failed.description, "account \"[account1].missing\"")
        guard case .failed(let reason) = failed.status else { return XCTFail("\(failed.status)") }
        XCTAssertTrue(reason.contains(project.appendingPathComponent("dataset/accounts.json").path), reason)
        XCTAssertTrue(reason.contains(".config/fleetest/dataset/\(project.lastPathComponent)/accounts.json"), reason)
        XCTAssertFalse(reason.contains("hunter2"), reason)
        XCTAssertEqual(sink.events.filter { $0.kind == "step" && $0.command == "account" }.count, 1)
    }

    // MARK: - dataFile

    func testDataFileReturnsTheProjectFileWithoutRecordingAStep() throws {
        try "id\nu1\n".write(to: project.appendingPathComponent("dataset/users.csv"), atomically: true, encoding: .utf8)
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        let url = dataFile("users.csv")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "id\nu1\n")
        XCTAssertEqual(steps(core).count, 0)
        XCTAssertFalse(core.scenarioAborted)
    }

    func testMissingDataFileFailsAndReturnsAnEmptyFileThatReadsAsEmpty() throws {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        let url = dataFile("nothing.csv")
        XCTAssertEqual(url.lastPathComponent, "fleetest-dataFile-not-found")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "", "後続の読み込みはプロセスを落とさない")
        XCTAssertTrue(core.scenarioAborted)
        let failed = try XCTUnwrap(steps(core).first)
        XCTAssertEqual(failed.description, "dataFile \"nothing.csv\"")
        guard case .failed(let reason) = failed.status else { return XCTFail("\(failed.status)") }
        XCTAssertTrue(reason.contains(project.appendingPathComponent("dataset/nothing.csv").path), reason)
        XCTAssertEqual(sink.events.filter { $0.kind == "step" && $0.command == "dataFile" }.count, 1)
    }

    func testDryRunDoesNotFailOnAMissingDataFile() {
        let core = makeCore(dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(try String(contentsOf: dataFile("nothing.csv"), encoding: .utf8), "")
        XCTAssertFalse(core.scenarioAborted)
        XCTAssertEqual(steps(core).count, 0)
    }

    // MARK: - httpRequest

    func testHTTPRequestGetAndPostReturnStatusHeadersBodyAndJSON() throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        let get = httpRequest("http://127.0.0.1:\(server.port)/echo")
        XCTAssertEqual(get.status, 201)
        XCTAssertEqual(get.headers["x-reply"], "yes", "ヘッダ名は小文字")
        XCTAssertEqual((get.json as? [String: Any])?["method"] as? String, "GET")

        let post = httpRequest("http://127.0.0.1:\(server.port)/echo", method: "post",
                               headers: ["X-Token": "abc"], body: "hello=1")
        XCTAssertEqual(post.status, 201)
        let object = try XCTUnwrap(post.json as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "POST")
        XCTAssertEqual(object["body"] as? String, "hello=1")
        XCTAssertEqual(object["token"] as? String, "abc")
        XCTAssertTrue(post.text.contains("hello=1"))

        XCTAssertEqual(steps(core).map(\.description), [
            "httpRequest GET http://127.0.0.1:\(server.port)/echo → 201",
            "httpRequest POST http://127.0.0.1:\(server.port)/echo → 201",
        ])
        XCTAssertFalse(core.scenarioAborted)
        XCTAssertEqual(sink.events.filter { $0.kind == "step" }.compactMap(\.command), ["httpRequest", "httpRequest"])
    }

    func testHTTPErrorStatusIsNotAFailure() throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(httpRequest("http://127.0.0.1:\(server.port)/missing").status, 404)
        XCTAssertEqual(httpRequest("http://127.0.0.1:\(server.port)/boom").status, 500)
        XCTAssertFalse(core.scenarioAborted)
    }

    func testNoResponseWithinWaitSecondsFailsTheStep() throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        let started = Date()
        let response = httpRequest("http://127.0.0.1:\(server.port)/hang", waitSeconds: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(response.status, 0)
        XCTAssertTrue(core.scenarioAborted)
        guard case .failed(let reason)? = steps(core).first?.status else { return XCTFail() }
        XCTAssertTrue(reason.contains("no response within 0.5s"), reason)
    }

    /// waitSeconds を省くと RunTunables.httpRequestTimeout(= core.tunables)で待つ
    func testDefaultWaitComesFromTheTunables() throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let core = makeCore(tunables: RunTunables(httpRequestTimeout: 0.5))
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        let started = Date()
        _ = httpRequest("http://127.0.0.1:\(server.port)/hang")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        guard case .failed(let reason)? = steps(core).first?.status else { return XCTFail() }
        XCTAssertTrue(reason.contains("no response within 0.5s"), reason)
    }

    func testConnectionRefusedAndBadURLFail() throws {
        let server = try TestHTTPServer()
        let deadPort = server.port
        server.stop()
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(httpRequest("http://127.0.0.1:\(deadPort)/", waitSeconds: 3).status, 0)
        guard case .failed(let refused)? = steps(core).first?.status else { return XCTFail() }
        XCTAssertTrue(refused.hasPrefix("httpRequest GET http://127.0.0.1:\(deadPort)/: "), refused)

        let second = makeCore()
        FTRuntime.bootstrap(core: second, dslThread: Thread.current)
        _ = httpRequest("not a url")
        _ = httpRequest("ftp://example.com/x")
        guard case .failed(let bad)? = steps(second).first?.status else { return XCTFail() }
        XCTAssertTrue(bad.contains("invalid URL"), bad)
        XCTAssertEqual(steps(second).count, 2, "最初の失敗で中断し、2つ目は skipped として記録される")
    }

    func testDryRunSendsNothingAndRecordsTheStep() throws {
        let server = try TestHTTPServer()
        defer { server.stop() }
        let core = makeCore(dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        let response = httpRequest("http://127.0.0.1:\(server.port)/echo")
        XCTAssertEqual(response.status, 0)
        XCTAssertTrue(response.data.isEmpty)
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertEqual(steps(core).map(\.description), ["httpRequest GET http://127.0.0.1:\(server.port)/echo"])
    }

    func testURLSessionProxyDictionaryFollowsTheEnvironment() {
        XCTAssertNil(URLSessionProxy.connectionProxyDictionary(environment: [:]))
        XCTAssertFalse(URLSessionProxy.isConfigured(environment: [:]))
        let env = ["HTTPS_PROXY": "http://127.0.0.1:5555", "NO_PROXY": "localhost, 127.0.0.1"]
        XCTAssertTrue(URLSessionProxy.isConfigured(environment: env))
        let dictionary = URLSessionProxy.connectionProxyDictionary(environment: env)
        XCTAssertEqual(dictionary?["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary?["HTTPSPort"] as? Int, 5555)
        XCTAssertEqual(dictionary?["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary?["ExceptionsList"] as? [String], ["localhost", "127.0.0.1"])
        XCTAssertNil(URLSessionProxy.connectionProxyDictionary(environment: ["HTTPS_PROXY": "garbage"]))
    }
}

/// 127.0.0.1 で待ち受ける最小の HTTP/1.1 サーバ。/echo = 201 + JSON、/missing = 404、/boom = 500、/hang = 応答しない
private final class TestHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let count = LockedValue<Int>(0)
    private let held = LockedValue<[Int32]>([])
    var requestCount: Int { count.value }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard fd >= 0, bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        descriptor = fd
        port = UInt16(bigEndian: actual.sin_port)
        let count = self.count, held = self.held
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { Self.serve(client, count: count, held: held) }
            }
        }
    }

    private static func serve(_ client: Int32, count: LockedValue<Int>, held: LockedValue<[Int32]>) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        func headerEnd() -> Range<Data.Index>? { data.range(of: Data("\r\n\r\n".utf8)) }
        while headerEnd() == nil {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { close(client); return }
            data.append(contentsOf: buffer[..<n])
        }
        let end = headerEnd()!
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var body = data[end.upperBound...]
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ").map(String.init)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < expected {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { break }
            body.append(contentsOf: buffer[..<n])
        }
        count.withLock { $0 += 1 }
        let path = parts.count > 1 ? parts[1] : "/"
        if path == "/hang" {
            held.withLock { $0.append(client) }   // 閉じずに放置(stop で閉じる)
            return
        }
        let status: String
        var payload = ""
        switch path {
        case "/echo":
            status = "201 Created"
            let object: [String: Any] = ["method": parts[0], "body": String(decoding: body, as: UTF8.self),
                                         "token": headers["x-token"] ?? ""]
            payload = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
        case "/missing": status = "404 Not Found"
        default: status = "500 Internal Server Error"
        }
        let reply = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nX-Reply: yes\r\n"
            + "Content-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
        _ = reply.withCString { write(client, $0, strlen($0)) }
        close(client)
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        for client in held.withLock({ $0 }) { close(client) }
    }
}
