// DriverError.isNoReadableWindow: Android の /snapshot が「アクティブウィンドウの a11y 根が
// 無い」で断った(422 + 宣言した本文接頭辞)応答だけを拾う。**期待値はリテラルで書く** ——
// production の定数で書くと、接頭辞を変えた回にワイヤ契約が割れたまま緑になる。
// isEngineIncapable(§StepExecutorTests+ScrollSearch.swift)と同じく status + 本文前置で見る。

import XCTest
@testable import FTCore

final class NoReadableWindowClassificationTests: XCTestCase {

    func testMatchesStatus422WithDeclaredPrefix() {
        XCTAssertTrue(DriverError.isNoReadableWindow(DriverError.badResponse(
            status: 422, body: "no-active-window-root: the device reports no accessibility root")))
    }

    func testDoesNotMatchOtherStatus422Bodies() {
        // 422 は他の一時的競合にも広く使われる(docs/design.md §4.3)。前置がなければ拾わない
        XCTAssertFalse(DriverError.isNoReadableWindow(DriverError.badResponse(
            status: 422, body: "cannot append to a password field")))
    }

    func testDoesNotMatchTheSameBodyOnADifferentStatus() {
        XCTAssertFalse(DriverError.isNoReadableWindow(DriverError.badResponse(
            status: 500, body: "no-active-window-root: …")))
    }

    func testDoesNotMatchUnrelatedErrors() {
        XCTAssertFalse(DriverError.isNoReadableWindow(DriverError.bridgeUnreachable(
            context: DriverErrorContext(engine: .android, physicalDevice: false), detail: "timeout")))
    }
}
