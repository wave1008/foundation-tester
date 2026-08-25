import FTCore
import Foundation
import XCTest

/// `.ftester-transfer-ignore` → rsync `--exclude` の翻訳(TransferIgnore の冒頭が規則の定義元)。
/// 期待値は openrsync で実験した形をそのまま書く —— 非固定パターンは
/// `<dir>/P` と `<dir>/**/P` の2本でないと `<dir>/P` 自身に当たらない
final class TransferIgnoreTests: XCTestCase {

    func testAnchoredAndUnanchoredPatternsRelativeToTheFilesDirectory() {
        XCTAssertEqual(
            TransferIgnore.excludePatterns(
                lines: ["# comment", "; other comment", "", "   ",
                        "/appstub/data/temp/session.json", "*.log", ".stub-leases/"],
                directory: "workspace"),
            [
                "/workspace/appstub/data/temp/session.json",
                "/workspace/*.log", "/workspace/**/*.log",
                "/workspace/.stub-leases/", "/workspace/**/.stub-leases/",
            ])
    }

    func testFileAtTheTransferRootAnchorsAtTheRoot() {
        XCTAssertEqual(
            TransferIgnore.excludePatterns(lines: ["/data/temp/", "cache"], directory: ""),
            ["/data/temp/", "/cache", "/**/cache"])
    }

    func testSurroundingWhitespaceIsTrimmedAndMiddleSlashIsUnanchored() {
        XCTAssertEqual(
            TransferIgnore.excludePatterns(lines: ["  data/temp/  "], directory: "workspace"),
            ["/workspace/data/temp/", "/workspace/**/data/temp/"])
    }

    // MARK: - scan(実ディレクトリ)

    private func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferIgnoreTests-\(UUID().uuidString)")
        for (relative, content) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// 見つけ方: 階層を問わず・辞書順・各ファイルは自分のディレクトリ起点・重複は1本に。
    /// 転送が除外する場所(ルート直下の results 等・階層を問わない node_modules)は読まない
    func testScanFindsFilesAtAnyDepthAndSkipsExcludedPlaces() throws {
        let root = try makeTree([
            "workspace/.ftester-transfer-ignore": "*.log\n",
            "workspace/appstub/.ftester-transfer-ignore": "/data/temp/\n*.log\n",
            "results/.ftester-transfer-ignore": "everything\n",
            "workspace/node_modules/.ftester-transfer-ignore": "everything\n",
            "workspace/results/.ftester-transfer-ignore": "nested-results\n",
            "scenarios/a.swift": "",
        ])
        let scan = TransferIgnore.scan(transferRoot: root,
                                       skipTopLevel: ["results"], skipAnywhere: ["node_modules"])
        XCTAssertEqual(scan.files, [
            "workspace/.ftester-transfer-ignore",
            "workspace/appstub/.ftester-transfer-ignore",
            "workspace/results/.ftester-transfer-ignore",
        ])
        XCTAssertEqual(scan.excludePatterns, [
            "/workspace/*.log", "/workspace/**/*.log",
            "/workspace/appstub/data/temp/",
            "/workspace/appstub/*.log", "/workspace/appstub/**/*.log",
            "/workspace/results/nested-results", "/workspace/results/**/nested-results",
        ])
    }

    func testScanOfAMissingRootOrATreeWithoutTheFileIsEmpty() throws {
        XCTAssertEqual(TransferIgnore.scan(
            transferRoot: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"),
            skipTopLevel: [], skipAnywhere: []), .none)
        let root = try makeTree(["workspace/data/x.json": "{}"])
        XCTAssertEqual(TransferIgnore.scan(transferRoot: root, skipTopLevel: [], skipAnywhere: []), .none)
    }

    /// 名前が同じでもディレクトリなら読まない(ファイルだけ)
    func testScanIgnoresADirectoryNamedLikeTheFile() throws {
        let root = try makeTree(["workspace/.ftester-transfer-ignore/inner.txt": "x"])
        XCTAssertEqual(TransferIgnore.scan(transferRoot: root, skipTopLevel: [], skipAnywhere: []), .none)
    }
}
