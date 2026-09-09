// `--junit` の書き出し先の事前検査。判定は「書けそうか」だけで、**ディレクトリを作らない**
// (検査が失敗した run の残骸を置かない)。末尾の書き込み失敗が警告のみの規律とは別軸。

import XCTest
@testable import FTCore

final class JUnitOutputPathTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-junit-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 書き込み不可にしたディレクトリを残すと後片付けが失敗する
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testWritableDirectoryIsAccepted() {
        let path = root.appendingPathComponent("junit.xml").path
        XCTAssertNil(JUnitOutputPath.unwritableReason(path: path))
    }

    /// 中間ディレクトリがまだ無いのは正常(書き出し側が withIntermediateDirectories で作る)
    func testMissingIntermediateDirectoriesAreAccepted() {
        let path = root.appendingPathComponent("reports/ci/junit.xml").path
        XCTAssertNil(JUnitOutputPath.unwritableReason(path: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("reports").path),
                       "検査はディレクトリを作らないこと")
    }

    func testEmptyPathIsRejected() {
        XCTAssertNotNil(JUnitOutputPath.unwritableReason(path: ""))
        XCTAssertNotNil(JUnitOutputPath.unwritableReason(path: "   "))
    }

    func testExistingDirectoryAtThePathIsRejected() throws {
        let path = root.appendingPathComponent("junit.xml")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let reason = JUnitOutputPath.unwritableReason(path: path.path)
        XCTAssertEqual(reason, "a directory already exists at that path")
    }

    /// パスの途中がファイルだと、書き出し側の createDirectory が必ず失敗する
    func testFileInTheMiddleOfThePathIsRejected() throws {
        let file = root.appendingPathComponent("reports")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let reason = JUnitOutputPath.unwritableReason(path: file.appendingPathComponent("junit.xml").path)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("is a file") == true, "理由に「途中がファイル」と出すこと: \(reason ?? "nil")")
    }

    func testUnwritableParentDirectoryIsRejected() throws {
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let reason = JUnitOutputPath.unwritableReason(path: locked.appendingPathComponent("junit.xml").path)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("is not writable") == true, "理由に「書き込み不可」と出すこと: \(reason ?? "nil")")
    }

    func testExistingWritableFileIsAccepted() throws {
        let path = root.appendingPathComponent("junit.xml")
        try "<testsuites/>".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertNil(JUnitOutputPath.unwritableReason(path: path.path), "上書きは正常")
    }
}
