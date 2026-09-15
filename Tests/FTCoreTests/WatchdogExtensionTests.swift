// `WatchdogExtension`(ScenarioHost.swift): deadlineExclusion(began/ended)から watchdog に
// 足すべき延長分を計算する純粋関数。began だけ = 上限ぶんを仮に見込む・ended = 実測へ置き換える・
// 複数回の begin/end も合計する。

import XCTest
@testable import FTCore

final class WatchdogExtensionTests: XCTestCase {

    func testBeganAloneReservesTheCapAsAProvisionalExtension() {
        var extension_ = WatchdogExtension()
        extension_.apply(status: "began", durationMs: 1000)
        XCTAssertEqual(extension_.extra, .milliseconds(1000))
    }

    func testEndedReplacesTheProvisionalExtensionWithTheMeasuredValue() {
        var extension_ = WatchdogExtension()
        extension_.apply(status: "began", durationMs: 1000)
        extension_.apply(status: "ended", durationMs: 400)
        XCTAssertEqual(extension_.extra, .milliseconds(400),
                       "ended の後も上限ぶんの仮の見込みが残っている")
    }

    func testMultipleCompletedWindowsSum() {
        var extension_ = WatchdogExtension()
        extension_.apply(status: "began", durationMs: 1000)
        extension_.apply(status: "ended", durationMs: 300)
        extension_.apply(status: "began", durationMs: 1000)
        extension_.apply(status: "ended", durationMs: 200)
        XCTAssertEqual(extension_.extra, .milliseconds(500), "複数回の完了分を合計していない")
    }

    /// 完了後に新しい began が来れば、また上限ぶんの仮の見込みが積み増される(完了分の上に乗る)
    func testANewBeganAfterCompletionAddsOnTopOfTheCompletedTotal() {
        var extension_ = WatchdogExtension()
        extension_.apply(status: "began", durationMs: 1000)
        extension_.apply(status: "ended", durationMs: 300)
        extension_.apply(status: "began", durationMs: 500)
        XCTAssertEqual(extension_.extra, .milliseconds(800))
    }

    func testNilOrUnknownStatusIsIgnored() {
        var extension_ = WatchdogExtension()
        extension_.apply(status: nil, durationMs: 1000)
        extension_.apply(status: "began", durationMs: nil)
        XCTAssertEqual(extension_.extra, .zero)
        extension_.apply(status: "something-else", durationMs: 1000)
        XCTAssertEqual(extension_.extra, .zero)
    }

    func testStartsAtZero() {
        XCTAssertEqual(WatchdogExtension().extra, .zero)
    }
}
