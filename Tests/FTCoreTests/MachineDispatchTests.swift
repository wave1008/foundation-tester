// MachineDispatchTests.swift
// `--runner` の正規化と、実行プロファイルの台が「どの機械に居るか」の読み取り
// (ディスパッチ判定の材料。ProfileResolver.runDeviceMachines)の破ったら落ちるテスト。

import XCTest
@testable import FTCore

final class MachineDispatchTests: XCTestCase {

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

    // MARK: - MachineDispatch.resolve

    func testResolveUnsetStaysLocal() {
        XCTAssertNil(MachineDispatch.resolve(explicitTarget: nil).target)
    }

    func testResolveExplicitTargetIsUsed() {
        XCTAssertEqual(MachineDispatch.resolve(explicitTarget: "user@cli-host").target, "user@cli-host")
        XCTAssertEqual(MachineDispatch.resolve(explicitTarget: " runner1 ").target, "runner1")
    }

    func testResolveExplicitLocalStaysLocal() {
        XCTAssertNil(MachineDispatch.resolve(explicitTarget: "local").target)
        XCTAssertNil(MachineDispatch.resolve(explicitTarget: "  local  ").target, "前後空白は trim してから比較する")
    }
}

// MARK: - ProfileResolver.runDeviceMachines(ディスパッチ判定の読み取り経路)

final class ProfileResolverRunDeviceMachinesTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

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

    private func writeRun(_ json: String, name: String) throws {
        try json.data(using: .utf8)!.write(to: project.runsDir.appendingPathComponent("\(name).json"))
    }

    /// enabled の台だけを、記述順・正規化済みの machine で返す
    func testReturnsEnabledDevicesWithNormalizedMachines() throws {
        try writeRun("""
        { "app": "a", "devices": [
          { "platform": "ios", "machine": " runner1 ", "name": "r" },
          { "platform": "android", "machine": "local", "name": "l" },
          { "platform": "ios", "machine": "M2", "name": "off", "enabled": false },
          { "platform": "android", "name": "implicit" }
        ] }
        """, name: "all")
        let devices = ProfileResolver.runDeviceMachines(project: project, runProfileName: "all")
        XCTAssertEqual(devices, [
            RunDeviceMachine(machine: "runner1", name: "r", platform: "ios"),
            RunDeviceMachine(machine: nil, name: "l", platform: "android"),
            RunDeviceMachine(machine: nil, name: "implicit", platform: "android"),
        ])
    }

    func testUnreadableProfileYieldsEmpty() throws {
        XCTAssertEqual(ProfileResolver.runDeviceMachines(project: project, runProfileName: "missing"), [])
        try writeRun("{ \"devices\": [ { \"name\": \"no-platform\" } ] }", name: "broken")
        XCTAssertEqual(ProfileResolver.runDeviceMachines(project: project, runProfileName: "broken"), [],
                       "platform の無い要素はデコードできない = 読めない扱い(resolve() が名指しで落とす)")
    }
}
