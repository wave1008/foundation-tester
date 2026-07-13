import XCTest

@testable import FTCore

/// FlowLocatorBuilder.chain の優先度とフォールバック規則。
/// 同期対象: vscode-ftester/src/liveModel.ts locatorChainForElement(同じ規則のユニットテストあり)。
final class FlowLocatorBuilderTests: XCTestCase {
    private func element(
        ref: Int, type: String, identifier: String? = nil, label: String? = nil
    ) -> ElementInfo {
        ElementInfo(
            ref: ref, type: type, identifier: identifier, label: label, value: nil,
            placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 0, height: 0), depth: 0)
    }

    func testIdOmitsTypeIndexFallback() {
        let email = element(ref: 1, type: "TextField", identifier: "email")
        let other = element(ref: 2, type: "TextField")
        let (primary, fallbacks) = FlowLocatorBuilder.chain(for: email, in: [email, other])
        XCTAssertEqual(primary, FlowLocator(id: "email"))
        XCTAssertTrue(fallbacks.isEmpty)
    }

    func testIdKeepsLabelButNotTypeIndex() {
        let el = element(ref: 1, type: "TextField", identifier: "email", label: "メール")
        let (primary, fallbacks) = FlowLocatorBuilder.chain(for: el, in: [el])
        XCTAssertEqual(primary, FlowLocator(id: "email"))
        XCTAssertEqual(fallbacks, [FlowLocator(label: "メール")])
    }

    func testNoIdKeepsLabelThenTypeIndex() {
        let first = element(ref: 1, type: "TextField")
        let el = element(ref: 2, type: "TextField", label: "メール")
        let (primary, fallbacks) = FlowLocatorBuilder.chain(for: el, in: [first, el])
        XCTAssertEqual(primary, FlowLocator(label: "メール"))
        XCTAssertEqual(fallbacks, [FlowLocator(type: "TextField", index: 1)])
    }

    func testNoIdNoLabelFallsBackToTypeIndex() {
        let el = element(ref: 1, type: "Button")
        let (primary, fallbacks) = FlowLocatorBuilder.chain(for: el, in: [el])
        XCTAssertEqual(primary, FlowLocator(type: "Button", index: 0))
        XCTAssertTrue(fallbacks.isEmpty)
    }
}
