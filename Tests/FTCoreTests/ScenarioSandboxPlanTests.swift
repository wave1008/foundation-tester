// 「包むかどうか」とマシン側の設定の読み方。ここが誤ると、包むつもりの実行が枠なしで走るか、
// 読ませないつもりの場所が読める。

import XCTest
@testable import FTCore

final class ScenarioSandboxPlanTests: XCTestCase {

    private var root: URL!
    private let home = "/Users/nobody-ft"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var configURL: URL { root.appendingPathComponent("config.json") }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: configURL)
    }

    private func resolve() throws -> ScenarioSandbox.Plan? {
        try ScenarioSandbox.plan(settings: try ScenarioSandbox.machineSettings(url: configURL), home: home)
    }

    /// 既定は「包む」。設定ファイルが無い・`sandbox` 欄が無い・空のいずれでも包む(リテラルで固定)
    func testWrappedByDefault() throws {
        XCTAssertNotNil(try resolve())
        try write(#"{"defaultProject": "p"}"#)
        XCTAssertNotNil(try resolve())
        try write(#"{"sandbox": {}}"#)
        XCTAssertNotNil(try resolve())
        try write(#"{"sandbox": {"disabled": false}}"#)
        XCTAssertNotNil(try resolve())
        XCTAssertNil(ScenarioSandbox.MachineSettings().disabled)
    }

    /// 外せるのはマシン側の `disabled: true` だけ
    func testOnlyTheMachineSideSwitchTurnsItOff() throws {
        try write(#"{"sandbox": {"disabled": true}}"#)
        XCTAssertNil(try resolve())
    }

    /// 内蔵の拒否は置き換えられない。`denyRead` は**足す**だけ
    func testDenyReadAddsToTheBuiltInListAndExpandsTilde() throws {
        try write(#"{"sandbox": {"denyRead": ["~/secrets", "/opt/keys"]}}"#)
        let plan = try XCTUnwrap(try resolve())
        XCTAssertTrue(plan.denyRead.contains(home + "/.ssh"))
        XCTAssertTrue(plan.denyRead.contains(home + "/.config"))
        XCTAssertTrue(plan.denyRead.contains(home + "/Library/Keychains"))
        XCTAssertEqual(Array(plan.denyRead.suffix(2)), [home + "/secrets", "/opt/keys"])
    }

    func testAllowedDomainsAreCarriedAndEmptyByDefault() throws {
        XCTAssertEqual(try resolve()?.allowedDomains, [])
        try write(#"{"sandbox": {"allowedDomains": ["api.example.com", "*.example.org"]}}"#)
        XCTAssertEqual(try resolve()?.allowedDomains, ["api.example.com", "*.example.org"])
    }

    /// 綴りを誤ったキーを黙って無視しない(`denyread` と書いた一覧が効かないまま走る)
    func testUnknownKeysAreAnError() throws {
        try write(#"{"sandbox": {"denyread": ["~/x"]}}"#)
        XCTAssertThrowsError(try resolve()) { error in
            guard case .unknownKeys(_, let keys)? = error as? ScenarioSandbox.ConfigError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(keys, ["denyread"])
        }
    }

    /// 壊れた設定は「空 = 既定」に倒さず止める(`LocalConfig.load` と違う)。既定に倒すと、追加した
    /// `denyRead` が黙って消えた状態で走る
    func testMalformedFileAndInvalidDomainAreErrors() throws {
        try write("{not json")
        XCTAssertThrowsError(try resolve()) { error in
            guard case .unreadable? = error as? ScenarioSandbox.ConfigError else { return XCTFail("\(error)") }
        }
        try write(#"{"sandbox": true}"#)
        XCTAssertThrowsError(try resolve()) { error in
            guard case .unreadable? = error as? ScenarioSandbox.ConfigError else { return XCTFail("\(error)") }
        }
        try write(#"{"sandbox": {"allowedDomains": ["ok.example.com", "*"]}}"#)
        XCTAssertThrowsError(try resolve()) { error in
            guard case .invalidDomain(_, let pattern)? = error as? ScenarioSandbox.ConfigError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(pattern, "*")
        }
    }

    /// 設定の場所は `XDG_CONFIG_HOME` を見ない(環境変数で別の設定へ向けて `disabled` を立てさせない)
    func testMachineSettingsLocationIgnoresXDGConfigHome() throws {
        XCTAssertEqual(ScenarioSandbox.machineSettingsURL(home: "/Users/a").path,
                       "/Users/a/.config/fleetest/config.json")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/ScenarioSandbox.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("\"XDG_CONFIG_HOME\""), "the sandbox settings must not follow XDG_CONFIG_HOME")
    }

    /// 実ホームは `HOME` を見ない(偽のホームを渡されると `~/.ssh` の拒否が偽の場所に組まれる)
    func testRealHomeComesFromThePasswordDatabase() throws {
        let entry = try XCTUnwrap(getpwuid(getuid()))
        XCTAssertEqual(ScenarioSandbox.realHome(), String(cString: entry.pointee.pw_dir))
    }

    func testLocalConfigCarriesTheSandboxSection() throws {
        XCTAssertNil(LocalConfig().sandbox)
        let decoded = try JSONDecoder().decode(
            LocalConfig.self, from: Data(#"{"sandbox": {"disabled": true, "denyRead": ["~/x"]}}"#.utf8))
        XCTAssertEqual(decoded.sandbox, ScenarioSandbox.MachineSettings(disabled: true, denyRead: ["~/x"]))
    }
}
