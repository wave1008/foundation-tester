// account() / data() のデータセット。置き場・属性単位の上書き・失敗文(パスを全部出し、値は出さない)。

import XCTest
@testable import FTCore

final class ScenarioDatasetTests: XCTestCase {

    private var root: URL!
    private var project: URL!
    private var home: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-dataset-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("MyProject", isDirectory: true)
        home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private func projectFile(_ kind: ScenarioDataset.Kind) -> URL {
        project.appendingPathComponent("dataset/\(kind.rawValue).json")
    }

    private func machineFile(_ kind: ScenarioDataset.Kind) -> URL {
        ScenarioDataset.machineURL(kind: kind, projectDir: project, home: home)
    }

    func testMachineFileLivesUnderTheRealHomeByProjectName() {
        XCTAssertEqual(machineFile(.accounts).path, "\(home!)/.config/fleetest/dataset/MyProject/accounts.json")
        XCTAssertEqual(machineFile(.data).lastPathComponent, "data.json")
    }

    func testProjectValueIsReadByLongKey() throws {
        try write(#"{"[account1]": {"id": "alice", "password": "s3cret!"}}"#, to: projectFile(.accounts))
        let dataset = ScenarioDataset(kind: .accounts, projectDir: project, home: home)
        XCTAssertEqual(try dataset.value(longKey: "[account1].password"), "s3cret!")
        XCTAssertEqual(try dataset.value(longKey: "[account1].id"), "alice")
    }

    /// 最後の `.` で分ける(データセット名に `.` を含められる。Shirates と同じ)
    func testLongKeySplitsAtTheLastDot() throws {
        try write(#"{"[a.b]": {"x": "1234"}}"#, to: projectFile(.data))
        let dataset = ScenarioDataset(kind: .data, projectDir: project, home: home)
        XCTAssertEqual(try dataset.value(longKey: "[a.b].x"), "1234")
        XCTAssertEqual(ScenarioDataset.split(longKey: "[a.b].x")?.dataset, "[a.b]")
        XCTAssertNil(ScenarioDataset.split(longKey: "nodot"))
    }

    func testMachineFileOverridesPerAttributeAndAddsItsOwn() throws {
        try write(#"{"[account1]": {"id": "alice", "password": "project-pw"}}"#, to: projectFile(.accounts))
        try write(#"{"[account1]": {"password": "machine-pw", "token": "tok-123"}, "[account2]": {"id": "bob"}}"#,
                  to: machineFile(.accounts))
        let dataset = ScenarioDataset(kind: .accounts, projectDir: project, home: home)
        XCTAssertEqual(try dataset.value(longKey: "[account1].password"), "machine-pw", "マシン側が上書きする")
        XCTAssertEqual(try dataset.value(longKey: "[account1].id"), "alice", "上書きされない属性はプロジェクト側のまま")
        XCTAssertEqual(try dataset.value(longKey: "[account1].token"), "tok-123", "マシン側だけの属性")
        XCTAssertEqual(try dataset.value(longKey: "[account2].id"), "bob", "マシン側だけのデータセット")
        XCTAssertEqual(Set(dataset.allValues(dataset: "[account1]")), ["alice", "machine-pw", "tok-123"])
    }

    func testMachineOnlyIsEnough() throws {
        try write(#"{"[a]": {"k": "machine-only"}}"#, to: machineFile(.data))
        XCTAssertEqual(try ScenarioDataset(kind: .data, projectDir: project, home: home).value(longKey: "[a].k"),
                       "machine-only")
    }

    /// 見たファイルを全部と、何が無かったかを言う。値は出さない
    func testMissingValueNamesEveryPathAndNeverTheValue() throws {
        try write(#"{"[account1]": {"password": "hunter2-hunter2"}}"#, to: projectFile(.accounts))
        let dataset = ScenarioDataset(kind: .accounts, projectDir: project, home: home)
        for key in ["[account1].nothing", "[nope].password", "nodot"] {
            let message = try XCTUnwrap(XCTAssertThrowsErrorMessage(try dataset.value(longKey: key)))
            XCTAssertTrue(message.contains(projectFile(.accounts).path), message)
            XCTAssertTrue(message.contains(machineFile(.accounts).path), message)
            XCTAssertTrue(message.contains("not found"), "machine file is absent: \(message)")
            XCTAssertFalse(message.contains("hunter2"), message)
            XCTAssertTrue(message.hasPrefix("account(\"\(key)\")"), message)
        }
        let attribute = try XCTUnwrap(XCTAssertThrowsErrorMessage(try dataset.value(longKey: "[account1].nothing")))
        XCTAssertTrue(attribute.contains("attribute \"nothing\" not found in dataset \"[account1]\""), attribute)
        let dataMessage = try XCTUnwrap(XCTAssertThrowsErrorMessage(
            try ScenarioDataset(kind: .data, projectDir: project, home: home).value(longKey: "[x].y")))
        XCTAssertTrue(dataMessage.hasPrefix("data("), dataMessage)
    }

    /// 壊れたファイルは、他のファイルに値があっても失敗にする(古い値で動かない)
    func testBrokenFileFailsEvenWhenAnotherFileHasTheValue() throws {
        try write(#"{"[a]": {"k": "project-value"}}"#, to: projectFile(.data))
        try write("{ not json", to: machineFile(.data))
        let message = try XCTUnwrap(XCTAssertThrowsErrorMessage(
            try ScenarioDataset(kind: .data, projectDir: project, home: home).value(longKey: "[a].k")))
        XCTAssertTrue(message.contains(machineFile(.data).path + " is not a JSON object"), message)
        XCTAssertFalse(message.contains("project-value"), message)
    }

    /// 属性値が文字列でないデータセットは拒む(Shirates の setValueAsString)
    func testNonStringAttributeIsRejectedByName() throws {
        try write(#"{"[a]": {"k": "v", "n": 5}}"#, to: projectFile(.data))
        let message = try XCTUnwrap(XCTAssertThrowsErrorMessage(
            try ScenarioDataset(kind: .data, projectDir: project, home: home).value(longKey: "[a].k")))
        XCTAssertTrue(message.contains("attribute \"n\" of dataset \"[a]\" is not a string"), message)
    }

    func testNoProjectDirectoryFails() {
        let message = XCTAssertThrowsErrorMessage(
            try ScenarioDataset(kind: .data, projectDir: nil, home: home).value(longKey: "[a].k"))
        XCTAssertEqual(message?.contains("no project directory"), true)
    }

    private func XCTAssertThrowsErrorMessage(_ body: @autoclosure () throws -> String,
                                             file: StaticString = #filePath, line: UInt = #line) -> String? {
        do { _ = try body(); XCTFail("expected a failure", file: file, line: line); return nil } catch {
            return (error as? ScenarioDataset.Failure)?.message
        }
    }
}
