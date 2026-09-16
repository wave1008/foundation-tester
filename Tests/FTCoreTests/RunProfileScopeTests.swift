// 実行プロファイルの enabled の台を台帳にする経路。
// `api monitor --profile` と `devices up/down --profile` が共有する経路で、ここが誤ると
// 「意図しないデバイスを起動・停止する」「監視対象が欠ける」という形で実機側に影響が出る。
// 実機なしで固められる部分なので単体テストで押さえる。

import XCTest
@testable import FTCore

final class RunProfileScopeTests: XCTestCase {

    private var tempDir: URL!
    private var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        try FileManager.default.createDirectory(at: project.runsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeRunProfile(_ name: String, devices: [[String: Any]]?) throws {
        var doc: [String: Any] = ["app": "a"]
        if let devices { doc["devices"] = devices }
        try JSONSerialization.data(withJSONObject: doc)
            .write(to: project.runsDir.appendingPathComponent("\(name).json"))
    }

    private func device(_ platform: String, _ name: String, machine: String = "local",
                        enabled: Bool? = nil, udid: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["platform": platform, "machine": machine, "name": name]
        if let enabled { d["enabled"] = enabled }
        if let udid { d["udid"] = udid }
        return d
    }

    // MARK: - 正常系

    func testKeepsOnlyEnabledDevicesAcrossPlatforms() throws {
        try writeRunProfile("mixed", devices: [
            device("ios", "シミュ1"), device("ios", "シミュ2", enabled: false),
            device("android", "エミュ1", enabled: false), device("android", "エミュ2", enabled: true),
        ])
        let result = try RunProfileScope.roster(project: project, runProfileName: "mixed")
        XCTAssertEqual(result.ios?.devices?.map(\.name), ["シミュ1"])
        XCTAssertEqual(result.android?.devices?.map(\.name), ["エミュ2"])
    }

    /// 名前で1台を引く単体操作は無効の台も見る(一覧に出ている台は操作できるべき)
    func testEnabledOnlyFalseKeepsDisabledDevices() throws {
        try writeRunProfile("mixed", devices: [
            device("ios", "シミュ1"), device("ios", "シミュ2", enabled: false),
        ])
        let result = try RunProfileScope.roster(project: project, runProfileName: "mixed",
                                                enabledOnly: false)
        XCTAssertEqual(result.ios?.devices?.map(\.name), ["シミュ1", "シミュ2"])
    }

    func testPlatformWithNoSurvivingDeviceBecomesNil() throws {
        // 空リストではなく nil(空リストだと「0台のプラットフォームがある」として扱われうる)
        try writeRunProfile("ios-only", devices: [
            device("ios", "シミュ1"), device("android", "エミュ1", enabled: false),
        ])
        let result = try RunProfileScope.roster(project: project, runProfileName: "ios-only")
        XCTAssertEqual(result.ios?.devices?.count, 1)
        XCTAssertNil(result.android)
    }

    /// 起動順は devices の記述順
    func testPreservesTheWrittenOrder() throws {
        try writeRunProfile("ordered", devices: [
            device("ios", "シミュ3"), device("ios", "シミュ1"), device("ios", "シミュ2"),
        ])
        let result = try RunProfileScope.roster(project: project, runProfileName: "ordered")
        XCTAssertEqual(result.ios?.devices?.map(\.name), ["シミュ3", "シミュ1", "シミュ2"])
    }

    /// 同名が別の機械にも居てよい。実効マシンは spec.machine へ正規化して書き戻る
    /// (モニターがタイルに機械名を出せる)
    func testSameNameOnTwoMachinesKeepsBothWithNormalizedMachines() throws {
        try writeRunProfile("mixed-machines", devices: [
            device("ios", "iPhone-01", udid: "LOCAL"),
            device("ios", "iPhone-01", machine: "M1Ultra", udid: "REMOTE"),
        ])
        let result = try RunProfileScope.roster(project: project, runProfileName: "mixed-machines")
        XCTAssertEqual(result.ios?.devices?.map(\.udid), ["LOCAL", "REMOTE"])
        XCTAssertEqual(result.ios?.devices?.map(\.machine), [nil, "M1Ultra"])
    }

    // MARK: - 異常系

    func testThrowsWhenRunProfileFileIsMissing() {
        XCTAssertThrowsError(try RunProfileScope.roster(project: project, runProfileName: "存在しない")) { error in
            guard case ProfileError.runProfileNotFound = error else { return XCTFail("\(error)") }
        }
    }

    func testThrowsWhenRunProfileHasNoDevices() throws {
        // devices を持たない実行プロファイルを「全台」と解釈しない(誤って全台起動しないため)
        try writeRunProfile("nodevices", devices: nil)
        XCTAssertThrowsError(try RunProfileScope.roster(project: project, runProfileName: "nodevices")) { error in
            guard case ProfileError.missingDevices = error else { return XCTFail("\(error)") }
        }
    }

    func testThrowsWhenRunProfileHasEmptyDeviceList() throws {
        try writeRunProfile("empty", devices: [])
        XCTAssertThrowsError(try RunProfileScope.roster(project: project, runProfileName: "empty"))
    }

    /// **文言まで固定する**: CLI(`devices up/down` / `api monitor` / `api list-devices`)が
    /// そのまま利用者へ出す
    func testThrowsWhenEveryDeviceIsDisabled() throws {
        try writeRunProfile("off", devices: [device("ios", "シミュ1", enabled: false)])
        XCTAssertThrowsError(try RunProfileScope.roster(project: project, runProfileName: "off")) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "run profile off has no enabled devices (every entry in \"devices\" has \"enabled\": false)")
        }
    }

    func testThrowsWhenRunProfileIsNotDecodable() throws {
        try Data("{ これは JSON ではない".utf8)
            .write(to: project.runsDir.appendingPathComponent("broken.json"))
        XCTAssertThrowsError(try RunProfileScope.roster(project: project, runProfileName: "broken"))
    }

    func testThrowsWhenAnEntryHasNoPlatform() throws {
        try writeRunProfile("noplatform", devices: [["machine": "local", "name": "x"]])
        XCTAssertThrowsError(try RunProfileScope.roster(project: project, runProfileName: "noplatform")) { error in
            guard case ProfileError.decodeFailed = error else { return XCTFail("\(error)") }
        }
    }
}
