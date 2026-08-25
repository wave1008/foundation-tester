// フリート定義(docs/remote-runner.md §13)の純粋ロジック。
// ssh・プロセス起動は Sources/fleetest/FleetRunner.swift 側(e2e に残す)。

import Foundation
import XCTest
@testable import FTCore

final class FleetProfileTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FleetProfileTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        for dir in [project.runsDir, FleetProfile.fleetsDir(project)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String, to dir: URL, name: String) throws {
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(name).json"))
    }

    private func writeRunProfile(_ name: String) throws {
        try write("{ \"app\": \"sampleapp\", \"devices\": [ { \"name\": \"メイン機\" } ] }",
                  to: project.runsDir, name: name)
    }

    // MARK: - names

    func testNamesListsFleetFilesSorted() throws {
        try write("{ \"runs\": [] }", to: FleetProfile.fleetsDir(project), name: "zeta")
        try write("{ \"runs\": [] }", to: FleetProfile.fleetsDir(project), name: "alpha")
        XCTAssertEqual(FleetProfile.names(project: project), ["alpha", "zeta"])
    }

    func testNamesEmptyWhenNoFleetsDir() throws {
        try FileManager.default.removeItem(at: FleetProfile.fleetsDir(project))
        XCTAssertEqual(FleetProfile.names(project: project), [])
    }

    // MARK: - load

    func testLoadDecodesRunsInOrder() throws {
        try write("""
        { "runs": [
            { "host": "local", "profile": "ios-1" },
            { "host": "M1Ultra", "profile": "ios-m1ultra" } ] }
        """, to: FleetProfile.fleetsDir(project), name: "ios-lab")
        let doc = try FleetProfile.load(project: project, name: "ios-lab")
        XCTAssertEqual(doc.runs, [
            FleetRunEntry(host: "local", profile: "ios-1"),
            FleetRunEntry(host: "M1Ultra", profile: "ios-m1ultra"),
        ])
    }

    /// 未知キーはエラーにしない(既存プロファイルの流儀。Codable の既定挙動そのまま)
    func testLoadIgnoresUnknownKeys() throws {
        try write("""
        { "runs": [ { "host": "local", "profile": "ios-1", "note": "ignored" } ],
          "description": "ignored too" }
        """, to: FleetProfile.fleetsDir(project), name: "ios-lab")
        let doc = try FleetProfile.load(project: project, name: "ios-lab")
        XCTAssertEqual(doc.runs, [FleetRunEntry(host: "local", profile: "ios-1")])
    }

    func testLoadThrowsNotFoundWithAvailableNames() throws {
        try write("{ \"runs\": [] }", to: FleetProfile.fleetsDir(project), name: "existing")
        XCTAssertThrowsError(try FleetProfile.load(project: project, name: "missing")) { error in
            guard case FleetProfileError.notFound(let name, let available) = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
            XCTAssertEqual(name, "missing")
            XCTAssertEqual(available, ["existing"])
        }
    }

    func testLoadThrowsDecodeFailedOnMalformedJSON() throws {
        try write("{ not json", to: FleetProfile.fleetsDir(project), name: "broken")
        XCTAssertThrowsError(try FleetProfile.load(project: project, name: "broken")) { error in
            guard case FleetProfileError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    // MARK: - validate: emptyRuns

    func testValidateEmptyRuns() {
        let issues = FleetProfile.validate(
            FleetProfileDocument(runs: []), project: project, registeredHostNames: [])
        XCTAssertEqual(issues, [.emptyRuns])
    }

    // MARK: - validate: duplicateHost

    func testValidateFlagsDuplicateRegisteredHost() throws {
        try writeRunProfile("ios-1")
        try writeRunProfile("ios-2")
        let doc = FleetProfileDocument(runs: [
            FleetRunEntry(host: "M1Ultra", profile: "ios-1"),
            FleetRunEntry(host: "M1Ultra", profile: "ios-2"),
        ])
        let issues = FleetProfile.validate(doc, project: project, registeredHostNames: ["M1Ultra"])
        XCTAssertEqual(issues, [.duplicateHost("M1Ultra")])
    }

    func testValidateFlagsDuplicateLocal() throws {
        try writeRunProfile("ios-1")
        try writeRunProfile("ios-2")
        let doc = FleetProfileDocument(runs: [
            FleetRunEntry(host: "local", profile: "ios-1"),
            FleetRunEntry(host: "local", profile: "ios-2"),
        ])
        let issues = FleetProfile.validate(doc, project: project, registeredHostNames: [])
        XCTAssertEqual(issues, [.duplicateHost("local")])
    }

    // MARK: - validate: unregisteredHost

    func testValidateFlagsUnregisteredHost() throws {
        try writeRunProfile("ios-1")
        let doc = FleetProfileDocument(runs: [FleetRunEntry(host: "someone@example.com", profile: "ios-1")])
        let issues = FleetProfile.validate(doc, project: project, registeredHostNames: ["M1Ultra"])
        XCTAssertEqual(issues, [.unregisteredHost("someone@example.com")])
    }

    func testValidateAcceptsRegisteredHost() throws {
        try writeRunProfile("ios-1")
        let doc = FleetProfileDocument(runs: [FleetRunEntry(host: "M1Ultra", profile: "ios-1")])
        let issues = FleetProfile.validate(doc, project: project, registeredHostNames: ["M1Ultra"])
        XCTAssertEqual(issues, [])
    }

    func testValidateAcceptsLocalWithoutRegistration() throws {
        try writeRunProfile("ios-1")
        let doc = FleetProfileDocument(runs: [FleetRunEntry(host: "local", profile: "ios-1")])
        let issues = FleetProfile.validate(doc, project: project, registeredHostNames: [])
        XCTAssertEqual(issues, [])
    }

    // MARK: - validate: unknownRunProfile

    func testValidateFlagsUnknownRunProfileWithAvailableList() throws {
        try writeRunProfile("ios-1")
        let doc = FleetProfileDocument(runs: [FleetRunEntry(host: "local", profile: "missing-profile")])
        let issues = FleetProfile.validate(doc, project: project, registeredHostNames: [])
        XCTAssertEqual(issues, [
            .unknownRunProfile(host: "local", profile: "missing-profile", available: ["ios-1"]),
        ])
    }

    // MARK: - validate: multiple issues surface together

    func testValidateReturnsAllIssuesAtOnce() throws {
        let doc = FleetProfileDocument(runs: [
            FleetRunEntry(host: "local", profile: "missing"),
            FleetRunEntry(host: "local", profile: "missing"),
            FleetRunEntry(host: "unregistered", profile: "missing"),
        ])
        let issues = FleetProfile.validate(doc, project: project, registeredHostNames: [])
        // 2つの "local" エントリはどちらも profile 不在なので、unknownRunProfile は
        // 個別に(重複除去せず)2件出る ―― 「どのエントリが」を落とさないため
        XCTAssertEqual(issues, [
            .duplicateHost("local"),
            .unknownRunProfile(host: "local", profile: "missing", available: []),
            .unknownRunProfile(host: "local", profile: "missing", available: []),
            .unregisteredHost("unregistered"),
            .unknownRunProfile(host: "unregistered", profile: "missing", available: []),
        ])
    }

    // MARK: - description text

    func testUnregisteredHostDescriptionMentionsHostsAdd() {
        XCTAssertTrue(FleetValidationIssue.unregisteredHost("x").description.contains("remote hosts add"))
    }

    // MARK: - aggregateExitCode

    func testAggregateExitCodeAllZeroIsZero() {
        XCTAssertEqual(FleetProfile.aggregateExitCode([0, 0, 0]), 0)
    }

    func testAggregateExitCodeEmptyIsZero() {
        XCTAssertEqual(FleetProfile.aggregateExitCode([]), 0)
    }

    func testAggregateExitCodeOneFailureIsNonZero() {
        XCTAssertEqual(FleetProfile.aggregateExitCode([0, 1, 0]), 1)
    }

    /// 規則: 非0の中の最大値を返す(全部同じ 1 に丸めない)
    func testAggregateExitCodeReturnsMaxOfNonZero() {
        XCTAssertEqual(FleetProfile.aggregateExitCode([0, 3, 90, 1]), 90)
    }

    func testAggregateExitCodeIgnoresOrder() {
        XCTAssertEqual(FleetProfile.aggregateExitCode([90, 0, 3]), FleetProfile.aggregateExitCode([3, 90, 0]))
    }
}
