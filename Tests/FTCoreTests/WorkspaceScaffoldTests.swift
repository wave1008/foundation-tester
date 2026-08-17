// remoteControl.workspace 配下の規約フォルダ(apps/scripts/data)の雛形作成。
// デバイス不要(FileManager だけの純粋な I/O)。

import Foundation
import XCTest
@testable import FTCore

final class WorkspaceScaffoldTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-workspace-scaffold-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// ワークスペースルートが未作成でも(親ディレクトリごと無くても)3フォルダを作る
    func testEnsureCreatesAllThreeDirectoriesOnFreshRoot() throws {
        let created = try WorkspaceScaffold.ensure(root: tempDir)
        XCTAssertEqual(created, ["apps", "scripts", "data"])
        for name in ["apps", "scripts", "data"] {
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent(name).path, isDirectory: &isDir))
            XCTAssertTrue(isDir.boolValue)
        }
    }

    /// 揃っていれば何もしない(戻り値は空 = 「初回ではない」の判定に使う)
    func testEnsureIsNoOpWhenAllThreeAlreadyExist() throws {
        try WorkspaceScaffold.ensure(root: tempDir)
        let secondRun = try WorkspaceScaffold.ensure(root: tempDir)
        XCTAssertEqual(secondRun, [])
    }

    /// 欠けている分だけ作る。既存フォルダの中身には触らない
    /// (先に apps/ を自作 + ファイルを置いてから ensure しても、そのファイルは残る)
    func testEnsureFillsOnlyTheMissingDirectoriesAndLeavesExistingContentAlone() throws {
        let apps = tempDir.appendingPathComponent("apps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let marker = apps.appendingPathComponent("keep-me.txt")
        try "hello".data(using: .utf8)!.write(to: marker)

        let created = try WorkspaceScaffold.ensure(root: tempDir)
        XCTAssertEqual(created, ["scripts", "data"], "既に在る apps/ は作成対象に数えない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "既存の中身を壊さない")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("scripts").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("data").path))
    }
}
