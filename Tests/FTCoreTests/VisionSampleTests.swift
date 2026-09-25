// `fleetest vision capture` / `ft_capture_element` が保存前に断るラベル(学習で初めて気付く誤りを先に言う)

import CoreGraphics
import ImageIO
import XCTest
@testable import FTCore

final class VisionSampleTests: XCTestCase {

    func testCheckStateLabelsMustMapToAState() {
        XCTAssertNil(VisionSample.labelIssue(classifier: "CheckStateClassifier", label: "[ON]"))
        XCTAssertNil(VisionSample.labelIssue(classifier: "CheckStateClassifier", label: "dark/[INDETERMINATE]"))
        XCTAssertNotNil(VisionSample.labelIssue(classifier: "CheckStateClassifier", label: "[Checked]"))
    }

    func testDefaultClassifierLabelsNeedABracketedLeaf() {
        XCTAssertNil(VisionSample.labelIssue(classifier: "DefaultClassifier", label: "@i/Settings/[Camera Icon]"))
        XCTAssertNotNil(VisionSample.labelIssue(classifier: "DefaultClassifier", label: "@i/Camera Icon"),
                        "imageIs は最後の [ 以降で判定するので、括弧の無いフォルダは指せない")
        XCTAssertNotNil(VisionSample.labelIssue(classifier: "DefaultClassifier", label: "[Camera Icon]/sub"))
    }

    func testUnknownClassifierIsRefused() {
        XCTAssertNotNil(VisionSample.labelIssue(classifier: "ScreenClassifier", label: "[Top]"))
    }

    // MARK: - path escape (G5)

    func testLabelIssueRejectsDotDotComponents() {
        XCTAssertNotNil(VisionSample.labelIssue(
            classifier: "DefaultClassifier", label: "@a/../../../../zz_escape2/[X]"))
    }

    func testLabelIssueRejectsAbsolutePaths() {
        XCTAssertNotNil(VisionSample.labelIssue(classifier: "DefaultClassifier", label: "/etc/[X]"))
    }

    func testLabelIssueRejectsSingleDotComponent() {
        XCTAssertNotNil(VisionSample.labelIssue(classifier: "DefaultClassifier", label: "./[X]"))
    }

    func testLabelIssueRejectsEmptyComponents() {
        XCTAssertNotNil(VisionSample.labelIssue(classifier: "DefaultClassifier", label: "@i//[X]"))
    }

    func testLabelIssueStillAcceptsAnOrdinaryNestedLabel() {
        XCTAssertNil(VisionSample.labelIssue(classifier: "DefaultClassifier", label: "@i/Settings/[Camera Icon]"))
    }

    func testNameIssueRejectsSlash() {
        XCTAssertNotNil(VisionSample.nameIssue("../../etc/passwd"))
        XCTAssertNotNil(VisionSample.nameIssue("sub/leaf.png"))
    }

    func testNameIssueRejectsDotDotAndEmpty() {
        XCTAssertNotNil(VisionSample.nameIssue(".."))
        XCTAssertNotNil(VisionSample.nameIssue("."))
        XCTAssertNotNil(VisionSample.nameIssue(""))
    }

    func testNameIssueAcceptsAnOrdinaryFileName() {
        XCTAssertNil(VisionSample.nameIssue("a.png"))
    }

    /// `save` の二次防御。`labelIssue` を経由しない(将来 bypass する)呼び出しでも folder が
    /// classifierFolder の外へ出ていれば isContained が独立に検出できることを確かめる
    func testIsContainedDetectsAnEscapedFolder() {
        let root = URL(fileURLWithPath: "/tmp/testroot/vision/classifiers/DefaultClassifier", isDirectory: true)
        let escaped = root.appendingPathComponent("@a/../../../../zz_escape2/[X]", isDirectory: true)
        XCTAssertFalse(VisionSample.isContained(escaped, in: root))
        let inside = root.appendingPathComponent("@i/Settings/[Camera Icon]", isDirectory: true)
        XCTAssertTrue(VisionSample.isContained(inside, in: root))
        XCTAssertTrue(VisionSample.isContained(root, in: root))
    }

    /// 元バグの再現: この形のラベルは save に渡すと無限ループ+created が際限なく伸びていた
    /// (deletingLastPathComponent が "a/../../.." 型の不動点で止まらなくなる)。
    /// labelIssue が入口で断るので、この呼び出しは待たずに(ハングせず)エラーで返る
    func testSaveRejectsThePathEscapeLabelWithoutHanging() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try VisionSample.save(image(), projectRoot: root, classifier: "DefaultClassifier",
                                                   label: "@a/../../../../zz_escape2/[X]", name: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "何も作らずに断る")
    }

    func testSaveRejectsAnInvalidNameWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try VisionSample.save(image(), projectRoot: root, classifier: "DefaultClassifier",
                                                   label: "[OK]", name: "../../escape.png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "何も作らずに断る")
    }

    // MARK: - save

    private func image() -> CGImage {
        let source = CGImageSourceCreateWithData(CheckStateClassifierTests.checkboxPNG(on: true, shift: 0) as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    func testSaveWritesIntoTheLabelFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try VisionSample.save(image(), projectRoot: root, classifier: "DefaultClassifier",
                                         label: "@i/Settings/[Camera Icon]", name: "a.png")
        XCTAssertEqual(file.path, root.appendingPathComponent(
            "vision/classifiers/DefaultClassifier/@i/Settings/[Camera Icon]/a.png").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// 同じ短いラベルが別のフォルダにあると学習できないので、保存した画像も作ったフォルダも戻す
    func testSaveRollsBackOnADuplicateLabel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try VisionSample.save(image(), projectRoot: root, classifier: "DefaultClassifier",
                                  label: "@i/[Camera Icon]", name: "a.png")
        XCTAssertThrowsError(try VisionSample.save(image(), projectRoot: root, classifier: "DefaultClassifier",
                                                   label: "@a/Other/[Camera Icon]", name: "b.png"))
        let classifiers = root.appendingPathComponent("vision/classifiers/DefaultClassifier")
        XCTAssertFalse(FileManager.default.fileExists(atPath: classifiers.appendingPathComponent("@a").path),
                       "作ったフォルダを戻す")
        XCTAssertTrue(FileManager.default.fileExists(atPath: classifiers.appendingPathComponent("@i/[Camera Icon]/a.png").path),
                      "先にあった見本は残す")
    }

    func testSaveRefusesAnInvalidLabelWithoutWriting() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vs-\(UUID().uuidString)")
        XCTAssertThrowsError(try VisionSample.save(image(), projectRoot: root, classifier: "CheckStateClassifier",
                                                   label: "[Checked]", name: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
