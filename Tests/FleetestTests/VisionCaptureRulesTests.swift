// `fleetest vision capture` が保存前に断るラベル(学習で初めて気付く誤りを先に言う)

import XCTest
@testable import fleetest

final class VisionCaptureRulesTests: XCTestCase {

    func testCheckStateLabelsMustMapToAState() {
        XCTAssertNil(VisionCaptureRules.labelIssue(classifier: "CheckStateClassifier", label: "[ON]"))
        XCTAssertNil(VisionCaptureRules.labelIssue(classifier: "CheckStateClassifier", label: "dark/[INDETERMINATE]"))
        XCTAssertNotNil(VisionCaptureRules.labelIssue(classifier: "CheckStateClassifier", label: "[Checked]"))
    }

    func testDefaultClassifierLabelsNeedABracketedLeaf() {
        XCTAssertNil(VisionCaptureRules.labelIssue(classifier: "DefaultClassifier", label: "@i/Settings/[Camera Icon]"))
        XCTAssertNotNil(VisionCaptureRules.labelIssue(classifier: "DefaultClassifier", label: "@i/Camera Icon"),
                        "imageIs は最後の [ 以降で判定するので、括弧の無いフォルダは指せない")
        XCTAssertNotNil(VisionCaptureRules.labelIssue(classifier: "DefaultClassifier", label: "[Camera Icon]/sub"))
    }

    func testUnknownClassifierIsRefused() {
        XCTAssertNotNil(VisionCaptureRules.labelIssue(classifier: "ScreenClassifier", label: "[Top]"))
    }
}
