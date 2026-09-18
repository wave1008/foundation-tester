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
