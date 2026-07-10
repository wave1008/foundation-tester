// ScenarioFoldersTests.swift

import XCTest
@testable import FTCore

final class ScenarioFoldersTests: XCTestCase {
    var scenariosDir: URL!

    override func setUpWithError() throws {
        scenariosDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-scenarios-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scenariosDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scenariosDir)
    }

    private func write(_ relativePath: String, _ content: String) throws {
        let url = scenariosDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testListExcludesDisabledAndHidden() throws {
        try FileManager.default.createDirectory(
            at: scenariosDir.appendingPathComponent("スモーク"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scenariosDir.appendingPathComponent("Generated"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scenariosDir.appendingPathComponent("_disabled"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scenariosDir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try write("A.swift", "class Alpha {}")  // ファイルはフォルダではない

        XCTAssertEqual(ScenarioFolders.list(scenariosDir: scenariosDir),
                       ["Generated", "スモーク"])
    }

    func testClassFileMapScansFoldersAndSkipsDisabled() throws {
        try write("A.swift", """
        import FTDSL

        @TestClass(app: "com.example.sampleapp")
        class ログインテスト {
            @Test("ログイン")
            func S0010() {}
        }
        """)
        try write("スモーク/B.swift", """
        @TestClass(app: "com.example.sampleapp", platform: "ios")
        final class Network_internet {
        }
        """)
        try write("_disabled/C.swift", "class 退避クラス {}")
        try write("スモーク/メモ.md", "class NotSwift {}")  // .swift 以外は対象外

        let map = ScenarioFolders.classFileMap(scenariosDir: scenariosDir)
        XCTAssertEqual(map["ログインテスト"]?.lastPathComponent, "A.swift")
        XCTAssertEqual(map["Network_internet"]?.lastPathComponent, "B.swift")
        XCTAssertNil(map["退避クラス"])
        XCTAssertNil(map["NotSwift"])

        XCTAssertNil(ScenarioFolders.folderName(of: map["ログインテスト"]!,
                                                scenariosDir: scenariosDir))
        XCTAssertEqual(ScenarioFolders.folderName(of: map["Network_internet"]!,
                                                  scenariosDir: scenariosDir), "スモーク")
    }

    func testClassNamesIgnoresCommentsAndNestedMentions() {
        let names = ScenarioFolders.classNames(inSource: """
        // class コメント内クラス は拾わない
        public final class 本物 {
            let text = "note"
        }
        @TestClass(app: "com.example.app")
        class Second {}
        """)
        XCTAssertEqual(names, ["本物", "Second"])
    }

    func testValidateName() {
        XCTAssertNil(ScenarioFolders.validateName("スモーク"))
        XCTAssertNil(ScenarioFolders.validateName("Generated"))
        XCTAssertNotNil(ScenarioFolders.validateName(""))
        XCTAssertNotNil(ScenarioFolders.validateName("a/b"))
        XCTAssertNotNil(ScenarioFolders.validateName(".hidden"))
        XCTAssertNotNil(ScenarioFolders.validateName("_disabled"))
    }

    func testDirectorySignatureDetectsRelevantChangesOnly() throws {
        try write("A.swift", "class Alpha {}")
        try write("スモーク/B.swift", "class Beta {}")
        try write("_disabled/C.swift", "class 退避 {}")
        let base = ScenarioFolders.directorySignature(scenariosDir: scenariosDir)
        XCTAssertFalse(base.isEmpty)

        // 変更なし → 署名は同じ
        XCTAssertEqual(ScenarioFolders.directorySignature(scenariosDir: scenariosDir), base)

        // 署名対象外の変更(_disabled/ の中身、.md)では変わらない
        try write("_disabled/D.swift", "class 退避2 {}")
        try write("メモ.md", "note")
        XCTAssertEqual(ScenarioFolders.directorySignature(scenariosDir: scenariosDir), base)

        // ファイル移動で変わる
        try FileManager.default.moveItem(
            at: scenariosDir.appendingPathComponent("A.swift"),
            to: scenariosDir.appendingPathComponent("スモーク/A.swift"))
        let afterMove = ScenarioFolders.directorySignature(scenariosDir: scenariosDir)
        XCTAssertNotEqual(afterMove, base)

        // 空フォルダの作成でも変わる(シナリオ一覧にフォルダとして出るため)
        try FileManager.default.createDirectory(
            at: scenariosDir.appendingPathComponent("新規"), withIntermediateDirectories: true)
        XCTAssertNotEqual(ScenarioFolders.directorySignature(scenariosDir: scenariosDir),
                          afterMove)
    }

    func testCreateMoveRenameDelete() throws {
        try write("A.swift", "class Alpha {}")
        try ScenarioFolders.create(name: "回帰", scenariosDir: scenariosDir)
        XCTAssertEqual(ScenarioFolders.list(scenariosDir: scenariosDir), ["回帰"])
        XCTAssertThrowsError(try ScenarioFolders.create(name: "回帰",
                                                        scenariosDir: scenariosDir))

        // 直下 → フォルダ
        let file = scenariosDir.appendingPathComponent("A.swift")
        let moved = try ScenarioFolders.move(file: file, toFolder: "回帰",
                                             scenariosDir: scenariosDir)
        XCTAssertEqual(Array(moved.pathComponents.suffix(2)), ["回帰", "A.swift"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // 同じ場所への移動は no-op
        XCTAssertEqual(try ScenarioFolders.move(file: moved, toFolder: "回帰",
                                                scenariosDir: scenariosDir), moved)

        // 移動先に同名ファイルがあればエラー(上書きしない)
        try write("A.swift", "class Alpha2 {}")
        XCTAssertThrowsError(try ScenarioFolders.move(
            file: scenariosDir.appendingPathComponent("A.swift"),
            toFolder: "回帰", scenariosDir: scenariosDir))

        // 名前変更(中身ごと)
        try ScenarioFolders.rename("回帰", to: "リグレッション", scenariosDir: scenariosDir)
        XCTAssertEqual(ScenarioFolders.list(scenariosDir: scenariosDir), ["リグレッション"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scenariosDir.appendingPathComponent("リグレッション/A.swift").path))

        // 空でないフォルダは削除できない
        XCTAssertThrowsError(try ScenarioFolders.delete("リグレッション",
                                                        scenariosDir: scenariosDir))

        // フォルダ → 直下へ戻す(既存の A.swift を先に退去)→ 空になったので削除できる
        try FileManager.default.removeItem(at: scenariosDir.appendingPathComponent("A.swift"))
        let back = try ScenarioFolders.move(
            file: scenariosDir.appendingPathComponent("リグレッション/A.swift"),
            toFolder: nil, scenariosDir: scenariosDir)
        XCTAssertEqual(back, scenariosDir.appendingPathComponent("A.swift"))
        try ScenarioFolders.delete("リグレッション", scenariosDir: scenariosDir)
        XCTAssertEqual(ScenarioFolders.list(scenariosDir: scenariosDir), [])
    }
}
