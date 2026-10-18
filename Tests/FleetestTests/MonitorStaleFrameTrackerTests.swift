// モニターの「同じ絵が 60 秒以上続く」の受動観測(警告だけ)。判定は DisplayFreezeDetector と同じ

import XCTest
@testable import fleetest

final class MonitorStaleFrameTrackerTests: XCTestCase {

    private let a = Data("A".utf8)
    private let b = Data("B".utf8)

    func testTheSameFrameForAMinuteWarnsOnceAndAChangeClearsIt() {
        var tracker = MonitorStaleFrameTracker()
        XCTAssertEqual(tracker.record(png: a, id: "d", at: 0), .none)
        XCTAssertEqual(tracker.record(png: a, id: "d", at: 30), .none)
        XCTAssertEqual(tracker.record(png: a, id: "d", at: 60), .began(seconds: 60), "最初に見た時刻から数える")
        XCTAssertEqual(tracker.record(png: a, id: "d", at: 90), .none, "同じ疑いを繰り返さない")
        XCTAssertEqual(tracker.record(png: b, id: "d", at: 92), .ended)
        XCTAssertEqual(tracker.record(png: b, id: "d", at: 100), .none)
    }

    func testAChangingScreenNeverWarns() {
        var tracker = MonitorStaleFrameTracker()
        for (i, frame) in [a, b, a, b, a].enumerated() {
            XCTAssertEqual(tracker.record(png: frame, id: "d", at: Double(i) * 40), .none)
        }
    }

    func testDevicesAreTrackedApartAndForgetRestartsTheCount() {
        var tracker = MonitorStaleFrameTracker()
        _ = tracker.record(png: a, id: "x", at: 0)
        _ = tracker.record(png: a, id: "y", at: 50)
        XCTAssertEqual(tracker.record(png: a, id: "x", at: 60), .began(seconds: 60))
        XCTAssertEqual(tracker.record(png: a, id: "y", at: 60), .none, "y は 10 秒しか経っていない")
        tracker.forget(id: "x")
        XCTAssertEqual(tracker.record(png: a, id: "x", at: 200), .none, "忘れた後は数え直す")
    }
}
