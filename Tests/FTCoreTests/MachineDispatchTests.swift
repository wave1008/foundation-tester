// MachineDispatchTests.swift
// マシンプロファイルの host(自動リモートディスパッチ、ユーザー決定)まわりの
// 破ったら落ちるテスト: JSON 後方互換・正規化・--host との優先順位(純粋関数)・
// ProfileResolver 経由の読み取り。

import XCTest
@testable import FTCore

final class MachineDispatchTests: XCTestCase {

    // MARK: - MachineProfile.host の JSON 後方互換

    func testMachineProfileDecodesWithoutHostField() throws {
        let json = """
        { "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro" } ] } }
        """.data(using: .utf8)!
        let machine = try JSONDecoder().decode(MachineProfile.self, from: json)
        XCTAssertNil(machine.machine, "host を書いていない既存プロファイルは無改修で動く")
    }

    func testMachineProfileDecodesWithHostField() throws {
        let json = """
        { "host": "M1Max", "ios": { "devices": [] } }
        """.data(using: .utf8)!
        let machine = try JSONDecoder().decode(MachineProfile.self, from: json)
        XCTAssertEqual(machine.machine, "M1Max")
    }

    // MARK: - MachineDispatch.normalize

    func testNormalizeTreatsNilEmptyAndLocalAsNil() {
        XCTAssertNil(MachineDispatch.normalize(nil))
        XCTAssertNil(MachineDispatch.normalize(""))
        XCTAssertNil(MachineDispatch.normalize("   "))
        XCTAssertNil(MachineDispatch.normalize("local"))
        XCTAssertNil(MachineDispatch.normalize("  local  "), "前後空白は trim してから比較する")
    }

    func testNormalizePreservesAndTrimsOtherNames() {
        XCTAssertEqual(MachineDispatch.normalize("M1Max"), "M1Max")
        XCTAssertEqual(MachineDispatch.normalize("  M1Max  "), "M1Max")
        XCTAssertEqual(MachineDispatch.normalize("user@host"), "user@host")
    }

    // MARK: - MachineDispatch.resolve(優先順位・食い違い)

    func testResolveBothLocalStaysLocal() {
        let decision = MachineDispatch.resolve(explicitTarget: nil, profileMachine: nil)
        XCTAssertNil(decision.target)
        XCTAssertNil(decision.mismatchWarning)
    }

    func testResolveMachineHostAloneAutoDispatches() {
        let decision = MachineDispatch.resolve(explicitTarget: nil, profileMachine: "runner1")
        XCTAssertEqual(decision.target, "runner1", "実行プロファイル経由の間接指定(--host 未指定)")
        XCTAssertNil(decision.mismatchWarning)
    }

    func testResolveExplicitHostAloneWins() {
        let decision = MachineDispatch.resolve(explicitTarget: "user@cli-host", profileMachine: nil)
        XCTAssertEqual(decision.target, "user@cli-host")
        XCTAssertNil(decision.mismatchWarning)
    }

    func testResolveExplicitAndMachineAgreeNoWarning() {
        let decision = MachineDispatch.resolve(explicitTarget: "runner1", profileMachine: "runner1")
        XCTAssertEqual(decision.target, "runner1")
        XCTAssertNil(decision.mismatchWarning, "一致しているときは注記しない")
    }

    func testResolveExplicitWinsOverDifferingMachineHostWithWarning() {
        let decision = MachineDispatch.resolve(explicitTarget: "cliHost", profileMachine: "machine")
        XCTAssertEqual(decision.target, "cliHost", "--host が常に勝つ")
        guard let warning = decision.mismatchWarning else {
            return XCTFail("expected a mismatch warning when --host and the machine profile disagree")
        }
        XCTAssertTrue(warning.contains("cliHost"))
        XCTAssertTrue(warning.contains("machine"))
    }

    func testResolveExplicitLocalOverridesMachineHostAndWarns() {
        // 欠陥3: "--host local" は「ここで走らせる」の明示指定であり、
        // 「未指定」ではない。マシン側が別のリモートを指していても黙って上書きせず、
        // 通常の食い違いと同じ規律で warn したうえでローカルに留まる
        // (以前は normalize の畳み込みだけで判定しており、この組み合わせだけ
        // マシン側の host へ自動ディスパッチしてしまっていた)
        let decision = MachineDispatch.resolve(explicitTarget: "local", profileMachine: "runner1")
        XCTAssertNil(decision.target, "--host local は常にローカルに留まる")
        guard let warning = decision.mismatchWarning else {
            return XCTFail("expected a mismatch warning when --host local overrides the machine host")
        }
        XCTAssertTrue(warning.contains("runner1"))
    }

    func testResolveExplicitLocalAndNoMachineHostStaysLocal() {
        let decision = MachineDispatch.resolve(explicitTarget: "local", profileMachine: nil)
        XCTAssertNil(decision.target)
        XCTAssertNil(decision.mismatchWarning, "食い違いが無ければ注記しない")
    }

    func testResolveExplicitLocalWithWhitespaceStillCountsAsLocal() {
        let decision = MachineDispatch.resolve(explicitTarget: "  local  ", profileMachine: "runner1")
        XCTAssertNil(decision.target, "前後空白は trim してから比較する")
        XCTAssertNotNil(decision.mismatchWarning)
    }
}

// MARK: - ProfileResolver.machine / ResolvedProfile.machine(読み取り経路)

final class ProfileResolverMachineHostTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        for dir in [project.appsDir, project.machinesDir, project.runsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ json: String, to dir: URL, name: String) throws {
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(name).json"))
    }

    func testMachineHostReadsNormalizedValue() throws {
        try write("""
        { "host": "  runner1  ", "ios": { "devices": [] } }
        """, to: project.machinesDir, name: "M1Max")
        let host = try ProfileResolver.defaultMachine(project: project, machineName: "M1Max")
        XCTAssertEqual(host, "runner1", "trim 済みで返る")
    }

    func testMachineHostAbsentIsNilNotError() throws {
        try write("""
        { "ios": { "devices": [] } }
        """, to: project.machinesDir, name: "M1Max")
        let host = try ProfileResolver.defaultMachine(project: project, machineName: "M1Max")
        XCTAssertNil(host, "既存プロファイル(host 省略)は無改修でローカル扱い")
    }

    func testMachineHostLocalIsNil() throws {
        try write("""
        { "host": "local", "ios": { "devices": [] } }
        """, to: project.machinesDir, name: "M1Max")
        let host = try ProfileResolver.defaultMachine(project: project, machineName: "M1Max")
        XCTAssertNil(host)
    }

    func testMachineHostUnknownMachineThrows() {
        XCTAssertThrowsError(
            try ProfileResolver.defaultMachine(project: project, machineName: "does-not-exist")
        ) { error in
            guard case ProfileError.machineProfileNotFound(let machine, _) = error else {
                return XCTFail("expected machineProfileNotFound, got \(error)")
            }
            XCTAssertEqual(machine, "does-not-exist")
        }
    }

    func testResolvedProfileCarriesNormalizedMachineHost() throws {
        try write("""
        { "ios": { "appName": "サンプル", "app": "com.example.sampleapp" } }
        """, to: project.appsDir, name: "sampleapp")
        try write("""
        { "host": "runner1",
          "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro" } ] } }
        """, to: project.machinesDir, name: "M1Max")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ] }
        """, to: project.runsDir, name: "all")

        let resolved = try ProfileResolver.resolve(project: project, runName: "all", machineName: "M1Max")
        XCTAssertEqual(resolved.machine, "runner1")
    }

    func testResolvedProfileMachineHostIsNilWhenOmitted() throws {
        try write("""
        { "ios": { "appName": "サンプル", "app": "com.example.sampleapp" } }
        """, to: project.appsDir, name: "sampleapp")
        try write("""
        { "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro" } ] } }
        """, to: project.machinesDir, name: "M1Max")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ] }
        """, to: project.runsDir, name: "all")

        let resolved = try ProfileResolver.resolve(project: project, runName: "all", machineName: "M1Max")
        XCTAssertNil(resolved.machine, "host 省略の既存マシンプロファイルはローカル扱いのまま")
    }
}
