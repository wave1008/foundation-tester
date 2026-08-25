// 実行プロファイルの `remoteControl.workspace`(docs/remote-runner.md §17)の純粋ロジックと
// resolve() への配線。デバイス・リモートは要らない(rsync/ssh はここでは扱わない —
// RemoteDispatchTests.swift の workspaceRsyncArgs / RemoteRunArgs 側で固定する)。
// appPath の原本(sourcePath)は常にリポジトリルート基準 —— ワークスペース宣言時は
// **インストールに使うパス(appPath)だけ** が "<workspace>/apps/<ファイル名>" に切り替わる。
// 実ファイルのコピー(ステージング)は WorkspaceAppStagingTests.swift 側の担当(ここは
// 純粋な path 計算だけを固定する。デバイス・ファイル I/O 不要)。

import Foundation
import XCTest
@testable import FTCore

final class RemoteControlWorkspaceTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-remoteControl-\(UUID().uuidString)")
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

    func testDeclaredWorkspaceReadsRemoteControlWorkspace() throws {
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "remoteControl": { "workspace": "../ws" } }
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
          "remoteControl": { "workspace": "   " } }
        """, to: project.runsDir, name: "r")
        XCTAssertNil(ProfileResolver.declaredWorkspace(project: project, runName: "r"))
    }

    func testDeclaredWorkspaceNilWhenProfileMissing() {
        XCTAssertNil(ProfileResolver.declaredWorkspace(project: project, runName: "nope"))
    }

    // MARK: - resolve(): 未宣言は既定ワークスペース `<project.rootURL>/workspace` を使う
    // (2026-08-18。ワークスペースは常に有効 —— appPath のインストール先は常にリダイレクトされる。
    // 原本(sourcePath)の解決基準はリポジトリルートのまま不変)

    func testUnspecifiedRemoteControlDefaultsToProjectRootWorkspace() throws {
        try writeAppAndMachine()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ] }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.workspaceRoot?.path,
                       project.rootURL.appendingPathComponent("workspace").path)
        XCTAssertEqual(resolved.apps["ios"]?.sourcePath,
                       tempDir.appendingPathComponent("apps/SampleApp.app").path)
        XCTAssertEqual(resolved.apps["ios"]?.appPath,
                       project.rootURL.appendingPathComponent("workspace/apps/SampleApp.app").path)
    }

    // MARK: - ProfileResolver.resolveWorkspaceRoot(純粋関数。優先順位の3段: override > declared > 既定)

    func testResolveWorkspaceRootDefaultsToProjectRootWorkspaceWhenNeitherGiven() {
        let projectRoot = URL(fileURLWithPath: "/repo/TestProjects/SampleApp")
        let repoRoot = URL(fileURLWithPath: "/repo")
        XCTAssertEqual(
            ProfileResolver.resolveWorkspaceRoot(
                declared: nil, override: nil, projectRoot: projectRoot, repoRoot: repoRoot).path,
            "/repo/TestProjects/SampleApp/workspace")
    }

    func testResolveWorkspaceRootDeclaredWinsOverDefault() {
        let projectRoot = URL(fileURLWithPath: "/repo/TestProjects/SampleApp")
        let repoRoot = URL(fileURLWithPath: "/repo")
        XCTAssertEqual(
            ProfileResolver.resolveWorkspaceRoot(
                declared: "../ws", override: nil, projectRoot: projectRoot, repoRoot: repoRoot).path,
            "/ws")
    }

    func testResolveWorkspaceRootOverrideWinsOverDeclaredAndDefault() {
        let projectRoot = URL(fileURLWithPath: "/repo/TestProjects/SampleApp")
        let repoRoot = URL(fileURLWithPath: "/repo")
        XCTAssertEqual(
            ProfileResolver.resolveWorkspaceRoot(
                declared: "../ws", override: "/mnt/mirror",
                projectRoot: projectRoot, repoRoot: repoRoot).path,
            "/mnt/mirror")
    }

    // MARK: - ProfileResolver.effectiveWorkspaceRoot(軽量読み。RemoteRunDispatcher が
    // マシン解決前にワークスペースの用意先を知るために使う。declaredWorkspace + 既定を合成する)

    func testEffectiveWorkspaceRootDefaultsToProjectRootWorkspaceWhenUndeclared() throws {
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ] }
        """, to: project.runsDir, name: "r")
        XCTAssertEqual(
            ProfileResolver.effectiveWorkspaceRoot(project: project, runName: "r").path,
            project.rootURL.appendingPathComponent("workspace").path)
    }

    func testEffectiveWorkspaceRootUsesDeclaredValueWhenPresent() throws {
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "remoteControl": { "workspace": "../ws" } }
        """, to: project.runsDir, name: "r")
        let expected = tempDir.deletingLastPathComponent().appendingPathComponent("ws")
        XCTAssertEqual(
            ProfileResolver.effectiveWorkspaceRoot(project: project, runName: "r").path, expected.path)
    }

    // MARK: - resolve(): remoteControl.workspace 宣言時は「インストールに使うパス」だけが
    // ワークスペース基準へ切り替わる。**原本(sourcePath)の解決基準はリポジトリルートのまま不変**
    // (appPath の相対パス解決そのものの基準は切り替えない —— 原本の置き場所と
    // インストールに使う場所は別物。docs/remote-runner.md §17)

    func testDeclaredWorkspaceRedirectsInstallPathButKeepsSourceAtRepoRoot() throws {
        try writeAppAndMachine(appPath: "apps/SampleApp.app")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "remoteControl": { "workspace": "../sut-workspace" } }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        // repoRoot = project.rootURL(TestProjects/SampleApp)の2階層上 = tempDir(setUp 参照)。
        // "../sut-workspace" は tempDir の親 + "sut-workspace" へ畳み込まれる
        // (resolvePath を経由せず独立に期待値を組み立てる)
        let expectedWorkspace = tempDir.deletingLastPathComponent().appendingPathComponent("sut-workspace")
        XCTAssertEqual(resolved.workspaceRoot?.path, expectedWorkspace.path)
        // 原本は宣言前と同じくリポジトリルート基準のまま(ここが今回の契約変更の核)
        XCTAssertEqual(resolved.apps["ios"]?.sourcePath,
                       tempDir.appendingPathComponent("apps/SampleApp.app").path)
        // インストールに使うパスだけが "<workspace>/apps/<原本のファイル名>" になる
        XCTAssertEqual(resolved.apps["ios"]?.appPath,
                       expectedWorkspace.appendingPathComponent("apps/SampleApp.app").path)
    }

    func testDeclaredWorkspaceAbsoluteAlsoUsesAppsSubdirectory() throws {
        try writeAppAndMachine(appPath: "apps/SampleApp.app")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "remoteControl": { "workspace": "/Volumes/shared/ws" } }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.workspaceRoot?.path, "/Volumes/shared/ws")
        XCTAssertEqual(resolved.apps["ios"]?.appPath, "/Volumes/shared/ws/apps/SampleApp.app")
    }

    /// appPath 自体が絶対パスでも、ワークスペース宣言時はインストール先が
    /// "<workspace>/apps/<ファイル名>" へ**常に**切り替わる(要件3「存在するかどうかで
    /// 分岐させない」の一貫性 —— 相対/絶対で扱いを変えると、絶対パスで書いたプロファイルだけ
    /// リモートで見つからない、という以前と同じ不具合の変種が残る)。**原本(sourcePath)は
    /// 絶対パスのまま変わらない**(以前の「絶対パスなら触らない」テストはこの契約変更で置き換わる)
    func testAbsoluteAppPathIsAlsoRedirectedToWorkspaceAppsWhenDeclared() throws {
        try writeAppAndMachine(appPath: "/opt/builds/SampleApp.app")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "remoteControl": { "workspace": "../ws" } }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.apps["ios"]?.sourcePath, "/opt/builds/SampleApp.app")
        let expectedWorkspace = tempDir.deletingLastPathComponent().appendingPathComponent("ws")
        XCTAssertEqual(resolved.apps["ios"]?.appPath,
                       expectedWorkspace.appendingPathComponent("apps/SampleApp.app").path)
    }

    // MARK: - resolve(): --workspace(workspaceOverride)がプロファイルの宣言を上書きする

    func testWorkspaceOverrideWinsOverDeclaredValue() throws {
        try writeAppAndMachine(appPath: "apps/SampleApp.app")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "remoteControl": { "workspace": "../local-only-ws" } }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m",
            workspaceOverride: "/Users/ci/fleetest-runner/work/workspace/SampleApp")
        XCTAssertEqual(resolved.workspaceRoot?.path,
                       "/Users/ci/fleetest-runner/work/workspace/SampleApp")
        XCTAssertEqual(resolved.apps["ios"]?.appPath,
                       "/Users/ci/fleetest-runner/work/workspace/SampleApp/apps/SampleApp.app")
        XCTAssertEqual(resolved.apps["ios"]?.sourcePath,
                       tempDir.appendingPathComponent("apps/SampleApp.app").path)
    }

    // MARK: - ProfileResolver.declaredAppPaths(軽量読み。RemoteRunDispatcher のミラー直前用)

    func testDeclaredAppPathsResolvesRelativeToRepoRoot() throws {
        try writeAppAndMachine(appPath: "apps/SampleApp.app")
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ] }
        """, to: project.runsDir, name: "r")

        let paths = ProfileResolver.declaredAppPaths(project: project, runName: "r")
        XCTAssertEqual(paths["ios"], tempDir.appendingPathComponent("apps/SampleApp.app").path)
        XCTAssertNil(paths["android"])
    }

    func testDeclaredAppPathsEmptyWhenAppOrProfileMissing() {
        XCTAssertEqual(ProfileResolver.declaredAppPaths(project: project, runName: "nope"), [:])
    }

    // MARK: - validate(): remoteControl 内の未知キーは警告(タイポ検出)

    func testValidateWarnsOnUnknownRemoteControlKey() throws {
        let json = Data("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "remoteControl": { "workspce": "../ws" } }
        """.utf8)
        let (errors, warnings) = ProfileResolver.validate(
            kind: .run, data: json, context: "runs/r.json", project: project)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertTrue(warnings.contains { $0.contains("remoteControl") && $0.contains("workspce") },
                     "\(warnings)")
    }

    // MARK: - resolve(): 開始・終了スクリプトは実効ワークスペースの scripts/ 配下に解決される
    // (規則そのものは RunHooksTests.swift。ここは配線だけ)

    func testResolveCarriesTheHooksResolvedAgainstTheEffectiveWorkspace() throws {
        try writeAppAndMachine()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ],
          "remoteControl": { "workspace": "/Volumes/shared/ws" } }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.setupHook?.url.path, "/Volumes/shared/ws/scripts/setup.sh")
        XCTAssertEqual(resolved.teardownHook?.url.path, "/Volumes/shared/ws/scripts/teardown.sh")
    }

    func testHooksFollowTheDefaultWorkspaceWhenUndeclared() throws {
        try writeAppAndMachine()
        try write("""
        { "app": "sampleapp", "devices": [ { "name": "d1" } ] }
        """, to: project.runsDir, name: "r")

        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertEqual(resolved.setupHook?.url.path,
                       project.rootURL.appendingPathComponent("workspace/scripts/setup.sh").path)
    }
}
