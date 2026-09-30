// 「包むかどうか」と構成ファイルの読み方。ここが誤ると、包むつもりの実行が枠なしで走るか、
// 読ませないつもりの場所が読める。

import XCTest
@testable import FTCore

final class ScenarioSandboxPlanTests: XCTestCase {

    private var root: URL!
    private var project: TestProject { TestProject(name: "P", rootURL: root) }
    private let home = "/Users/nobody-ft"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("profiles/runs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("conf"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ relative: String, _ json: String) throws {
        try Data(json.utf8).write(to: root.appendingPathComponent(relative))
    }

    private func resolve(_ request: ScenarioSandbox.Request, required: Bool = false) throws -> ScenarioSandbox.Plan? {
        try ScenarioSandbox.plan(request, project: project, home: home, required: required)
    }

    func testNotWrappedUnlessRequestedOrRequiredByTheMachine() throws {
        XCTAssertNil(try resolve(.unrequested))
        XCTAssertNil(try resolve(ScenarioSandbox.Request(enabled: false, configPath: "conf/x.json")))
        XCTAssertNotNil(try resolve(ScenarioSandbox.Request(enabled: true)))
        // マシン側の必須は、プロファイルの false にも、プロファイルを持たない呼び手にも勝つ
        XCTAssertNotNil(try resolve(.unrequested, required: true))
        XCTAssertNotNil(try resolve(ScenarioSandbox.Request(enabled: false), required: true))
    }

    func testDefaultsWhenThereIsNoConfigurationFile() throws {
        let plan = try XCTUnwrap(try resolve(ScenarioSandbox.Request(enabled: true)))
        XCTAssertEqual(plan.allowedDomains, [])
        XCTAssertEqual(plan.denyRead, [
            ".ssh", ".aws", ".gnupg", ".netrc", ".kube", ".docker", ".config/gh", "Library/Keychains",
        ].map { home + "/" + $0 })
    }

    func testDefaultFileNameIsReadWhenItExists() throws {
        try write("sandbox.json", #"{"allowedDomains": ["api.example.com"]}"#)
        let plan = try XCTUnwrap(try resolve(ScenarioSandbox.Request(enabled: true)))
        XCTAssertEqual(plan.allowedDomains, ["api.example.com"])
        // denyRead を書いていなければ既定の一覧のまま
        XCTAssertEqual(plan.denyRead.count, ScenarioSandbox.defaultDenyReadHomeSubpaths.count)
    }

    /// `denyRead` は既定を**置き換える**。`~` とプロジェクトからの相対を解決する
    func testDenyReadReplacesTheDefaultAndResolvesPaths() throws {
        try write("conf/sb.json", #"{"denyRead": ["~/Documents", "secrets", "/opt/private"]}"#)
        let plan = try XCTUnwrap(try resolve(ScenarioSandbox.Request(enabled: true, configPath: "conf/sb.json")))
        XCTAssertEqual(plan.denyRead, [
            NSHomeDirectory() + "/Documents",
            root.appendingPathComponent("secrets").standardizedFileURL.path,
            "/opt/private",
        ])
        try write("conf/empty.json", #"{"denyRead": []}"#)
        XCTAssertEqual(try resolve(ScenarioSandbox.Request(enabled: true, configPath: "conf/empty.json"))?.denyRead, [])
    }

    func testExplicitPathThatDoesNotExistIsAnError() {
        XCTAssertThrowsError(try resolve(ScenarioSandbox.Request(enabled: true, configPath: "conf/missing.json"))) {
            XCTAssertEqual($0 as? ScenarioSandbox.ConfigError,
                           .notFound(root.appendingPathComponent("conf/missing.json").standardizedFileURL.path))
        }
    }

    /// 綴りを誤ったキーを黙って無視しない(`denyread` と書いた一覧が効かないまま走る)
    func testUnknownKeysAreAnError() throws {
        try write("sandbox.json", #"{"denyread": ["~/x"], "allowedDomains": []}"#)
        XCTAssertThrowsError(try resolve(ScenarioSandbox.Request(enabled: true))) { error in
            guard case .unknownKeys(_, let keys)? = error as? ScenarioSandbox.ConfigError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(keys, ["denyread"])
        }
    }

    func testMalformedFileAndInvalidDomainAreErrors() throws {
        try write("sandbox.json", "{not json")
        XCTAssertThrowsError(try resolve(ScenarioSandbox.Request(enabled: true))) { error in
            guard case .unreadable? = error as? ScenarioSandbox.ConfigError else { return XCTFail("\(error)") }
        }
        try write("sandbox.json", #"{"allowedDomains": ["ok.example.com", "*"]}"#)
        XCTAssertThrowsError(try resolve(ScenarioSandbox.Request(enabled: true))) { error in
            guard case .invalidDomain(_, let pattern)? = error as? ScenarioSandbox.ConfigError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(pattern, "*")
        }
    }

    /// 包まない実行は、壊れた構成ファイルがあっても止めない(読まない)
    func testBrokenConfigurationIsNotReadWhenNotWrapped() throws {
        try write("sandbox.json", "{not json")
        XCTAssertNil(try resolve(.unrequested))
    }

    // MARK: - プロファイルから要求だけを読む口

    func testSandboxRequestReadsOnlyTheTwoKeysAndAppliesOverrides() throws {
        try write("profiles/runs/on.json", #"{"app": "a", "sandbox": true, "sandboxConfig": "conf/sb.json"}"#)
        try write("profiles/runs/off.json", #"{"app": "a"}"#)
        XCTAssertEqual(try ProfileResolver.sandboxRequest(project: project, runName: "on"),
                       ScenarioSandbox.Request(enabled: true, configPath: "conf/sb.json"))
        XCTAssertEqual(try ProfileResolver.sandboxRequest(project: project, runName: "off"), .unrequested)
        XCTAssertEqual(try ProfileResolver.sandboxRequest(project: project, runName: nil), .unrequested)
        XCTAssertEqual(
            try ProfileResolver.sandboxRequest(project: project, runName: "off", overrides: ["sandbox": true]),
            ScenarioSandbox.Request(enabled: true))
        XCTAssertEqual(
            try ProfileResolver.sandboxRequest(project: project, runName: "on", overrides: ["sandbox": false]),
            ScenarioSandbox.Request(enabled: false, configPath: "conf/sb.json"))
        XCTAssertEqual(
            try ProfileResolver.sandboxRequest(
                project: project, runName: nil,
                overrides: ["sandbox": true, "sandboxConfig": .string("x.json")]),
            ScenarioSandbox.Request(enabled: true, configPath: "x.json"))
    }

    /// 読めないプロファイルを「包まない」に倒さない(包むつもりの実行が枠なしで走る)
    func testSandboxRequestThrowsWhenTheProfileCannotBeRead() throws {
        XCTAssertThrowsError(try ProfileResolver.sandboxRequest(project: project, runName: "missing"))
        try write("profiles/runs/broken.json", "{not json")
        XCTAssertThrowsError(try ProfileResolver.sandboxRequest(project: project, runName: "broken"))
    }

    /// `sandboxRequired` の既定は「無い = 必須でない」。リテラルで固定する
    func testSandboxRequiredDefaultsToUnset() throws {
        XCTAssertNil(LocalConfig().sandboxRequired)
        let decoded = try JSONDecoder().decode(LocalConfig.self, from: Data(#"{"sandboxRequired": true}"#.utf8))
        XCTAssertEqual(decoded.sandboxRequired, true)
    }
}
