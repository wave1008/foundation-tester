import Foundation
import XCTest
@testable import FTCore

/// 子を起こす実行ファイルは実体のパスで指す(`ExecutablePath`)。`.build/debug` は SwiftPM がビルドのたびに消して作り直すリンクで、
/// その間(実測 約 0.8ms)リンク経由の起動は ENOENT になる(2026-10-15 の負荷テスト)
final class ExecutablePathTests: XCTestCase {

    func testResolvesALinkedDirectoryToTheRealFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exepath-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("out/Debug")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let binary = real.appendingPathComponent("tool")
        FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("debug"),
                                                   withDestinationURL: real)
        let viaLink = root.appendingPathComponent("debug/tool")
        XCTAssertEqual(ExecutablePath.resolved(viaLink).path, binary.resolvingSymlinksInPath().path)
        // 実体が無い(リンクの作り直しの最中・別の配置)なら元のパスのまま
        let missing = root.appendingPathComponent("debug/absent")
        XCTAssertEqual(ExecutablePath.resolved(missing), missing)
    }

    /// `Bundle.main.executableURL` を直に使ってよいのは、子を起こさない箇所だけ(等号固定)。子を起こす新しい経路が
    /// リンクのパスで起こすと、ビルドのたびの窓で ENOENT になる
    func testOnlyNonSpawningSitesReadTheExecutableURLDirectly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let allowed: [String: String] = [
            "Sources/FTCore/ExecutablePath.swift": "the resolver itself",
            "Sources/FTCore/ScenarioSandbox.swift": "the sandbox's state roots (the same value the scope is built from)",
            "Sources/FTCore/ScriptSandbox.swift": "the sandbox's state roots for scripts",
            "Sources/FTCore/ToolVersion.swift": "walks up to .git (no process is started)",
            "Sources/FTBridgeClient/BridgeLauncher.swift": "walks up to Runner/ after resolving links itself",
            "Sources/fleetest/ApiResultsCommand.swift": "fingerprint of the binary for the output cache (stat follows links)",
        ]
        var found: Set<String> = []
        let sources = root.appendingPathComponent("Sources")
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if code.contains(where: { $0.contains("Bundle.main.executableURL") }) {
                found.insert(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        XCTAssertEqual(found, Set(allowed.keys))
    }

    /// run の中で一番多く起こす子(シナリオ実行バイナリ)は `.build/debug` のリンクを経ずに実体で起こす
    func testScenarioRunnerIsStartedByItsRealPath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        guard let start = text.range(of: "public static func runnerURL(project: TestProject)"),
              let end = text.range(of: "throw ScenarioHostError.runnerNotFound", range: start.upperBound..<text.endIndex) else {
            return XCTFail("runnerURL not found — the scan is broken")
        }
        let body = text[start.upperBound..<end.lowerBound]
        XCTAssertNotNil(body.range(of: "return ExecutablePath.resolved(debugBinary)"), "the .build/debug runner is started through the link")
        XCTAssertNotNil(body.range(of: "ExecutablePath.current?"), "the sibling runner is looked up next to the link path")
    }
}
