// TouchGesture.resolve / validate の単体テスト(純粋関数。デバイスもホストの StepExecutor も通さない)。
// StepExecutor 経由の配線(target の決め方・失敗時にドライバを撃たないこと)は
// StepExecutorGestureTests / GestureDSLTests が持つ。

import XCTest
@testable import FTCore

final class TouchGestureTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    // MARK: - 比率 → 絶対座標

    /// move は「開始点」+「移動先」の2点を積み、時刻は durationSeconds の累積
    func testRatioMapsToAbsoluteCoordinatesWithinTargetFrame() throws {
        let target = FTRect(x: 100, y: 200, width: 200, height: 100)
        let finger = FTFinger(x: 0.25, y: 0.5).move(x: 0.75, y: 0.5, durationSeconds: 0.3)

        let result = TouchGesture.resolve([finger], in: target, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        let request = try result.get()
        XCTAssertEqual(request.fingers.count, 1)
        let points = request.fingers[0].points
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].x, 150, accuracy: 0.001)
        XCTAssertEqual(points[0].y, 250, accuracy: 0.001)
        XCTAssertEqual(points[0].t, 0, accuracy: 0.001)
        XCTAssertEqual(points[1].x, 250, accuracy: 0.001)
        XCTAssertEqual(points[1].y, 250, accuracy: 0.001)
        XCTAssertEqual(points[1].t, 0.3, accuracy: 0.001)
    }

    /// hold は座標を変えずに時刻だけ進める(同じ座標の点が続く = 静止)
    func testHoldCreatesASameCoordinatePoint() throws {
        let finger = FTFinger(x: 0.5, y: 0.5).hold(seconds: 0.4)

        let result = TouchGesture.resolve([finger], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        let points = try result.get().fingers[0].points
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].x, points[1].x, accuracy: 0.001)
        XCTAssertEqual(points[0].y, points[1].y, accuracy: 0.001)
        XCTAssertEqual(points[0].t, 0, accuracy: 0.001)
        XCTAssertEqual(points[1].t, 0.4, accuracy: 0.001)
    }

    /// startSeconds は**その指だけ**の点の時刻をずらす(2本目以降を遅らせて置く用途)
    func testStartSecondsOffsetsOnlyThatFingersPoints() throws {
        let first = FTFinger(x: 0.1, y: 0.1).hold(seconds: 0.1)
        let second = FTFinger(x: 0.9, y: 0.9, startSeconds: 0.5).hold(seconds: 0.1)

        let result = TouchGesture.resolve([first, second], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        let fingers = try result.get().fingers
        XCTAssertEqual(fingers[0].points[0].t, 0, accuracy: 0.001)
        XCTAssertEqual(fingers[1].points[0].t, 0.5, accuracy: 0.001)
        XCTAssertEqual(fingers[1].points[1].t, 0.6, accuracy: 0.001)
    }

    /// 移動も静止も積まない指(触れて離すだけ)は `minimumContactSeconds` の接触時間を持つ
    func testTapOnlyFingerGetsTheMinimumContactDuration() throws {
        let finger = FTFinger(x: 0.5, y: 0.5)

        let result = TouchGesture.resolve([finger], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        let points = try result.get().fingers[0].points
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].t, 0, accuracy: 0.001)
        XCTAssertEqual(points[1].t, TouchGesture.minimumContactSeconds, accuracy: 0.001)
    }

    // MARK: - 却下

    func testZeroFingersIsRejected() {
        let result = TouchGesture.resolve([], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        assertFailure(result, contains: "at least one finger")
    }

    func testMoreThanFiveFingersIsRejected() {
        let fingers = (0..<6).map { FTFinger(x: 0.1 * Double($0), y: 0.5) }
        let result = TouchGesture.resolve(fingers, in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        assertFailure(result, contains: "at most 5 fingers")
        assertFailure(result, contains: "got 6")
    }

    /// 画面外の点(ここでは対象=画面全体で、比率が 0...1 を超えて画面の外へ出る形)
    /// 4辺それぞれの外を断る(1辺だけの検査だと、他の辺の判定を消しても緑のまま通る)
    func testOffScreenPointIsRejectedWithItsOwnMessage() {
        for (x, y) in [(-0.1, 0.5), (1.1, 0.5), (0.5, -0.1), (0.5, 1.1)] {
            let result = TouchGesture.resolve([FTFinger(x: x, y: y)], in: screen, screen: screen,
                                              maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
            assertFailure(result, contains: "is off the screen")
        }
    }

    /// 画面の縁ちょうどは画面内(境界を含む)
    func testPointsOnTheScreenEdgeAreAccepted() {
        let finger = FTFinger(x: 0, y: 0).move(x: 1, y: 1, durationSeconds: 0.2)
        let result = TouchGesture.resolve([finger], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        XCTAssertNoThrow(try result.get())
    }

    func testNonPositiveMoveDurationIsRejected() {
        let finger = FTFinger(x: 0.2, y: 0.2).move(x: 0.8, y: 0.8, durationSeconds: 0)
        let result = TouchGesture.resolve([finger], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        assertFailure(result, contains: "durationSeconds of move must be a finite number greater than 0")
    }

    func testNonPositiveHoldSecondsIsRejected() {
        let finger = FTFinger(x: 0.2, y: 0.2).hold(seconds: -1)
        let result = TouchGesture.resolve([finger], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        assertFailure(result, contains: "seconds of hold must be a finite number greater than 0")
    }

    /// 既定の cap(10秒)を超え、`maxGestureSeconds:` の上書きが案内される(cap < ceiling のとき)
    func testTotalOverTheDefaultCapIsRejectedAndSuggestsTheOverride() {
        let finger = FTFinger(x: 0.2, y: 0.2).move(x: 0.8, y: 0.8, durationSeconds: 11)
        let result = TouchGesture.resolve([finger], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        assertFailure(result, contains: "must be 10 seconds or less")
        assertFailure(result, contains: "maxGestureSeconds:")
    }

    /// ちょうど絶対上限(60秒)を cap に渡したときは、これ以上上げようが無いので上書きの案内をしない
    func testTotalOverTheCeilingCapIsRejectedWithoutSuggestingAFurtherOverride() {
        let finger = FTFinger(x: 0.2, y: 0.2).move(x: 0.8, y: 0.8, durationSeconds: 61)
        let result = TouchGesture.resolve([finger], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.gestureSecondsCeiling)
        assertFailure(result, contains: "must be 60 seconds or less")
        XCTAssertFalse(rejectionMessage(result)?.contains("maxGestureSeconds:") ?? true,
                   "60秒(絶対上限)を渡しているのに、さらに上書きできるかのように案内している")
    }

    /// 1本の指に積める点の上限(625)を超えると却下する(Android の16ms刻みの床。TouchGesture.maxPointsPerFinger の doc)
    func testPointsPerFingerOverTheLimitIsRejected() {
        var finger = FTFinger(x: 0, y: 0)
        // 開始点 + 626 回の move = 627 点(626 回それぞれ 0.001秒 = 合計 0.626秒。秒数の上限には掛からない)
        for i in 0...626 {
            let ratio = Double(i % 2)
            finger = finger.move(x: ratio, y: ratio, durationSeconds: 0.001)
        }
        let result = TouchGesture.resolve([finger], in: screen, screen: screen,
                                          maxGestureSeconds: BridgeAPI.defaultMaxGestureSeconds)
        assertFailure(result, contains: "at most 625 are allowed")
    }

    // MARK: - helpers

    private func rejectionMessage(_ result: Result<GestureRequest, TouchGesture.Rejection>) -> String? {
        if case .failure(let rejection) = result { return rejection.message }
        return nil
    }

    private func assertFailure(_ result: Result<GestureRequest, TouchGesture.Rejection>,
                               contains fragment: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let rejection) = result else {
            return XCTFail("成功してはいけない", file: file, line: line)
        }
        XCTAssertTrue(rejection.message.contains(fragment),
                      "\(rejection.message) に \(fragment) が含まれていない", file: file, line: line)
    }
}
