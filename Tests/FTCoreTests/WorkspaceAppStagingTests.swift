// appPath の原本をワークスペースの apps/ へ実際にコピーする I/O 層(WorkspaceAppStaging)。
// パス計算(インストール先の決定)は FileSyncWorkspaceTests.swift 側(resolve() の純粋ロジック)。
// ここはファイル/ディレクトリの実コピーと冪等性(差分判定)だけを見る。デバイス不要。

import Foundation
import XCTest
@testable import FTCore

final class WorkspaceAppStagingTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-workspace-app-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - installPath(唯一のインストール先規則。ProfileResolver.resolve と共有)

    func testInstallPathIsWorkspaceRootAppsPlusBasename() {
        let workspace = tempDir.appendingPathComponent("ws")
        XCTAssertEqual(
            WorkspaceAppStaging.installPath(source: "/builds/SampleApp.app", workspaceRoot: workspace),
            workspace.appendingPathComponent("apps/SampleApp.app").path)
    }

    // MARK: - stageApp: ファイル

    func testStageAppCopiesAFile() throws {
        let source = tempDir.appendingPathComponent("source.apk")
        try "v1".data(using: .utf8)!.write(to: source)
        let dest = tempDir.appendingPathComponent("ws/apps/source.apk")

        let copied = try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path)
        XCTAssertTrue(copied)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "v1")
    }

    /// 冪等性の核: 内容が変わっていなければ2回目のコピーを飛ばす(115MB を毎回運ばない)。
    /// stageApp が copyItem 後に dest の mtime を明示的に原本と揃えるので、
    /// この判定は copyItem 自体が mtime を保持するかという実装詳細に依存しない
    func testStageAppSkipsSecondCallWhenUnchanged() throws {
        let source = tempDir.appendingPathComponent("source.apk")
        try "v1".data(using: .utf8)!.write(to: source)
        let dest = tempDir.appendingPathComponent("ws/apps/source.apk")

        XCTAssertTrue(try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path))
        let copiedAgain = try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path)
        XCTAssertFalse(copiedAgain, "内容が変わっていなければ2回目はコピーしない")
    }

    /// 原本が変わったら(サイズが変わる更新)コピーし直す
    func testStageAppRecopiesWhenSourceChanges() throws {
        let source = tempDir.appendingPathComponent("source.apk")
        try "v1".data(using: .utf8)!.write(to: source)
        let dest = tempDir.appendingPathComponent("ws/apps/source.apk")
        XCTAssertTrue(try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path))

        try "v2-longer-content".data(using: .utf8)!.write(to: source)
        let copiedAgain = try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path)
        XCTAssertTrue(copiedAgain, "原本のサイズが変わったら再コピーする")
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "v2-longer-content")
    }

    // MARK: - stageApp: ディレクトリ(iOS の .app は常にディレクトリ)

    private func makeAppBundle(at url: URL, executableContent: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try executableContent.data(using: .utf8)!.write(to: url.appendingPathComponent("SampleApp"))
        try "<plist/>".data(using: .utf8)!.write(to: url.appendingPathComponent("Info.plist"))
    }

    func testStageAppCopiesADirectoryBundle() throws {
        let source = tempDir.appendingPathComponent("SampleApp.app")
        try makeAppBundle(at: source, executableContent: "binary-v1")
        let dest = tempDir.appendingPathComponent("ws/apps/SampleApp.app")

        let copied = try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path)
        XCTAssertTrue(copied)
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent("SampleApp"), encoding: .utf8),
            "binary-v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Info.plist").path))
    }

    func testStageAppSkipsSecondCallForUnchangedDirectory() throws {
        let source = tempDir.appendingPathComponent("SampleApp.app")
        try makeAppBundle(at: source, executableContent: "binary-v1")
        let dest = tempDir.appendingPathComponent("ws/apps/SampleApp.app")
        XCTAssertTrue(try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path))

        let copiedAgain = try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path)
        XCTAssertFalse(copiedAgain, "ディレクトリでも差分判定が効く")
    }

    /// ディレクトリ内の深いファイルが変わったこと(総バイト数の変化)を拾う
    func testStageAppRecopiesWhenNestedFileInDirectoryChanges() throws {
        let source = tempDir.appendingPathComponent("SampleApp.app")
        try makeAppBundle(at: source, executableContent: "binary-v1")
        let dest = tempDir.appendingPathComponent("ws/apps/SampleApp.app")
        XCTAssertTrue(try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path))

        try "binary-v2-rebuilt-longer".data(using: .utf8)!
            .write(to: source.appendingPathComponent("SampleApp"))
        let copiedAgain = try WorkspaceAppStaging.stageApp(source: source.path, dest: dest.path)
        XCTAssertTrue(copiedAgain, "配下ファイルの総バイト数が変われば再コピーする")
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent("SampleApp"), encoding: .utf8),
            "binary-v2-rebuilt-longer")
    }

    // MARK: - 原本が無いとき

    /// 原本・複製のどちらも無ければ、原本のパスを名指ししてエラーにする
    /// (ステージ先を出しても「何をビルドすればよいか」分からない)
    func testStageAppThrowsNamingTheSourcePathWhenNeitherExists() {
        let source = tempDir.appendingPathComponent("missing/SampleApp.app").path
        let dest = tempDir.appendingPathComponent("ws/apps/SampleApp.app").path

        XCTAssertThrowsError(try WorkspaceAppStaging.stageApp(source: source, dest: dest)) { error in
            guard case WorkspaceAppStagingError.sourceNotFound(let namedPath) = error else {
                return XCTFail("wrong error type: \(error)")
            }
            XCTAssertEqual(namedPath, source, "エラーはステージ先ではなく原本のパスを名指しする")
        }
    }

    /// 原本が無くても複製が既にあれば何もしない(リモートの子は rsync で複製だけを受け取り
    /// 原本を持たない。docs/remote-runner.md §17。ここで常にエラーにすると、この機構が解決した
    /// 「リモートで appPath が見つからない」問題へ逆戻りする)
    func testStageAppIsNoOpWhenSourceMissingButDestAlreadyStaged() throws {
        let source = tempDir.appendingPathComponent("missing/SampleApp.app").path
        let dest = tempDir.appendingPathComponent("ws/apps/SampleApp.app")
        try makeAppBundle(at: dest, executableContent: "already-mirrored")

        let copied = try WorkspaceAppStaging.stageApp(source: source, dest: dest.path)
        XCTAssertFalse(copied)
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent("SampleApp"), encoding: .utf8),
            "already-mirrored", "既にある複製を壊さない")
    }
}
