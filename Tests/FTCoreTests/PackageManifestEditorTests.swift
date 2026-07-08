// PackageManifestEditorTests.swift
// マーカー区間の全置換・抽出のテスト(dump-package 検証はスキップ: verify=false)。

import XCTest
@testable import FTCore

final class PackageManifestEditorTests: XCTestCase {
    var manifestURL: URL!

    let template = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "fixture",
        targets: [
            .target(name: "Core"),
            // === ftester projects begin(ftester project create/sync が自動生成。手編集禁止)===
            // === ftester projects end ===
            .testTarget(name: "CoreTests"),
        ]
    )
    """

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        manifestURL = dir.appendingPathComponent("Package.swift")
        try template.write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent())
    }

    func testUpdateAndExtract() throws {
        try PackageManifestEditor.updateProjects(
            manifestURL: manifestURL, projectNames: ["SampleApp", "Demo"], verify: false)
        let content = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(content.contains(#"name: "ftester-scenarios-SampleApp""#))
        XCTAssertTrue(content.contains(#"path: "Projects/Demo/Scenarios""#))
        XCTAssertTrue(content.contains(#"exclude: ["_disabled"]"#))
        // マーカー外は無傷
        XCTAssertTrue(content.contains(".target(name: \"Core\"),"))
        XCTAssertTrue(content.contains(".testTarget(name: \"CoreTests\"),"))

        XCTAssertEqual(try PackageManifestEditor.registeredProjects(manifestURL: manifestURL),
                       ["Demo", "SampleApp"], "名前順で抽出")

        // 冪等: 同じ内容で再実行しても変化しない
        let before = try String(contentsOf: manifestURL, encoding: .utf8)
        try PackageManifestEditor.updateProjects(
            manifestURL: manifestURL, projectNames: ["Demo", "SampleApp"], verify: false)
        XCTAssertEqual(try String(contentsOf: manifestURL, encoding: .utf8), before)

        // 削除(空リスト)
        try PackageManifestEditor.updateProjects(
            manifestURL: manifestURL, projectNames: [], verify: false)
        XCTAssertEqual(try PackageManifestEditor.registeredProjects(manifestURL: manifestURL), [])
        XCTAssertFalse(try String(contentsOf: manifestURL, encoding: .utf8)
            .contains("ftester-scenarios-"))
    }

    func testMarkersMissingThrows() throws {
        try "// no markers".write(to: manifestURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PackageManifestEditor.updateProjects(
            manifestURL: manifestURL, projectNames: ["X"], verify: false)) { error in
            guard case PackageManifestEditorError.markersNotFound = error else {
                return XCTFail("markersNotFound のはず: \(error)")
            }
        }
    }
}
