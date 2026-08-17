// 実行プロファイルの `fileSync.workspace`(docs/remote-runner.md §17)の純粋ロジックと
// resolve() への配線。デバイス・リモートは要らない(rsync/ssh はここでは扱わない —
// RemoteDispatchTests.swift の workspaceRsyncArgs / RemoteRunArgs 側で固定する)。

import Foundation
import XCTest
@testable import FTCore

final class FileSyncWorkspaceTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-fileSync-\(UUID().uuidString)")
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

    private func writeAppAndMachine(appPath: String = "apps/SampleApp.app") throws {
        try write("""
        { "ios": { "app": "com.example.sampleapp", "appPath": "\(appPath)" } }
        """, to: project.appsDir, name: "sampleapp")
        try write("""
        { "ios": { "devices": [ { "name": "d1", "simulator": "iPhone 17 Pro" } ] } }
        """, to: project.machinesDir, name: "m")
    }

    // MARK: - ProfileResolver.effectiveWorkspaceRaw(純粋関数)

    func testEffectiveWorkspaceRawNeitherIsNil() {
        XCTAssertNil(ProfileResolver.effectiveWorkspaceRaw(declared: nil, override: nil))
    }

    func testEffectiveWorkspaceRawDeclaredOnly() {
        XCTAssertEqual(
            ProfileResolver.effectiveWorkspaceRaw(declared: "../ws", override: nil), "../ws")
    }

    func testEffectiveWorkspaceRawOverrideWinsOverDeclared() {
        XCTAssertEqual(
            ProfileResolver.effectiveWorkspaceRaw(declared: "../ws", override: "/mnt/mirror"),
            "/mnt/mirror")
    }

    func testEffectiveWorkspaceRawOverrideAloneAppliesEvenWithoutDeclaration() {
        XCTAssertEqual(
            ProfileResolver.effectiveWorkspaceRaw(declared: nil, override: "/mnt/mirror"),
            "/mnt/mirror")
    }

    func testEffectiveWorkspaceRawTrimsWhitespaceAndTreatsBlankAsAbsent() {
        XCTAssertEqual(
            ProfileResolver.effectiveWorkspaceRaw(declared: "  ../ws  ", override: nil), "../ws")
        XCTAssertNil(ProfileResolver.effectiveWorkspaceRaw(declared: "   ", override: nil))
        // 空白だけの override は「指定なし」であって「ワークスペース無し」ではない ——
        // 宣言値を黙って無効化すると appPath がリポジトリルート基準へ戻り、リモートで
        // 転送されていない絶対パスを見に行く(この機構が解決した不具合へ逆戻りする)
        XCTAssertEqual(
            ProfileResolver.effectiveWorkspaceRaw(declared: "../ws", override: "   "), "../ws")
    }

    // MARK: - ProfileResolver.declaredWorkspace(軽量読み。マシン解決を経由しない)

    func testDeclaredWorkspaceReadsFileSyncWorkspace() throws {
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "fileSync": { "workspace": "../ws" } }
        """, to: project.runsDir, name: "r")
        XCTAssertEqual(ProfileResolver.declaredWorkspace(project: project, runName: "r"), "../ws")
    }

    func testDeclaredWorkspaceNilWhenSectionAbsent() throws {
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ] }
        """, to: project.runsDir, name: "r")
        XCTAssertNil(ProfileResolver.declaredWorkspace(project: project, runName: "r"))
    }

    func testDeclaredWorkspaceNilWhenWorkspaceEmpty() throws {
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "fileSync": { "workspace": "   " } }
        """, to: project.runsDir, name: "r")
        XCTAssertNil(ProfileResolver.declaredWorkspace(project: project, runName: "r"))
    }

    func testDeclaredWorkspaceNilWhenProfileMissing() {
        XCTAssertNil(ProfileResolver.declaredWorkspace(project: project, runName: "nope"))
    }

    // MARK: - resolve(): 未宣言は appPath の解決を1バイトも変えない(退行の砦)

    func testUnspecifiedFileSyncKeepsAppPathRepoRootBased() throws {
        try writeAppAndMachine()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ] }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertNil(resolved.workspaceRoot)
        XCTAssertEqual(resolved.apps["ios"]?.appPath,
                       tempDir.appendingPathComponent("apps/SampleApp.app").path)
    }

    // MARK: - resolve(): fileSync.workspace 宣言時は appPath の基準が切り替わる

    func testDeclaredWorkspaceRelativeShiftsAppPathBase() throws {
        try writeAppAndMachine(appPath: "apps/SampleApp.app")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "fileSync": { "workspace": "../sut-workspace" } }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        // repoRoot = project.rootURL(TestProjects/SampleApp)の2階層上 = tempDir(setUp 参照)。
        // "../sut-workspace" は tempDir の親 + "sut-workspace" へ畳み込まれる
        // (resolvePath を経由せず独立に期待値を組み立てる)
        let expectedWorkspace = tempDir.deletingLastPathComponent().appendingPathComponent("sut-workspace")
        XCTAssertEqual(resolved.workspaceRoot?.path, expectedWorkspace.path)
        XCTAssertEqual(resolved.apps["ios"]?.appPath,
                       expectedWorkspace.appendingPathComponent("apps/SampleApp.app").path)
    }

    func testDeclaredWorkspaceAbsoluteIsUsedVerbatim() throws {
        try writeAppAndMachine(appPath: "apps/SampleApp.app")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "fileSync": { "workspace": "/Volumes/shared/ws" } }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.workspaceRoot?.path, "/Volumes/shared/ws")
        XCTAssertEqual(resolved.apps["ios"]?.appPath, "/Volumes/shared/ws/apps/SampleApp.app")
    }

    /// appPath 自体が絶対パスなら、fileSync.workspace が宣言されていても触らない
    /// (resolvePath は "/" 始まりを base 無視で素通しする。既存の絶対パス規約を壊さない)
    func testAbsoluteAppPathIsUntouchedEvenWithWorkspaceDeclared() throws {
        try writeAppAndMachine(appPath: "/opt/builds/SampleApp.app")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "fileSync": { "workspace": "../ws" } }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["ios"]?.appPath, "/opt/builds/SampleApp.app")
    }

    // MARK: - resolve(): --workspace(workspaceOverride)がプロファイルの宣言を上書きする

    func testWorkspaceOverrideWinsOverDeclaredValue() throws {
        try writeAppAndMachine(appPath: "apps/SampleApp.app")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "fileSync": { "workspace": "../local-only-ws" } }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m",
            workspaceOverride: "/Users/ci/ftester-runner/work/workspace/SampleApp")
        XCTAssertEqual(resolved.workspaceRoot?.path,
                       "/Users/ci/ftester-runner/work/workspace/SampleApp")
        XCTAssertEqual(resolved.apps["ios"]?.appPath,
                       "/Users/ci/ftester-runner/work/workspace/SampleApp/apps/SampleApp.app")
    }

    // MARK: - validate(): fileSync 内の未知キーは警告(タイポ検出)

    func testValidateWarnsOnUnknownFileSyncKey() throws {
        let json = Data("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "fileSync": { "workspce": "../ws" } }
        """.utf8)
        let (errors, warnings) = ProfileResolver.validate(
            kind: .run, data: json, context: "runs/r.json", project: project)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertTrue(warnings.contains { $0.contains("fileSync") && $0.contains("workspce") },
                     "\(warnings)")
    }
}
