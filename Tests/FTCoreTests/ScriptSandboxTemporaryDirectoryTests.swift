import Foundation
import XCTest
@testable import FTCore

/// スクリプト専用の一時領域 `hooks-<pid>/` のうち、死んだ pid のものだけを回収の対象にする
final class ScriptSandboxTemporaryDirectoryTests: XCTestCase {
    func testOnlyDeadHookDirectoriesAreListed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ft-hooks-temp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["hooks-100", "hooks-200", "hooks-abc", "fleetest-scenarios-E2E-iOS", "hooks-0"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let stale = ScriptSandbox.staleTemporaryDirectories(root: root.path) { pid in pid == 200 }
        XCTAssertEqual(stale, [root.appendingPathComponent("hooks-100").path])
    }

    func testTheDirectoryNameCarriesThePid() {
        XCTAssertEqual(ScriptSandbox.temporaryDirectoryName(pid: 4242), "hooks-4242")
        XCTAssertTrue(ScriptSandbox.temporaryDirectory(pid: 4242)?.hasSuffix("/fleetest-sandbox/hooks-4242/") == true)
    }
}
