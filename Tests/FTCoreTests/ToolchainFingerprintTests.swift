// 成果物(XCUITest ランナー・in-app dylib)を「どの Xcode/SDK で作ったか」で鮮度判定する仕組み。
// Xcode を上げてもソースの mtime は動かないため、これが無いと旧成果物が使われ続ける。
// **判定できないケースは必ず「作り直す」側に倒す**のが規約(古い成果物で走る方が高くつく)。
import XCTest
@testable import FTCore

final class ToolchainFingerprintTests: XCTestCase {

    private var dir: URL!
    private var file: URL { dir.appendingPathComponent(".toolchain") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-toolchain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStoreThenMatches() {
        ToolchainFingerprint.store(at: file, current: "Xcode 27.0 Build 27A1 / iphonesimulator 27A1")
        XCTAssertTrue(ToolchainFingerprint.matches(
            storedAt: file, current: "Xcode 27.0 Build 27A1 / iphonesimulator 27A1"))
    }

    /// Xcode を上げた = 指紋が変わる → 作り直す
    func testDifferentToolchainDoesNotMatch() {
        ToolchainFingerprint.store(at: file, current: "Xcode 27.0 Build 27A1 / iphonesimulator 27A1")
        XCTAssertFalse(ToolchainFingerprint.matches(
            storedAt: file, current: "Xcode 27.1 Build 27B2 / iphonesimulator 27B2"))
    }

    /// 未保存(指紋を書く前の版で作った成果物)は不一致扱い
    func testMissingFileDoesNotMatch() {
        XCTAssertFalse(ToolchainFingerprint.matches(storedAt: file, current: "Xcode 27.0"))
    }

    /// 現在値が取れない(xcodebuild が使えない等)ときも不一致扱い = 作り直す側へ
    func testNilCurrentDoesNotMatch() {
        ToolchainFingerprint.store(at: file, current: "Xcode 27.0")
        XCTAssertFalse(ToolchainFingerprint.matches(storedAt: file, current: nil))
    }

    /// 現在値が取れないときは書かない(空ファイルを残して誤って一致させない)
    func testStoreWithNilDoesNothing() {
        ToolchainFingerprint.store(at: file, current: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// 保存側の末尾改行など空白差で不一致にしない(書き手と読み手がずれると毎回再ビルドになる)
    func testTrailingWhitespaceIsIgnored() throws {
        try "Xcode 27.0\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(ToolchainFingerprint.matches(storedAt: file, current: "Xcode 27.0"))
    }

    /// 親ディレクトリが無くても書ける(成果物ディレクトリを消した直後のビルドで落とさない)
    func testStoreCreatesParentDirectory() {
        let nested = dir.appendingPathComponent("build/.toolchain")
        ToolchainFingerprint.store(at: nested, current: "Xcode 27.0")
        XCTAssertTrue(ToolchainFingerprint.matches(storedAt: nested, current: "Xcode 27.0"))
    }

    // MARK: - productVersion(of:)

    func testProductVersionExtractsFromComposedFingerprint() {
        XCTAssertEqual(ToolchainFingerprint.productVersion(
            of: "Xcode 27.0 Build version 27A5228h / iphonesimulator 24A434"), "27.0")
    }

    func testProductVersionRejectsFormWithoutXcodePrefix() {
        XCTAssertNil(ToolchainFingerprint.productVersion(of: "27.0 Build version 27A5228h"))
        XCTAssertNil(ToolchainFingerprint.productVersion(of: "xcode 27.0"))
        XCTAssertNil(ToolchainFingerprint.productVersion(of: ""))
    }

    /// "Xcode " の直後がすぐ空白(版が空)なら nil
    func testProductVersionRejectsEmptyVersion() {
        XCTAssertNil(ToolchainFingerprint.productVersion(of: "Xcode  Build version 27A5228h"))
    }

    func testProductVersionHandlesBareVersionWithNoTrailingText() {
        XCTAssertEqual(ToolchainFingerprint.productVersion(of: "Xcode 27.0"), "27.0")
    }
}
