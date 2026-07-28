// Package.swift の最低 macOS と、受け手の Package.swift(ProjectScaffold.externalManifest)の
// 最低 macOS の同期検証。受け手側が本体より低いと依存解決が失敗し、高いと本体が対応する OS で
// 受け手だけビルドできなくなる(どちらも受け手のセットアップが止まる)。

import XCTest
@testable import FTCore

final class PlatformFloorSyncTests: XCTestCase {

    func testExternalManifestPlatformMatchesPackageSwift() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        let manifest = try String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)

        guard let own = Self.macOSFloor(in: manifest) else {
            return XCTFail("Package.swift から .macOS(\"…\") を読めません")
        }
        guard let generated = Self.macOSFloor(
            in: ProjectScaffold.externalManifest(packageName: "Recipient",
                                                 dependencyLine: #".package(path: "..")"#)) else {
            return XCTFail("externalManifest から .macOS(\"…\") を読めません")
        }

        XCTAssertEqual(own, generated,
                       "Package.swift と ProjectScaffold.externalManifest の最低 macOS は"
                       + "同時に変えること")
    }

    /// `.macOS("26.0")` の引数を返す(コメント行の記述には反応しないよう `.macOS("` を目印にする)
    static func macOSFloor(in manifest: String) -> String? {
        guard let start = manifest.range(of: ".macOS(\"") else { return nil }
        let rest = manifest[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
