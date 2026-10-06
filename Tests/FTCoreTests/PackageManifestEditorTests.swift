// verify=false: dump-package 検証(遅い)を全テストでスキップ
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
            // === fleetest projects begin(fleetest project create/sync が自動生成。手編集禁止)===
            // === fleetest projects end ===
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
        XCTAssertTrue(content.contains(#"name: "fleetest-scenarios-SampleApp""#))
        XCTAssertTrue(content.contains(#"path: "TestProjects/Demo/scenarios""#))
        XCTAssertTrue(content.contains(#"exclude: ["_disabled"]"#))
        // シナリオは tools-version 6.0 の既定 = Swift 6 言語モード(言語モードを書き足さない)
        XCTAssertFalse(content.contains("swiftSettings"), content)
        XCTAssertTrue(content.contains(".target(name: \"Core\"),"))
        XCTAssertTrue(content.contains(".testTarget(name: \"CoreTests\"),"))

        XCTAssertEqual(try PackageManifestEditor.registeredProjects(manifestURL: manifestURL),
                       ["Demo", "SampleApp"], "名前順で抽出")

        let before = try String(contentsOf: manifestURL, encoding: .utf8)
        try PackageManifestEditor.updateProjects(
            manifestURL: manifestURL, projectNames: ["Demo", "SampleApp"], verify: false)
        XCTAssertEqual(try String(contentsOf: manifestURL, encoding: .utf8), before)

        try PackageManifestEditor.updateProjects(
            manifestURL: manifestURL, projectNames: [], verify: false)
        XCTAssertEqual(try PackageManifestEditor.registeredProjects(manifestURL: manifestURL), [])
        XCTAssertFalse(try String(contentsOf: manifestURL, encoding: .utf8)
            .contains("fleetest-scenarios-"))
    }

    func testSyncDeclaresExtraDependenciesOnceAndKeepsWhatTheUserWrote() throws {
        try PackageManifestEditor.updateProjects(
            manifestURL: manifestURL, projectNames: ["Demo"], verify: false)
        var content = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(content.contains(
            "let fleetestScenarioDependencies: [String: [Target.Dependency]] = [:]\n\nlet package = Package("),
            content)
        XCTAssertTrue(content.contains(
            #"dependencies: ["FTScenarioRunner", "FTDSL"] + (fleetestScenarioDependencies["Demo"] ?? []),"#),
            content)

        content = content.replacingOccurrences(
            of: "[String: [Target.Dependency]] = [:]",
            with: "[String: [Target.Dependency]] = [\n    \"Demo\": [\"Helpers\"],\n]")
        try content.write(to: manifestURL, atomically: true, encoding: .utf8)
        try PackageManifestEditor.updateProjects(
            manifestURL: manifestURL, projectNames: ["Demo", "Other"], verify: false)
        let synced = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(synced.contains("    \"Demo\": [\"Helpers\"],\n]"), "利用者が書いた依存を sync が消した")
        XCTAssertEqual(synced.components(separatedBy: "let fleetestScenarioDependencies").count, 2,
                       "宣言は1つだけ")
        XCTAssertTrue(synced.contains(#"(fleetestScenarioDependencies["Other"] ?? [])"#), synced)
    }

    func testDeclarationGoesAfterImportWhenThereIsNoLetPackage() throws {
        let manifest = "import PackageDescription\nvar package = Package(name: \"x\")\n"
        let updated = try PackageManifestEditor.ensureExtraDependenciesDeclaration(
            in: manifest, manifestURL: manifestURL)
        XCTAssertTrue(updated.hasPrefix(
            "import PackageDescription\n\n// Extra dependencies"), updated)
        XCTAssertThrowsError(try PackageManifestEditor.ensureExtraDependenciesDeclaration(
            in: "// nothing", manifestURL: manifestURL))
    }

    func testUnknownExtraDependencyKeysAreTheOnesThatAreNotProjects() {
        let manifest = """
        let fleetestScenarioDependencies: [String: [Target.Dependency]] = [
            "Demo": [.product(name: "SwiftOTP", package: "SwiftOTP")],
            "Dmeo": [
                "Helpers",
            ],
        ]
        let package = Package(name: "x", targets: [.target(name: "Helpers", path: "Sources/Helpers")])
        """
        XCTAssertEqual(PackageManifestEditor.unknownExtraDependencyKeys(
            in: manifest, projectNames: ["Demo"]), ["Dmeo"])
        XCTAssertEqual(PackageManifestEditor.unknownExtraDependencyKeys(
            in: manifest, projectNames: ["Demo", "Dmeo"]), [])
        XCTAssertEqual(PackageManifestEditor.unknownExtraDependencyKeys(
            in: "let fleetestScenarioDependencies: [String: [Target.Dependency]] = [:]\n\"X\": 1\n",
            projectNames: []), [], "空の辞書の後ろの行を読まない")
    }

    /// 受け手の雛形に依存を足して SwiftPM に評価させる(生成した式が型検査を通り、依存がターゲットに載る)
    func testRecipientManifestPassesExtraDependenciesToTheScenarioTarget() throws {
        let manifest = ProjectScaffold.externalManifest(
            packageName: "Recipient", dependencyLine: ".package(path: \"../foundation-tester\"),")
            .replacingOccurrences(
                of: "[String: [Target.Dependency]] = [:]",
                with: "[String: [Target.Dependency]] = [\n    \"Demo\": [\"Helpers\"],\n]")
            .replacingOccurrences(
                of: "        \(PackageManifestEditor.beginMarker)",
                with: "        .target(name: \"Helpers\", path: \"Helpers\"),\n"
                    + "        \(PackageManifestEditor.beginMarker)")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        try PackageManifestEditor.updateProjects(
            manifestURL: manifestURL, projectNames: ["Demo"], external: true, verify: true)

        let dump = try Shell.run(["swift", "package", "dump-package"],
                                 cwd: manifestURL.deletingLastPathComponent())
        let output = try XCTUnwrap(dump.outputIfSucceeded, dump.tail)
        let start = try XCTUnwrap(output.firstIndex(of: "{"), output)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(output[start...].utf8)) as? [String: Any])
        let targets = try XCTUnwrap(json["targets"] as? [[String: Any]])
        let scenario = try XCTUnwrap(targets.first { $0["name"] as? String == "fleetest-scenarios-Demo" })
        let deps = "\(scenario["dependencies"] ?? "")"
        XCTAssertTrue(deps.contains("Helpers"), deps)
        XCTAssertTrue(deps.contains("FTDSL"), deps)
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
