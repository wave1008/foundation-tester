// profile 付きの MCP 経路(ft_run_scenario・直接操作系の共通入口 resolveProfileTarget)が
// appPath の原本をワークスペースの apps/ へ運ぶこと。resolved.apps[].appPath は常にステージ先を
// 指すので、運ばずにブリッジ準備へ渡すと autoInstall が存在しないパスを simctl install して落ちた
// (CLI の ProfileRunner/ApiRunCommand だけが運んでいた)。
// デバイスに触らないよう、Android の台だけのプロファイルに platformArg "ios" を渡して
// 「台が無い」で抜けさせる —— ステージはその手前で済んでいなければならない
// (resolved.apps は台の居る OS だけなので、運ばれるのは android の appPath)。
// プロジェクトは FT_PACKAGE_ROOT で一時ディレクトリへ差し替える(env はプロセス全体なので必ず戻す)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPProfileWorkspaceStagingTests: XCTestCase {
    private var root: URL!
    private var saved: [String: String?] = [:]
    private let envKeys = ["FT_PACKAGE_ROOT", RunEnvironmentKeys.fastInput,
                           RunEnvironmentKeys.preActionWarmup, RunEnvironmentKeys.animations,
                           RunEnvironmentKeys.playProtectBypass]

    override func setUpWithError() throws {
        for key in envKeys { saved[key] = ProcessInfo.processInfo.environment[key] }
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MCPProfileWorkspaceStagingTests-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("TestProjects/p/profiles")
        for sub in ["runs", "apps"] {
            try FileManager.default.createDirectory(
                at: profiles.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "// swift-tools-version:5.9\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // 原本はリポジトリの外を指す絶対パス(受け手の報告と同じ形)
        let source = root.appendingPathComponent("outside/dist/Sample.apk")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "binary".write(to: source, atomically: true, encoding: .utf8)
        try #"{"common":{"autoInstall":true},"android":{"app":"com.example.sample","appPath":"\#(source.path)"}}"#
            .write(to: profiles.appendingPathComponent("apps/app.json"), atomically: true, encoding: .utf8)
        let emu = #"{"platform":"android","machine":"local","name":"Emu","avd":"Pixel_9"}"#
        try #"{"app":"app","devices":[\#(emu)]}"#
            .write(to: profiles.appendingPathComponent("runs/run.json"), atomically: true, encoding: .utf8)
        setenv("FT_PACKAGE_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        for key in envKeys {
            if let value = saved[key] ?? nil { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testResolveProfileTargetStagesTheAppBeforeTouchingADevice() async throws {
        let project = try ScenarioHost.project(named: "p")
        let resolved = try ProfileResolver.resolve(project: project, runName: "run")
        let dest = try XCTUnwrap(resolved.apps["android"]?.appPath)
        XCTAssertNotEqual(dest, resolved.apps["android"]?.sourcePath, "ステージ先が原本と別であること(前提)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest))

        var prologue: [String] = []
        do {
            _ = try await MCPServer().resolveProfileTarget(
                project: project, profileName: "run", platformArg: "ios", prologue: &prologue)
            XCTFail("iOS の台が無いので抜けるはず")
        } catch {
            XCTAssertTrue("\(error)".contains("has no ios device"), "\(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest),
                      "ブリッジ準備より前に原本がステージ先へ運ばれていること")
        XCTAssertTrue(prologue.contains { $0.contains("Staged app package(s) into the workspace: android") },
                      "\(prologue)")
    }
}
