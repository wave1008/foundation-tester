// ブリッジ資産(Runner/・InAppBridge/)のルート解決。外部パッケージ構成では cwd が受け手パッケージに
// 固定されるため、cwd 探索だけでは解決できない(実害: MCP サーバが受け手ルートで
// InAppBridge/build.sh を探して provision が必ず落ちた)。
import XCTest
@testable import FTBridgeClient

final class RepoRootResolutionTests: XCTestCase {

    private func withEnv(_ key: String, _ value: String?, _ body: () throws -> Void) rethrows {
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        try body()
    }

    private func makeToolRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-toolroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Runner"), withIntermediateDirectories: true)
        try "name: FleetestRunner".write(
            to: dir.appendingPathComponent("Runner/project.yml"), atomically: true, encoding: .utf8)
        return dir
    }

    /// FT_TOOL_ROOT が有効なクローンを指す場合はそれが返る(cwd 探索より優先)
    func testValidOverrideIsUsed() throws {
        let toolRoot = try makeToolRoot()
        defer { try? FileManager.default.removeItem(at: toolRoot) }

        try withEnv("FT_TOOL_ROOT", toolRoot.path) {
            let root = try RepoRoot.find()
            XCTAssertEqual(root.standardizedFileURL.path, toolRoot.standardizedFileURL.path)
        }
    }

    /// Runner/ を持たないパスを指していたら探索へフォールバックせず失敗する(誤設定を黙って読み替えない)
    func testInvalidOverrideThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-toolroot-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try withEnv("FT_TOOL_ROOT", dir.path) {
            XCTAssertThrowsError(try RepoRoot.find())
        }
    }

    /// 実行中バイナリ(.build/... のテストバンドル)から上方に辿ってクローンルートへ到達できる。
    /// cwd が受け手パッケージに固定される MCP サーバはこの経路で解決される
    func testExecutableRootReachesClone() throws {
        let root = try XCTUnwrap(RepoRoot.executableRoot())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("InAppBridge/build.sh").path))
    }
}
