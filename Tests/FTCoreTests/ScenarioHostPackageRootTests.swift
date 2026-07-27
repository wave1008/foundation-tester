// FT_PACKAGE_ROOT による ScenarioHost.packageRoot() の cwd 探索オーバーライドの検証。
import XCTest
@testable import FTCore

final class ScenarioHostPackageRootTests: XCTestCase {

    private func withEnv(_ key: String, _ value: String?, _ body: () throws -> Void) rethrows {
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        try body()
    }

    /// 有効なパッケージディレクトリを指す場合はそれが返る(cwd 探索より優先)
    func testValidOverrideIsUsed() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-pkgroot-valid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try "// swift-tools-version: 6.0".write(
            to: tempDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try withEnv("FT_PACKAGE_ROOT", tempDir.path) {
            let root = ScenarioHost.packageRoot()
            XCTAssertEqual(root?.standardizedFileURL.path, tempDir.standardizedFileURL.path)
        }
    }

    /// 無効なディレクトリ(Package.swift 無し)を指す場合は cwd 探索へフォールバックせず nil
    func testInvalidOverrideReturnsNil() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-pkgroot-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try withEnv("FT_PACKAGE_ROOT", tempDir.path) {
            XCTAssertNil(ScenarioHost.packageRoot(), "誤設定を別ルートへ黙って読み替えてはいけない")
        }
    }

    /// 未設定なら従来どおり cwd 探索(このテストプロセスの cwd はリポジトリ内なので見つかるはず)
    func testUnsetFallsBackToCwdSearch() throws {
        try withEnv("FT_PACKAGE_ROOT", nil) {
            XCTAssertNotNil(ScenarioHost.packageRoot(), "リポジトリ内で実行しているので cwd 探索で見つかるはず")
        }
    }
}
